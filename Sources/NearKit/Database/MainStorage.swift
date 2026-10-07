import Foundation
import GRDB

/// Single-row tables for the account, the chain and the history sync cursor, plus token balances
/// and token metadata (Android `MainDatabase` entities other than transactions).
final class MainStorage {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) throws {
        self.dbPool = dbPool
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createMainTables") { db in
            try db.create(table: AccountState.databaseTableName) { t in
                t.column(AccountState.Columns.primaryKey.name, .text).notNull()
                t.column(AccountState.Columns.exists.name, .boolean).notNull()
                t.column(AccountState.Columns.amount.name, .text).notNull()
                t.column(AccountState.Columns.locked.name, .text).notNull()
                t.column(AccountState.Columns.storageUsage.name, .integer).notNull()
                t.column(AccountState.Columns.hasContract.name, .boolean).notNull()
                t.primaryKey([AccountState.Columns.primaryKey.name], onConflict: .replace)
            }

            try db.create(table: ChainState.databaseTableName) { t in
                t.column(ChainState.Columns.primaryKey.name, .text).notNull()
                t.column(ChainState.Columns.blockHeight.name, .integer).notNull()
                t.column(ChainState.Columns.gasPrice.name, .text).notNull()
                t.primaryKey([ChainState.Columns.primaryKey.name], onConflict: .replace)
            }

            try db.create(table: FtBalance.databaseTableName) { t in
                t.column(FtBalance.Columns.contractId.name, .text).notNull()
                t.column(FtBalance.Columns.balance.name, .text).notNull()
                t.primaryKey([FtBalance.Columns.contractId.name], onConflict: .replace)
            }

            try db.create(table: FtMetadata.databaseTableName) { t in
                t.column(FtMetadata.Columns.contractId.name, .text).notNull()
                t.column(FtMetadata.Columns.name.name, .text).notNull()
                t.column(FtMetadata.Columns.symbol.name, .text).notNull()
                t.column(FtMetadata.Columns.decimals.name, .integer).notNull()
                t.column(FtMetadata.Columns.spec.name, .text)
                t.primaryKey([FtMetadata.Columns.contractId.name], onConflict: .replace)
            }

            try db.create(table: TransactionSyncState.databaseTableName) { t in
                t.column(TransactionSyncState.Columns.primaryKey.name, .text).notNull()
                t.column(TransactionSyncState.Columns.lastSyncedBlockHeight.name, .integer).notNull()
                t.column(TransactionSyncState.Columns.initialSyncDone.name, .boolean).notNull()
                t.column(TransactionSyncState.Columns.backfillResumeToken.name, .text)
                t.primaryKey([TransactionSyncState.Columns.primaryKey.name], onConflict: .replace)
            }
        }

        return migrator
    }
}

extension MainStorage: IMainStorage {
    func accountState() throws -> AccountState? {
        try dbPool.read { db in
            try AccountState.fetchOne(db)
        }
    }

    func save(accountState: AccountState) throws {
        try dbPool.write { db in
            try accountState.save(db)
        }
    }

    func chainState() throws -> ChainState? {
        try dbPool.read { db in
            try ChainState.fetchOne(db)
        }
    }

    func save(chainState: ChainState) throws {
        try dbPool.write { db in
            try chainState.save(db)
        }
    }

    func ftBalances() throws -> [FtBalance] {
        try dbPool.read { db in
            // insertion order: the index's order, then watched tokens
            try FtBalance.order(Column.rowID).fetchAll(db)
        }
    }

    func replace(ftBalances: [FtBalance]) throws {
        try dbPool.write { db in
            try FtBalance.deleteAll(db)
            for balance in ftBalances {
                try balance.insert(db)
            }
        }
    }

    func ftMetadata(contractId: String) throws -> FtMetadata? {
        try dbPool.read { db in
            try FtMetadata.filter(FtMetadata.Columns.contractId == contractId).fetchOne(db)
        }
    }

    func save(ftMetadata: FtMetadata) throws {
        try dbPool.write { db in
            try ftMetadata.save(db)
        }
    }

    func transactionSyncState() throws -> TransactionSyncState? {
        try dbPool.read { db in
            try TransactionSyncState.fetchOne(db)
        }
    }

    func save(transactionSyncState: TransactionSyncState) throws {
        try dbPool.write { db in
            try transactionSyncState.save(db)
        }
    }
}
