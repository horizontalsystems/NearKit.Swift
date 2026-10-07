import Foundation
import HsCryptoKit

/// Builds, signs and submits transactions, recording each one locally as pending so the wallet
/// shows it immediately (Android `TransactionSender`). Sends are serialized: concurrent sends would
/// read the same access key nonce and one of them would be rejected with InvalidNonce.
final class TransactionSender {
    /// Mainnet and testnet `transaction_validity_period`: a block hash older than this is rejected.
    static let transactionValidityBlocks = 86400

    private let accountId: String
    private let rpcApiProvider: RpcApiProvider
    private let mainStorage: IMainStorage
    private let transactionStorage: ITransactionStorage
    /// Gets each record saved as pending, which no sync reports until it changes.
    private let onPendingSaved: (Transaction) -> Void
    private let queue = SendQueue()

    init(accountId: String, rpcApiProvider: RpcApiProvider, mainStorage: IMainStorage, transactionStorage: ITransactionStorage, onPendingSaved: @escaping (Transaction) -> Void = { _ in }) {
        self.accountId = accountId
        self.rpcApiProvider = rpcApiProvider
        self.mainStorage = mainStorage
        self.transactionStorage = transactionStorage
        self.onPendingSaved = onPendingSaved
    }

    /// Builds and signs without submitting. The nonce and block hash come from the chain.
    func sign(signer: Signer, receiverId: String, actions: [Action]) async throws -> SignedTransaction {
        try await queue.run { [self] in
            try await signWithHeight(signer: signer, receiverId: receiverId, actions: actions).0
        }
    }

    func send(signer: Signer, receiverId: String, actions: [Action]) async throws -> Transaction {
        try await queue.run { [self] in
            let (signed, height) = try await signWithHeight(signer: signer, receiverId: receiverId, actions: actions)
            return try await submit(signed: signed, referenceHeight: height)
        }
    }

    /// Fails unless `signer`'s key is a full-access key of the account.
    func requireFullAccess(signer: Signer) async throws -> AccessKeyView {
        guard let accessKey = try await rpcApiProvider.viewAccessKey(accountId: accountId, publicKey: signer.publicKey.description) else {
            throw SendError.accessKeyNotFound
        }
        guard accessKey.isFullAccess else {
            throw SendError.notFullAccessKey
        }
        return accessKey
    }

    private func signWithHeight(signer: Signer, receiverId: String, actions: [Action]) async throws -> (SignedTransaction, Int) {
        let accessKey = try await requireFullAccess(signer: signer)
        guard accessKey.nonce < UInt64.max else {
            throw InvalidResponse("view_access_key: nonce out of range")
        }

        let transaction = try NearTransaction(
            signerId: accountId,
            publicKey: signer.publicKey,
            nonce: accessKey.nonce + 1,
            receiverId: receiverId,
            blockHash: Base58.strictDecode(accessKey.blockHash, count: NearTransaction.blockHashSize),
            actions: actions
        )
        return (try signer.sign(transaction), accessKey.blockHeight)
    }

    /// Submits an already signed transaction (e.g. one signed for a dApp). `referenceHeight` is the
    /// height of its block hash when known; it bounds how long the record may stay pending.
    ///
    /// Only a rejection for a transaction no node knows is reported as `SendError.rejected`. Any
    /// other failure may come after a node already accepted it (a dropped connection, or failover
    /// resending it to a node that then refuses the used nonce), so the record is kept as pending
    /// to resolve or expire, instead of inviting the user to send again.
    func submit(signed: SignedTransaction, referenceHeight: Int?) async throws -> Transaction {
        // the current height when the block hash's is unknown: a later expiry only keeps the record pending longer
        let height: Int
        if let referenceHeight {
            height = referenceHeight
        } else if let chainState = try mainStorage.chainState() {
            height = chainState.blockHeight
        } else {
            height = try await rpcApiProvider.latestBlock().height
        }

        let (pending, tags) = TransactionConverter.pending(
            transaction: signed.transaction,
            hash: signed.hash,
            expiresAfterHeight: height + Self.transactionValidityBlocks,
            timestamp: Int(Date().timeIntervalSince1970)
        )
        let savePending = { [self] in
            try transactionStorage.save(transactions: [(pending, tags)])
            onPendingSaved(pending)
        }

        let failure: Error?
        do {
            _ = try await rpcApiProvider.sendTransaction(signedTxBase64: signed.base64, waitUntil: "INCLUDED")
            failure = nil
        } catch is CancellationError {
            // cancelled mid-request: the transaction may be out
            try savePending()
            throw CancellationError()
        } catch {
            failure = error
        }

        if let error = failure as? RpcError, error.name == RpcError.invalidTransaction {
            let rejected = SendError.rejected(details: error.data ?? error.message ?? error.name)
            switch await isKnown(signed: signed) {
            case .some(false):
                throw rejected
            case .some(true):
                // an earlier attempt got it on chain; this is a refusal of the duplicate
                try savePending()
                return pending
            case .none:
                // cannot tell: keep the record, which expires to failed if the rejection was real
                try savePending()
                throw rejected
            }
        }

        try savePending()
        if let failure {
            throw failure
        }
        return pending
    }

    /// Whether a node knows the transaction; nil when that cannot be told right now.
    private func isKnown(signed: SignedTransaction) async -> Bool? {
        do {
            return try await rpcApiProvider.transactionStatus(hash: signed.hash, senderAccountId: signed.transaction.signerId) != nil
        } catch {
            return nil
        }
    }
}
