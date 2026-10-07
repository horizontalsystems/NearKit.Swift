import Foundation
import GRDB

/// `ft_metadata` of a token contract, cached because it never changes in practice.
public class FtMetadata: Record, Equatable {
    public let contractId: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let spec: String?

    init(contractId: String, name: String, symbol: String, decimals: Int, spec: String?) {
        self.contractId = contractId
        self.name = name
        self.symbol = symbol
        self.decimals = decimals
        self.spec = spec
        super.init()
    }

    public static func == (lhs: FtMetadata, rhs: FtMetadata) -> Bool {
        lhs.contractId == rhs.contractId && lhs.name == rhs.name && lhs.symbol == rhs.symbol && lhs.decimals == rhs.decimals && lhs.spec == rhs.spec
    }

    // MARK: - Record

    override public class var databaseTableName: String {
        "ftMetadata"
    }

    enum Columns: String, ColumnExpression {
        case contractId, name, symbol, decimals, spec
    }

    public required init(row: Row) throws {
        contractId = row[Columns.contractId]
        name = row[Columns.name]
        symbol = row[Columns.symbol]
        decimals = row[Columns.decimals]
        spec = row[Columns.spec]
        try super.init(row: row)
    }

    override public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.contractId] = contractId
        container[Columns.name] = name
        container[Columns.symbol] = symbol
        container[Columns.decimals] = decimals
        container[Columns.spec] = spec
    }
}
