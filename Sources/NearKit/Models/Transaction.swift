import BigInt
import Foundation
import GRDB

/// A transaction touching the kit's account. NEAR executes a transaction as a tree of receipts,
/// possibly across blocks and shards; `nearTransfers` and `ftTransfers` are the value movements of
/// the kit's account found anywhere in that tree, not just the top-level actions.
public class Transaction: Record {
    public enum Status: String {
        case pending = "Pending"
        case success = "Success"
        case failed = "Failed"
    }

    public let hash: String
    /// Block the transaction was included in; nil while pending or when only known from the RPC.
    public let blockHeight: Int?
    /// Unix seconds. For pending transactions this is the submission time.
    public let timestamp: Int
    public let signerId: String
    public let receiverId: String
    public let actions: [TxAction]
    public let nearTransfers: [NearTransfer]
    public let ftTransfers: [FtTransfer]
    /// yoctoNEAR burnt as gas by the whole receipt tree, paid by `signerId`. Nil while pending.
    public let fee: BigUInt?
    public let status: Status
    /// Failure detail from the outcome (e.g. `{"ActionError":…}`), or `expired`.
    public let failure: String?
    /// Pending only: once the chain passes this height the transaction can no longer be included.
    public let expiresAfterHeight: Int?

    init(
        hash: String, blockHeight: Int?, timestamp: Int, signerId: String, receiverId: String, actions: [TxAction],
        nearTransfers: [NearTransfer], ftTransfers: [FtTransfer], fee: BigUInt?, status: Status, failure: String?, expiresAfterHeight: Int?
    ) {
        self.hash = hash
        self.blockHeight = blockHeight
        self.timestamp = timestamp
        self.signerId = signerId
        self.receiverId = receiverId
        self.actions = actions
        self.nearTransfers = nearTransfers
        self.ftTransfers = ftTransfers
        self.fee = fee
        self.status = status
        self.failure = failure
        self.expiresAfterHeight = expiresAfterHeight
        super.init()
    }

    public var isPending: Bool {
        status == .pending
    }

    public var isSuccess: Bool {
        status == .success
    }

    public var isFailed: Bool {
        status == .failed
    }

    public func isSigner(accountId: String) -> Bool {
        signerId == accountId
    }

    /// Net native NEAR change of `accountId` from successful movements, fee excluded.
    public func nearNetChange(accountId: String) -> BigInt {
        nearTransfers.filter(\.success).reduce(BigInt(0)) { result, transfer in
            if transfer.to == accountId {
                return transfer.from == accountId ? result : result + BigInt(transfer.amount)
            }
            if transfer.from == accountId {
                return result - BigInt(transfer.amount)
            }
            return result
        }
    }

    /// The NEAR `accountId` gained or lost as a payment: `nearNetChange` without the NEAR that only
    /// accompanies a call. That is the 1 yoctoNEAR contracts demand as proof of a full-access key
    /// (NEP-141 `ft_*`, NEP-245, intents), the storage deposit that registers a receiver next to a
    /// token transfer, and the part of that deposit the contract sends back. It decides whether a
    /// transaction belongs to NEAR's history (Android `Transaction.nearMoved`).
    public func nearMoved(accountId: String) -> BigInt {
        let sendsToken = signerId == accountId && actions.contains { Self.isFtMethod($0.methodName) }
        func accompanying(_ transfer: NearTransfer) -> Bool {
            transfer.kind == .functionCallDeposit && transfer.from == accountId &&
                (transfer.amount == 1 || Self.isFtMethod(transfer.methodName) || (sendsToken && transfer.methodName == Self.storageDeposit))
        }

        let successful = nearTransfers.filter(\.success)
        // what each contract may still send back of the registration deposits it got
        var refundable = [String: BigUInt]()
        for transfer in successful where accompanying(transfer) && transfer.methodName == Self.storageDeposit {
            refundable[transfer.to, default: 0] += transfer.amount
        }

        return successful.reduce(BigInt(0)) { result, transfer in
            if accompanying(transfer) {
                return result
            }
            if transfer.to == accountId, transfer.kind == .transfer, let available = refundable[transfer.from], available >= transfer.amount {
                refundable[transfer.from] = available - transfer.amount
                return result
            }
            if transfer.to == accountId {
                return transfer.from == accountId ? result : result + BigInt(transfer.amount)
            }
            if transfer.from == accountId {
                return result - BigInt(transfer.amount)
            }
            return result
        }
    }

    private static let storageDeposit = "storage_deposit"

    static func isFtMethod(_ methodName: String?) -> Bool {
        methodName?.hasPrefix("ft_") == true
    }

    func copy(timestamp: Int? = nil, status: Status? = nil, failure: String?? = nil) -> Transaction {
        Transaction(
            hash: hash, blockHeight: blockHeight, timestamp: timestamp ?? self.timestamp, signerId: signerId, receiverId: receiverId,
            actions: actions, nearTransfers: nearTransfers, ftTransfers: ftTransfers, fee: fee, status: status ?? self.status,
            failure: failure ?? self.failure, expiresAfterHeight: expiresAfterHeight
        )
    }

    // MARK: - Record

    override public class var databaseTableName: String {
        "transactions"
    }

    enum Columns: String, ColumnExpression {
        case hash, blockHeight, timestamp, signerId, receiverId, actions, nearTransfers, ftTransfers, fee, status, failure, expiresAfterHeight
    }

    public required init(row: Row) throws {
        hash = row[Columns.hash]
        blockHeight = row[Columns.blockHeight]
        timestamp = row[Columns.timestamp]
        signerId = row[Columns.signerId]
        receiverId = row[Columns.receiverId]
        actions = try Self.decode(row[Columns.actions], column: .actions)
        nearTransfers = try Self.decode(row[Columns.nearTransfers], column: .nearTransfers)
        ftTransfers = try Self.decode(row[Columns.ftTransfers], column: .ftTransfers)
        let fee: String? = row[Columns.fee]
        if let fee {
            guard let value = BigUInt(fee) else {
                throw DatabaseError(message: "invalid fee: \(fee)")
            }
            self.fee = value
        } else {
            self.fee = nil
        }
        let status: String = row[Columns.status]
        guard let value = Status(rawValue: status) else {
            throw DatabaseError(message: "invalid status: \(status)")
        }
        self.status = value
        failure = row[Columns.failure]
        expiresAfterHeight = row[Columns.expiresAfterHeight]
        try super.init(row: row)
    }

    override public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.hash] = hash
        container[Columns.blockHeight] = blockHeight
        container[Columns.timestamp] = timestamp
        container[Columns.signerId] = signerId
        container[Columns.receiverId] = receiverId
        container[Columns.actions] = try Self.encode(actions)
        container[Columns.nearTransfers] = try Self.encode(nearTransfers)
        container[Columns.ftTransfers] = try Self.encode(ftTransfers)
        container[Columns.fee] = fee?.description
        container[Columns.status] = status.rawValue
        container[Columns.failure] = failure
        container[Columns.expiresAfterHeight] = expiresAfterHeight
    }

    private static func encode(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ text: String, column: Columns) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw DatabaseError(message: "invalid \(column.rawValue): \(error)")
        }
    }
}

/// A top-level action, flattened for storage and display.
public struct TxAction: Equatable, Codable {
    /// CreateAccount, DeployContract, FunctionCall, Transfer, Stake, AddKey, DeleteKey, DeleteAccount, Delegate…
    public let type: String
    public let deposit: BigUInt?
    public let methodName: String?
    /// FunctionCall arguments as text when they are UTF-8 (normally JSON), truncated.
    public let args: String?
    public let gas: BigUInt?
    public let publicKey: String?
    public let beneficiaryId: String?
    public let stake: BigUInt?

    init(type: String, deposit: BigUInt? = nil, methodName: String? = nil, args: String? = nil, gas: BigUInt? = nil, publicKey: String? = nil, beneficiaryId: String? = nil, stake: BigUInt? = nil) {
        self.type = type
        self.deposit = deposit
        self.methodName = methodName
        self.args = args
        self.gas = gas
        self.publicKey = publicKey
        self.beneficiaryId = beneficiaryId
        self.stake = stake
    }

    enum CodingKeys: String, CodingKey {
        case type, deposit, methodName, args, gas, publicKey, beneficiaryId, stake
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        deposit = try container.decodeAmountIfPresent(forKey: .deposit)
        methodName = try container.decodeIfPresent(String.self, forKey: .methodName)
        args = try container.decodeIfPresent(String.self, forKey: .args)
        gas = try container.decodeAmountIfPresent(forKey: .gas)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        beneficiaryId = try container.decodeIfPresent(String.self, forKey: .beneficiaryId)
        stake = try container.decodeAmountIfPresent(forKey: .stake)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(deposit?.description, forKey: .deposit)
        try container.encodeIfPresent(methodName, forKey: .methodName)
        try container.encodeIfPresent(args, forKey: .args)
        try container.encodeIfPresent(gas?.description, forKey: .gas)
        try container.encodeIfPresent(publicKey, forKey: .publicKey)
        try container.encodeIfPresent(beneficiaryId, forKey: .beneficiaryId)
        try container.encodeIfPresent(stake?.description, forKey: .stake)
    }
}

/// NEAR attached to a receipt: a Transfer, or the deposit of a FunctionCall (storage_deposit, the
/// 1 yocto of ft_transfer, wrap.near near_deposit). Gas refunds from `system` are not included;
/// they are already netted out of `Transaction.fee`.
public struct NearTransfer: Equatable, Codable {
    public enum Kind: String, Codable {
        case transfer = "Transfer"
        case functionCallDeposit = "FunctionCallDeposit"
    }

    public let from: String
    public let to: String
    public let amount: BigUInt
    public let kind: Kind
    /// False when the receipt failed; its deposit went back to the sender.
    public let success: Bool
    /// The method a `functionCallDeposit` was attached to.
    public let methodName: String?

    init(from: String, to: String, amount: BigUInt, kind: Kind, success: Bool, methodName: String? = nil) {
        self.from = from
        self.to = to
        self.amount = amount
        self.kind = kind
        self.success = success
        self.methodName = methodName
    }

    enum CodingKeys: String, CodingKey {
        case from, to, amount, kind, success, methodName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        amount = try container.decodeAmount(forKey: .amount)
        kind = try container.decode(Kind.self, forKey: .kind)
        success = try container.decode(Bool.self, forKey: .success)
        methodName = try container.decodeIfPresent(String.self, forKey: .methodName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(amount.description, forKey: .amount)
        try container.encode(kind, forKey: .kind)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(methodName, forKey: .methodName)
    }
}

/// A NEP-141 movement from an `EVENT_JSON` log of a successful receipt, or predicted for a pending send.
public struct FtTransfer: Equatable, Codable {
    public let contractId: String
    /// Nil for a mint.
    public let from: String?
    /// Nil for a burn.
    public let to: String?
    public let amount: BigUInt
    public let memo: String?

    init(contractId: String, from: String?, to: String?, amount: BigUInt, memo: String?) {
        self.contractId = contractId
        self.from = from
        self.to = to
        self.amount = amount
        self.memo = memo
    }

    func copy(memo: String?) -> FtTransfer {
        FtTransfer(contractId: contractId, from: from, to: to, amount: amount, memo: memo)
    }

    enum CodingKeys: String, CodingKey {
        case contractId, from, to, amount, memo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractId = try container.decode(String.self, forKey: .contractId)
        from = try container.decodeIfPresent(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        amount = try container.decodeAmount(forKey: .amount)
        memo = try container.decodeIfPresent(String.self, forKey: .memo)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contractId, forKey: .contractId)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(to, forKey: .to)
        try container.encode(amount.description, forKey: .amount)
        try container.encodeIfPresent(memo, forKey: .memo)
    }
}

/// Which histories a transaction belongs to: `tokenNative` or a token contract id.
public enum TransactionTag {
    public static let tokenNative = "native"
}

class TransactionTagRecord: Record {
    let hash: String
    let token: String

    init(hash: String, token: String) {
        self.hash = hash
        self.token = token
        super.init()
    }

    override class var databaseTableName: String {
        "transactionTag"
    }

    enum Columns: String, ColumnExpression {
        case hash, token
    }

    required init(row: Row) throws {
        hash = row[Columns.hash]
        token = row[Columns.token]
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.hash] = hash
        container[Columns.token] = token
    }
}

/// Amounts are stored as decimal strings: u128 fits no JSON number exactly.
private extension KeyedDecodingContainer {
    func decodeAmount(forKey key: Key) throws -> BigUInt {
        let text = try decode(String.self, forKey: key)
        guard let value = BigUInt(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "invalid amount \(text)")
        }
        return value
    }

    func decodeAmountIfPresent(forKey key: Key) throws -> BigUInt? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        return try decodeAmount(forKey: key)
    }
}
