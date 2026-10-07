import BigInt
import HdWalletKit
import HsCryptoKit
import HsToolKit
@testable import NearKit
import XCTest

/// Live check against NEAR testnet, the same as the Android `TestnetIntegrationTest`: create a
/// funded account through the testnet helper, send NEAR to a new implicit account, wrap NEAR and
/// send the token with a storage deposit, then find the transactions in the FastNEAR index.
/// Skipped unless `NEARKIT_INTEGRATION=true` in the test process; CI never sets it. From the command
/// line pass it as `TEST_RUNNER_NEARKIT_INTEGRATION=true xcodebuild test ...` so xcodebuild forwards it.
final class TestnetIntegrationTests: XCTestCase {
    private static let helperUrl = URL(string: "https://helper.testnet.near.org/account")!
    private static let wrap = "wrap.testnet"

    private let network = Network.testNet
    private var rpc: RpcApiProvider!
    private var fastNear: FastNearProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NEARKIT_INTEGRATION"] == "true", "set NEARKIT_INTEGRATION=true to run against the testnet")

        let networkManager = NetworkManager(timeout: Kit.requestTimeout)
        rpc = RpcApiProvider(urls: network.rpcUrls, networkManager: networkManager)
        fastNear = FastNearProvider(network: network, apiKey: nil, networkManager: networkManager)
    }

    func testFundSendWrapAndIndex() async throws {
        let sender = try Signer.instance(seed: XCTUnwrap(Mnemonic.seed(mnemonic: Mnemonic.generate())))
        let receiver = try Signer.address(seed: XCTUnwrap(Mnemonic.seed(mnemonic: Mnemonic.generate())))
        let senderId = "nearkit-\(Int(Date().timeIntervalSince1970 * 1000)).testnet"
        print("sender \(senderId) (\(sender.publicKey)), receiver \(receiver)")

        try await createAccount(accountId: senderId, publicKey: sender.publicKey.description)
        var account = try await rpc.viewAccount(accountId: senderId)
        for _ in 0 ..< 15 where account == nil {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            account = try await rpc.viewAccount(accountId: senderId)
        }
        let funded = try XCTUnwrap(account, "helper did not create the account")
        print("sender balance \(NearAmount.toNear(yocto: funded.amount)) NEAR, storage \(funded.storageUsage) bytes")
        let receiverBefore = try await rpc.viewAccount(accountId: receiver)
        XCTAssertNil(receiverBefore)

        // 1. NEAR to a fresh implicit account creates it
        let amount = try XCTUnwrap(NearAmount.toYocto(near: Decimal(string: "1.5")!))
        let block = try await rpc.latestBlock()
        let transfer = try await sendAndWait(sender, signerId: senderId, receiverId: receiver, actions: [.transfer(deposit: amount)])
        XCTAssertEqual(transfer.status, .success)
        XCTAssertEqual(transfer.nearNetChange(accountId: senderId), -BigInt(amount))
        let receiverAfter = try await rpc.viewAccount(accountId: receiver)
        XCTAssertEqual(receiverAfter?.amount, amount)
        let estimate = FeeCalculator().estimate(actions: [.transfer(deposit: amount)], receiverIsImplicit: true, createsAccount: true, gasPrice: block.gasPrice)
        let fee = try XCTUnwrap(transfer.fee)
        print("transfer \(transfer.hash): fee \(fee) (estimate \(estimate.fee), required \(estimate.requiredBalance))")
        XCTAssertLessThanOrEqual(fee, estimate.fee)

        // 2. Reusing a nonce is refused by the node before it reaches a block
        let stale = try NearTransaction(signerId: senderId, publicKey: sender.publicKey, nonce: 1, receiverId: receiver, blockHash: Base58.strictDecode(block.hash), actions: [.transfer(deposit: 1)])
        do {
            _ = try await rpc.sendTransaction(signedTxBase64: sender.sign(stale).base64)
            XCTFail("stale nonce accepted")
        } catch let error as RpcError {
            print("stale nonce rejected: \(error.name) \(error.data ?? "")")
            XCTAssertEqual(error.name, RpcError.invalidTransaction)
        }

        // 3. Wrap NEAR, then send the token to the receiver, who is not registered yet
        var wrapActions = [Action]()
        if let deposit = try await FtActions.storageDepositRequired(rpcApiProvider: rpc, contractId: Self.wrap, accountId: senderId) {
            let args = #"{"account_id":"\#(senderId)","registration_only":true}"#
            wrapActions.append(.functionCall(methodName: "storage_deposit", args: Data(args.utf8), gas: FtActions.gas, deposit: deposit))
        }
        try wrapActions.append(.functionCall(methodName: "near_deposit", args: Data("{}".utf8), gas: FtActions.gas, deposit: XCTUnwrap(NearAmount.toYocto(near: Decimal(string: "0.5")!))))
        let wrapped = try await sendAndWait(sender, signerId: senderId, receiverId: Self.wrap, actions: wrapActions)
        XCTAssertEqual(wrapped.status, .success)
        print("wrap \(wrapped.hash): \(wrapped.ftTransfers)")

        let tokenAmount = try XCTUnwrap(NearAmount.toYocto(near: Decimal(string: "0.1")!))
        let storageDeposit = try await FtActions.storageDepositRequired(rpcApiProvider: rpc, contractId: Self.wrap, accountId: receiver)
        XCTAssertNotNil(storageDeposit, "receiver should not be registered")
        let ftActions = try FtActions.transfer(receiverId: receiver, amount: tokenAmount, memo: "nearkit", storageDeposit: storageDeposit)
        let ftSend = try await sendAndWait(sender, signerId: senderId, receiverId: Self.wrap, actions: ftActions)
        print("ft_transfer \(ftSend.hash): \(ftSend.ftTransfers), fee \(ftSend.fee.map { "\($0)" } ?? "nil")")
        XCTAssertEqual(ftSend.status, .success)
        XCTAssertEqual(ftSend.ftTransfers, [FtTransfer(contractId: Self.wrap, from: senderId, to: receiver, amount: tokenAmount, memo: "nearkit")])
        let receiverBalance = try await rpc.callFunctionJson(contractId: Self.wrap, methodName: "ft_balance_of", argsJson: FtActions.accountIdArgs(receiver))
        XCTAssertEqual(receiverBalance as? String, tokenAmount.description)
        let depositAfter = try await FtActions.storageDepositRequired(rpcApiProvider: rpc, contractId: Self.wrap, accountId: receiver)
        XCTAssertNil(depositAfter)

        // 4. The index picks the transactions up within seconds
        let wanted: Set = [transfer.hash, wrapped.hash, ftSend.hash]
        var indexed = Set<String>()
        var waited = 0
        while !indexed.isSuperset(of: wanted), waited < 90 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            waited += 3
            let page = try await fastNear.accountTransactions(accountId: senderId, fromBlockHeight: nil, newestFirst: true, resumeToken: nil, limit: FastNearProvider.pageLimit)
            indexed = Set(page.rows.map(\.hash))
        }
        print("indexed after \(waited)s: \(indexed)")
        XCTAssertTrue(indexed.isSuperset(of: wanted))
        let fromIndex = try await fastNear.transactions(hashes: Array(wanted)).map { try TransactionConverter.convert(item: $0, accountId: senderId, fallbackTimestamp: 0).0 }
        for transaction in fromIndex {
            print("index \(transaction.hash): \(transaction.status) fee \(transaction.fee.map { "\($0)" } ?? "nil") near \(transaction.nearNetChange(accountId: senderId)) ft \(transaction.ftTransfers)")
        }
        XCTAssertTrue(fromIndex.allSatisfy(\.isSuccess))
        XCTAssertEqual(fromIndex.first { $0.hash == ftSend.hash }?.ftTransfers, ftSend.ftTransfers)

        // 5. The named account is found from its key (the implicit one always comes first)
        let accounts = try await Kit.findAccounts(publicKey: sender.publicKey, network: network)
        print("accounts for key: \(accounts)")
        XCTAssertEqual(accounts.first, sender.publicKey.implicitAccountId)
    }

    /// The same steps `TransactionSender` takes, then polls the RPC until the outcome is final.
    private func sendAndWait(_ signer: Signer, signerId: String, receiverId: String, actions: [Action]) async throws -> Transaction {
        let accessKey = try await rpc.viewAccessKey(accountId: signerId, publicKey: signer.publicKey.description)
        let key = try XCTUnwrap(accessKey)
        let transaction = try NearTransaction(signerId: signerId, publicKey: signer.publicKey, nonce: key.nonce + 1, receiverId: receiverId, blockHash: Base58.strictDecode(key.blockHash), actions: actions)
        let signed = try signer.sign(transaction)
        _ = try await rpc.sendTransaction(signedTxBase64: signed.base64, waitUntil: "INCLUDED")

        for _ in 0 ..< 40 {
            if let status = try await rpc.transactionStatus(hash: signed.hash, senderAccountId: signerId), status.isExecuted,
               let raw = status.raw, status.finalExecutionStatus == "FINAL"
            {
                return try TransactionConverter.convert(item: raw, accountId: signerId, fallbackTimestamp: 0).0
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw InvalidResponse("transaction \(signed.hash) did not finalize")
    }

    private func createAccount(accountId: String, publicKey: String) async throws {
        var request = URLRequest(url: Self.helperUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["newAccountId": accountId, "newAccountPublicKey": publicKey])
        let (_, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("helper HTTP \(statusCode)")
        // the helper rate-limits account creation; that says nothing about the kit
        try XCTSkipIf(statusCode == 429, "testnet helper rate limit")
        XCTAssertTrue((200 ..< 300).contains(statusCode), "helper HTTP \(statusCode)")
    }
}
