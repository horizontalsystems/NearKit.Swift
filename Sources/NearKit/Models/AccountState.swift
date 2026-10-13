import BigInt
import Foundation
import GRDB

/// On-chain state of the kit's account. A single row; `exists` is false until the account receives NEAR.
public class AccountState: Record, Equatable {
    private static let primaryKeyValue = "primaryKey"
    private let primaryKey: String = AccountState.primaryKeyValue

    /// Accounts using at most this many bytes need no storage stake (NEP-448 zero balance accounts).
    public static let zeroBalanceAccountStorageLimit: UInt64 = 770
    /// 10^19 yoctoNEAR (0.00001 NEAR) per byte; unchanged since genesis.
    public static let storagePricePerByte = BigUInt(10).power(19)

    public let exists: Bool
    /// Liquid balance, yoctoNEAR.
    public let amount: BigUInt
    /// Validator stake locked on the account itself (delegation to pools is not included).
    public let locked: BigUInt
    public let storageUsage: UInt64
    public let hasContract: Bool

    public static let empty = AccountState(exists: false, amount: 0, locked: 0, storageUsage: 0, hasContract: false)

    init(exists: Bool, amount: BigUInt, locked: BigUInt, storageUsage: UInt64, hasContract: Bool) {
        self.exists = exists
        self.amount = amount
        self.locked = locked
        self.storageUsage = storageUsage
        self.hasContract = hasContract
        super.init()
    }

    convenience init(view: AccountView?) {
        guard let view else {
            self.init(exists: false, amount: 0, locked: 0, storageUsage: 0, hasContract: false)
            return
        }
        self.init(exists: true, amount: view.amount, locked: view.locked, storageUsage: view.storageUsage, hasContract: view.hasContract)
    }

    /// Balance held for storage staking: none up to the zero-balance limit, above it the whole
    /// usage is staked, and locked stake counts towards it.
    public var storageStaked: BigUInt {
        storageUsage <= Self.zeroBalanceAccountStorageLimit ? 0 : BigUInt(storageUsage) * Self.storagePricePerByte
    }

    /// What transfers can spend: liquid balance minus the storage stake not covered by `locked`.
    public var available: BigUInt {
        let uncovered = storageStaked > locked ? storageStaked - locked : 0
        return amount > uncovered ? amount - uncovered : 0
    }

    public static func == (lhs: AccountState, rhs: AccountState) -> Bool {
        lhs.exists == rhs.exists && lhs.amount == rhs.amount && lhs.locked == rhs.locked && lhs.storageUsage == rhs.storageUsage && lhs.hasContract == rhs.hasContract
    }

    // MARK: - Record

    override public class var databaseTableName: String {
        "accountState"
    }

    enum Columns: String, ColumnExpression {
        case primaryKey, exists, amount, locked, storageUsage, hasContract
    }

    public required init(row: Row) throws {
        exists = row[Columns.exists]
        amount = try AccountState.bigUInt(row[Columns.amount], column: .amount)
        locked = try AccountState.bigUInt(row[Columns.locked], column: .locked)
        storageUsage = UInt64(bitPattern: row[Columns.storageUsage] as Int64)
        hasContract = row[Columns.hasContract]
        try super.init(row: row)
    }

    override public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.primaryKey] = primaryKey
        container[Columns.exists] = exists
        container[Columns.amount] = amount.description
        container[Columns.locked] = locked.description
        container[Columns.storageUsage] = Int64(bitPattern: storageUsage)
        container[Columns.hasContract] = hasContract
    }

    /// u128 amounts are stored as decimal text: they fit neither an SQLite integer nor a double.
    private static func bigUInt(_ text: String, column: Columns) throws -> BigUInt {
        guard let value = BigUInt(text) else {
            throw DatabaseError(message: "invalid \(column.rawValue): \(text)")
        }
        return value
    }
}
