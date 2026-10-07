import BigInt
import Foundation
import GRDB

/// Latest final block seen and the gas price in it. A single row.
class ChainState: Record, Equatable {
    private static let primaryKeyValue = "primaryKey"
    private let primaryKey: String = ChainState.primaryKeyValue

    let blockHeight: Int
    /// yoctoNEAR per gas unit.
    let gasPrice: BigUInt

    init(blockHeight: Int, gasPrice: BigUInt) {
        self.blockHeight = blockHeight
        self.gasPrice = gasPrice
        super.init()
    }

    static func == (lhs: ChainState, rhs: ChainState) -> Bool {
        lhs.blockHeight == rhs.blockHeight && lhs.gasPrice == rhs.gasPrice
    }

    // MARK: - Record

    override class var databaseTableName: String {
        "chainState"
    }

    enum Columns: String, ColumnExpression {
        case primaryKey, blockHeight, gasPrice
    }

    required init(row: Row) throws {
        blockHeight = row[Columns.blockHeight]
        let gasPrice: String = row[Columns.gasPrice]
        guard let value = BigUInt(gasPrice) else {
            throw DatabaseError(message: "invalid gasPrice: \(gasPrice)")
        }
        self.gasPrice = value
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.primaryKey] = primaryKey
        container[Columns.blockHeight] = blockHeight
        container[Columns.gasPrice] = gasPrice.description
    }
}
