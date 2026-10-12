import Foundation
import GRDB

/// The transaction table, keyed by hash with REPLACE, so the indexed record takes the place of the
/// pending one the kit wrote for the same hash, plus the token tags each transaction is listed under.
final class TransactionStorage {
    private static let hashChunkSize = 500

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) throws {
        self.dbPool = dbPool
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createTransactions") { db in
            try db.create(table: Transaction.databaseTableName) { t in
                t.column(Transaction.Columns.hash.name, .text).notNull()
                t.column(Transaction.Columns.blockHeight.name, .integer)
                t.column(Transaction.Columns.timestamp.name, .integer).notNull()
                t.column(Transaction.Columns.signerId.name, .text).notNull()
                t.column(Transaction.Columns.receiverId.name, .text).notNull()
                t.column(Transaction.Columns.actions.name, .text).notNull()
                t.column(Transaction.Columns.nearTransfers.name, .text).notNull()
                t.column(Transaction.Columns.ftTransfers.name, .text).notNull()
                t.column(Transaction.Columns.fee.name, .text)
                t.column(Transaction.Columns.status.name, .text).notNull()
                t.column(Transaction.Columns.failure.name, .text)
                t.column(Transaction.Columns.expiresAfterHeight.name, .integer)
                t.primaryKey([Transaction.Columns.hash.name], onConflict: .replace)
            }
            try db.create(index: "transaction_timestamp", on: Transaction.databaseTableName, columns: [Transaction.Columns.timestamp.name])

            try db.create(table: TransactionTagRecord.databaseTableName) { t in
                t.column(TransactionTagRecord.Columns.hash.name, .text).notNull()
                t.column(TransactionTagRecord.Columns.token.name, .text).notNull()
                t.primaryKey([TransactionTagRecord.Columns.hash.name, TransactionTagRecord.Columns.token.name], onConflict: .replace)
            }
            try db.create(index: "transactionTag_token", on: TransactionTagRecord.databaseTableName, columns: [TransactionTagRecord.Columns.token.name])
        }

        return migrator
    }
}

extension TransactionStorage: ITransactionStorage {
    func save(transactions: [(Transaction, Set<String>)]) throws {
        try dbPool.write { db in
            for (transaction, tags) in transactions {
                try transaction.save(db)
                try TransactionTagRecord.filter(TransactionTagRecord.Columns.hash == transaction.hash).deleteAll(db)
                for token in tags {
                    try TransactionTagRecord(hash: transaction.hash, token: token).insert(db)
                }
            }
        }
    }

    func transaction(hash: String) throws -> Transaction? {
        try dbPool.read { db in
            try Transaction.filter(Transaction.Columns.hash == hash).fetchOne(db)
        }
    }

    func pendingTransactions() throws -> [Transaction] {
        try dbPool.read { db in
            try Transaction.filter(Transaction.Columns.status == Transaction.Status.pending.rawValue).fetchAll(db)
        }
    }

    /// Hashes the index need not be asked for again. Records built from the RPC or predicted at send
    /// time have no block height yet, and a pending record from the index was still executing; the
    /// index fills both in.
    func indexedHashes(_ hashes: [String]) throws -> Set<String> {
        try dbPool.read { db in
            var indexed = Set<String>()
            for start in stride(from: 0, to: hashes.count, by: Self.hashChunkSize) {
                let chunk = Array(hashes[start ..< min(start + Self.hashChunkSize, hashes.count)])
                let found = try String.fetchAll(
                    db,
                    Transaction
                        .select(Transaction.Columns.hash)
                        .filter(
                            chunk.contains(Transaction.Columns.hash) && Transaction.Columns.blockHeight != nil &&
                                Transaction.Columns.status != Transaction.Status.pending.rawValue
                        )
                )
                indexed.formUnion(found)
            }
            return indexed
        }
    }

    func transactions(token: String?, beforeTimestamp: Int?, beforeHash: String?, limit: Int) throws -> [Transaction] {
        try dbPool.read { db in
            let table = Transaction.databaseTableName
            let timestamp = Transaction.Columns.timestamp.name
            let hash = Transaction.Columns.hash.name
            var arguments = StatementArguments()
            var sql = "SELECT t.* FROM \(table) t"

            if let token {
                sql += " INNER JOIN \(TransactionTagRecord.databaseTableName) g ON g.\(TransactionTagRecord.Columns.hash.name) = t.\(hash) WHERE g.\(TransactionTagRecord.Columns.token.name) = ?"
                arguments += [token]
            } else {
                sql += " WHERE 1"
            }

            // ties on timestamp are broken by hash so that paging with (timestamp, hash) is stable;
            // without a hash everything at beforeTimestamp is excluded ("" sorts before any hash)
            if let beforeTimestamp {
                sql += " AND (t.\(timestamp) < ? OR (t.\(timestamp) = ? AND t.\(hash) < ?))"
                arguments += [beforeTimestamp, beforeTimestamp, beforeHash ?? ""]
            }

            sql += " ORDER BY t.\(timestamp) DESC, t.\(hash) DESC LIMIT ?"
            arguments += [limit]

            return try Transaction.fetchAll(db, sql: sql, arguments: arguments)
        }
    }
}
