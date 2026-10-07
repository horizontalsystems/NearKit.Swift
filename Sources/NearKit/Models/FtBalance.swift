import BigInt
import Foundation
import GRDB

/// A NEP-141 token balance of the kit's account.
public class FtBalance: Record, Equatable {
    public let contractId: String
    /// In the token's smallest unit; divide by 10^decimals from `FtMetadata`.
    public let balance: BigUInt

    public init(contractId: String, balance: BigUInt) {
        self.contractId = contractId
        self.balance = balance
        super.init()
    }

    public static func == (lhs: FtBalance, rhs: FtBalance) -> Bool {
        lhs.contractId == rhs.contractId && lhs.balance == rhs.balance
    }

    // MARK: - Record

    override public class var databaseTableName: String {
        "ftBalance"
    }

    enum Columns: String, ColumnExpression {
        case contractId, balance
    }

    public required init(row: Row) throws {
        contractId = row[Columns.contractId]
        let balance: String = row[Columns.balance]
        guard let value = BigUInt(balance) else {
            throw DatabaseError(message: "invalid balance: \(balance)")
        }
        self.balance = value
        try super.init(row: row)
    }

    override public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.contractId] = contractId
        container[Columns.balance] = balance.description
    }
}
