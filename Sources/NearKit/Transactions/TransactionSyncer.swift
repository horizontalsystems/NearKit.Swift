import Combine
import Foundation
import HsExtensions
import HsToolKit

/// Keeps the local transaction table in step with the FastNEAR history index (Android `TransactionSyncer`).
///
/// The first sync stores the newest page; each later sync fetches what is newer than the last
/// stored height and then walks one more page back through older history until it reaches the
/// account's first transaction. Pending transactions the kit submitted are resolved from the RPC,
/// because the index lags a few seconds behind the chain.
///
/// Unlike Android, the incremental fetch starts `overlapBlocks` below the cursor: the index adds a
/// row where the account only appears in a receipt or an event log a few blocks after the
/// transaction's own block, so a row can show up below a height already synced past. Rows already
/// stored with a block height are not fetched again.
final class TransactionSyncer {
    static let pageLimit = 100
    static let maxIncrementalPages = 10
    static let overlapBlocks = 300
    static let expired = "expired"

    private let accountId: String
    private let rpcApiProvider: RpcApiProvider
    private let indexerProvider: IIndexerProvider
    private let mainStorage: IMainStorage
    private let transactionStorage: ITransactionStorage
    private let logger: Logger?

    @DistinctPublished private(set) var syncState: SyncState = .notSynced(error: SyncError.notStarted)

    private let transactionsSubject = PassthroughSubject<[Transaction], Never>()

    /// Emits every batch of new or updated transactions found by a sync or created by a send.
    var transactionsPublisher: AnyPublisher<[Transaction], Never> {
        transactionsSubject.eraseToAnyPublisher()
    }

    init(accountId: String, rpcApiProvider: RpcApiProvider, indexerProvider: IIndexerProvider, mainStorage: IMainStorage, transactionStorage: ITransactionStorage, logger: Logger? = nil) {
        self.accountId = accountId
        self.rpcApiProvider = rpcApiProvider
        self.indexerProvider = indexerProvider
        self.mainStorage = mainStorage
        self.transactionStorage = transactionStorage
        self.logger = logger
    }

    /// Reports transactions saved outside a sync, such as a send's pending record.
    func publish(transactions: [Transaction]) {
        transactionsSubject.send(transactions)
    }

    func setNotStarted() {
        syncState = .notSynced(error: SyncError.notStarted)
    }

    func setNotSynced(error: Error) {
        syncState = .notSynced(error: error)
    }

    func sync(blockHeight: Int) async throws {
        let state = try mainStorage.transactionSyncState()
        let initialSyncDone = state?.initialSyncDone ?? false
        if !initialSyncDone {
            syncState = .syncing(progress: nil)
        }

        do {
            var changed = try await resolvePending(blockHeight: blockHeight)
            if let state, state.initialSyncDone {
                changed += try await incrementalSync(state: state)
            } else {
                changed += try await initialSync()
            }

            if !changed.isEmpty {
                transactionsSubject.send(changed)
            }
            syncState = .synced
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The account syncer owns the failure policy and calls setNotSynced when the failure is
            // real. Only a first sync that never completed is reported here.
            if !initialSyncDone {
                syncState = .notSynced(error: error)
            }
            throw error
        }
    }

    private func initialSync() async throws -> [Transaction] {
        let page = try await indexerProvider.accountTransactions(accountId: accountId, fromBlockHeight: nil, newestFirst: true, resumeToken: nil, limit: Self.pageLimit)
        let stored = try await store(rows: page.rows)
        try mainStorage.save(transactionSyncState: TransactionSyncState(
            lastSyncedBlockHeight: page.rows.map(\.blockHeight).max() ?? 0,
            initialSyncDone: true,
            backfillResumeToken: page.rows.count >= Self.pageLimit ? page.resumeToken : nil
        ))
        return stored
    }

    private func incrementalSync(state: TransactionSyncState) async throws -> [Transaction] {
        var stored = [Transaction]()
        var lastHeight = state.lastSyncedBlockHeight
        var resumeToken: String?
        var pages = 0

        repeat {
            // inclusive bound, and below the cursor: a block can hold several of the account's
            // transactions, and the index adds some rows a few blocks late
            let page = try await indexerProvider.accountTransactions(
                accountId: accountId,
                fromBlockHeight: max(0, state.lastSyncedBlockHeight - Self.overlapBlocks),
                newestFirst: false,
                resumeToken: resumeToken,
                limit: Self.pageLimit
            )
            stored += try await store(rows: page.rows)
            lastHeight = max(lastHeight, page.rows.map(\.blockHeight).max() ?? lastHeight)
            resumeToken = page.rows.count >= Self.pageLimit ? page.resumeToken : nil
            pages += 1
        } while resumeToken != nil && pages < Self.maxIncrementalPages

        var backfillToken = state.backfillResumeToken
        if let token = backfillToken {
            let page = try await indexerProvider.accountTransactions(accountId: accountId, fromBlockHeight: nil, newestFirst: true, resumeToken: token, limit: Self.pageLimit)
            stored += try await store(rows: page.rows)
            backfillToken = page.rows.count >= Self.pageLimit ? page.resumeToken : nil
        }

        try mainStorage.save(transactionSyncState: TransactionSyncState(lastSyncedBlockHeight: lastHeight, initialSyncDone: true, backfillResumeToken: backfillToken))
        return stored
    }

    /// Fetches and stores the rows not already stored from the index. Returns the new or updated records.
    private func store(rows: [AccountTxRow]) async throws -> [Transaction] {
        guard !rows.isEmpty else {
            return []
        }
        let indexed = try transactionStorage.indexedHashes(rows.map(\.hash))
        var seen = Set<String>()
        let wanted = rows.filter { !indexed.contains($0.hash) && seen.insert($0.hash).inserted }
        var timestamps = [String: Int]()
        for row in wanted {
            timestamps[row.hash] = Int(row.blockTimestampNanos / 1_000_000_000)
        }

        var result = [Transaction]()
        for start in stride(from: 0, to: wanted.count, by: FastNearProvider.maxHashesPerRequest) {
            let chunk = wanted[start ..< min(start + FastNearProvider.maxHashesPerRequest, wanted.count)]
            let items = try await indexerProvider.transactions(hashes: chunk.map(\.hash))
            let converted: [(Transaction, Set<String>)] = items.compactMap { item in
                do {
                    let hash = item.object("transaction")?.string("hash")
                    return try TransactionConverter.convert(item: item, accountId: accountId, fallbackTimestamp: hash.flatMap { timestamps[$0] } ?? 0)
                } catch {
                    logger?.warning("Skipping unreadable transaction: \(error)")
                    return nil
                }
            }
            try transactionStorage.save(transactions: converted)
            result += converted.map(\.0)
        }
        return result
    }

    /// Resolves transactions the kit submitted: executed ones are replaced by their outcome. One that
    /// neither the node nor the index knows once the chain has passed its validity window is marked
    /// failed. The node alone is not enough: it answers UNKNOWN_TRANSACTION for transactions older
    /// than its garbage collection window, and a "failed" send invites sending again.
    private func resolvePending(blockHeight: Int) async throws -> [Transaction] {
        var resolved = [Transaction]()

        for pending in try transactionStorage.pendingTransactions() {
            let status: TxStatus?
            do {
                status = try await rpcApiProvider.transactionStatus(hash: pending.hash, senderAccountId: pending.signerId)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }

            let updated: (Transaction, Set<String>)
            if let status, status.isExecuted, let raw = status.raw {
                let (transaction, tags) = try TransactionConverter.convert(item: raw, accountId: accountId, fallbackTimestamp: pending.timestamp)
                // RPC outcomes carry no block time; keep the submission time until the index has it
                updated = (transaction.copy(timestamp: pending.timestamp), tags)
            } else if status == nil, let expiresAfterHeight = pending.expiresAfterHeight, blockHeight > expiresAfterHeight {
                let indexed: RpcJson?
                do {
                    indexed = try await indexerProvider.transactions(hashes: [pending.hash]).first { $0.object("transaction")?.lenientString("hash") == pending.hash }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
                if let indexed {
                    updated = try TransactionConverter.convert(item: indexed, accountId: accountId, fallbackTimestamp: pending.timestamp)
                } else {
                    updated = (pending.copy(status: .failed, failure: Self.expired), TransactionConverter.tags(transaction: pending, accountId: accountId))
                }
            } else {
                continue
            }

            if updated.0.isPending {
                continue
            }
            try transactionStorage.save(transactions: [updated])
            resolved.append(updated.0)
        }

        return resolved
    }
}
