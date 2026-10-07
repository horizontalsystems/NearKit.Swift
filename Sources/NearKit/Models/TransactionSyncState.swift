import Foundation
import GRDB

/// Where the history sync stands. A single row.
class TransactionSyncState: Record {
    private static let primaryKeyValue = "primaryKey"
    private let primaryKey: String = TransactionSyncState.primaryKeyValue

    /// Highest block height of an indexed transaction already stored.
    let lastSyncedBlockHeight: Int
    let initialSyncDone: Bool
    /// Where the walk back through older history continues; nil once it reached the first transaction.
    let backfillResumeToken: String?

    init(lastSyncedBlockHeight: Int, initialSyncDone: Bool, backfillResumeToken: String?) {
        self.lastSyncedBlockHeight = lastSyncedBlockHeight
        self.initialSyncDone = initialSyncDone
        self.backfillResumeToken = backfillResumeToken
        super.init()
    }

    // MARK: - Record

    override class var databaseTableName: String {
        "transactionSyncState"
    }

    enum Columns: String, ColumnExpression {
        case primaryKey, lastSyncedBlockHeight, initialSyncDone, backfillResumeToken
    }

    required init(row: Row) throws {
        lastSyncedBlockHeight = row[Columns.lastSyncedBlockHeight]
        initialSyncDone = row[Columns.initialSyncDone]
        backfillResumeToken = row[Columns.backfillResumeToken]
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.primaryKey] = primaryKey
        container[Columns.lastSyncedBlockHeight] = lastSyncedBlockHeight
        container[Columns.initialSyncDone] = initialSyncDone
        container[Columns.backfillResumeToken] = backfillResumeToken
    }
}
