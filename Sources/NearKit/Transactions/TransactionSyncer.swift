import Combine
import Foundation
import HsExtensions
import HsToolKit

/// Keeps the local transaction table in step with the FastNEAR history index (Android `TransactionSyncer`).
///
/// The first sync stores the newest page; each later sync fetches what is newer than the last
/// stored height and then walks one more page back through older history until it reaches the
/// account's first transaction. Pending transactions are resolved from the RPC, because the index
/// lags a few seconds behind the chain and serves transactions before they finish executing.
///
/// The incremental fetch starts `reindexWindowBlocks` below the cursor: the index files a
/// transaction under the block it was submitted in, but adds the row for an account only when a
/// receipt touching that account executes, which can be many blocks later. Stored hashes are not
/// fetched again.
///
/// History is optional to the rest of the kit: a failure here sets only this syncer's state, and a
/// rate limit from the index pauses history syncs instead of retrying into it.
final class TransactionSyncer {
    static let pageLimit = 100
    static let maxIncrementalPages = 10
    /// About three minutes at 0.6 s blocks; covers the 200-block yield/resume timeout and long cross-contract flows.
    static let reindexWindowBlocks = 300
    static let maxToleratedFailures = 3
    static let minBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 300
    static let expired = "expired"

    private let accountId: String
    private let rpcApiProvider: RpcApiProvider
    private let indexerProvider: IIndexerProvider
    private let mainStorage: IMainStorage
    private let transactionStorage: ITransactionStorage
    private let logger: Logger?
    private let now: () -> Date

    private var consecutiveFailures = 0
    private var backoffUntil = Date.distantPast
    private var backoff: TimeInterval = 0

    @DistinctPublished private(set) var syncState: SyncState = .notSynced(error: SyncError.notStarted)

    private let transactionsSubject = PassthroughSubject<[Transaction], Never>()

    /// Emits every batch of new or updated transactions found by a sync or created by a send.
    var transactionsPublisher: AnyPublisher<[Transaction], Never> {
        transactionsSubject.eraseToAnyPublisher()
    }

    init(
        accountId: String, rpcApiProvider: RpcApiProvider, indexerProvider: IIndexerProvider, mainStorage: IMainStorage, transactionStorage: ITransactionStorage,
        logger: Logger? = nil, now: @escaping () -> Date = Date.init
    ) {
        self.accountId = accountId
        self.rpcApiProvider = rpcApiProvider
        self.indexerProvider = indexerProvider
        self.mainStorage = mainStorage
        self.transactionStorage = transactionStorage
        self.logger = logger
        self.now = now
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

    /// Never throws except on cancellation; failures are reported through `syncState`.
    func sync(blockHeight: Int) async throws {
        do {
            let state = try mainStorage.transactionSyncState()
            let initialSyncDone = state?.initialSyncDone ?? false
            if !initialSyncDone {
                syncState = .syncing(progress: nil)
            }

            // the node still resolves sends while the index is rate limited
            let indexPaused = now() < backoffUntil
            // emitted on their own: a send resolved over the RPC must show even when the index fails next
            let resolved = try await resolvePending(blockHeight: blockHeight, useIndex: !indexPaused)
            emit(resolved)
            if indexPaused {
                return
            }
            let stored: [Transaction]
            if let state, initialSyncDone {
                stored = try await incrementalSync(state: state)
            } else {
                stored = try await initialSync()
            }
            emit(stored)

            consecutiveFailures = 0
            backoff = 0
            syncState = .synced
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            consecutiveFailures += 1
            if NetworkErrors.isRateLimited(error) {
                // HsToolKit keeps no response headers, so no Retry-After as on Android: doubling from 30 s
                backoff = min(max(backoff * 2, Self.minBackoff), Self.maxBackoff)
                backoffUntil = now().addingTimeInterval(backoff)
            }
            logger?.warning("Transaction sync failed: \(error)")
            // after a successful sync a blip keeps the synced state; anything else is reported
            let tolerate = syncState == .synced && NetworkErrors.isTransient(error) && consecutiveFailures < Self.maxToleratedFailures
            if !tolerate {
                syncState = .notSynced(error: error)
            }
        }
    }

    private func emit(_ transactions: [Transaction]) {
        if !transactions.isEmpty {
            transactionsSubject.send(transactions)
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
            let page = try await indexerProvider.accountTransactions(
                accountId: accountId,
                fromBlockHeight: max(0, state.lastSyncedBlockHeight - Self.reindexWindowBlocks),
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

        let converted = try await fetch(hashes: wanted.map(\.hash)) { timestamps[$0] ?? 0 }
        try transactionStorage.save(transactions: converted)
        return converted.map(\.0)
    }

    /// Transactions for `hashes` from the index; hashes the index does not have are left out.
    private func fetch(hashes: [String], fallbackTimestamp: (String) -> Int) async throws -> [(Transaction, Set<String>)] {
        var result = [(Transaction, Set<String>)]()
        for start in stride(from: 0, to: hashes.count, by: FastNearProvider.maxHashesPerRequest) {
            let chunk = Array(hashes[start ..< min(start + FastNearProvider.maxHashesPerRequest, hashes.count)])
            let items = try await indexerProvider.transactions(hashes: chunk)
            for (hash, item) in Self.mostComplete(items) {
                do {
                    result.append(try TransactionConverter.convert(item: item, accountId: accountId, fallbackTimestamp: fallbackTimestamp(hash)))
                } catch {
                    logger?.warning("Skipping unreadable transaction: \(error)")
                }
            }
        }
        return result
    }

    /// One item per hash, in first-seen order. While a transaction is executing the index can return
    /// several snapshots of it in one response, in no particular order; the one with the most
    /// receipts is the latest.
    static func mostComplete(_ items: [RpcJson]) -> [(String, RpcJson)] {
        var order = [String]()
        var best = [String: RpcJson]()
        for item in items {
            guard let hash = item.object("transaction")?.lenientString("hash") else {
                continue
            }
            guard let current = best[hash] else {
                order.append(hash)
                best[hash] = item
                continue
            }
            if (item.array("receipts")?.count ?? 0) > (current.array("receipts")?.count ?? 0) {
                best[hash] = item
            }
        }
        return order.compactMap { hash in best[hash].map { (hash, $0) } }
    }

    /// Resolves transactions the kit submitted: executed ones are replaced by their outcome. One that
    /// neither the node nor the index knows once the chain has passed its validity window is marked
    /// failed. The node alone is not enough: it answers UNKNOWN_TRANSACTION for transactions older
    /// than its garbage collection window, and a "failed" send invites sending again.
    private func resolvePending(blockHeight: Int, useIndex: Bool) async throws -> [Transaction] {
        var resolved = [Transaction]()
        var unresolvedFromIndex = [Transaction]()

        for pending in try transactionStorage.pendingTransactions() {
            if pending.blockHeight != nil {
                unresolvedFromIndex.append(pending)
            }
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
                guard useIndex else {
                    continue
                }
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
            unresolvedFromIndex.removeAll { $0.hash == pending.hash }
        }

        if useIndex {
            resolved += try await refetchFromIndex(pending: unresolvedFromIndex)
        }
        return resolved
    }

    /// Records the index served while they were still executing, that the node could not resolve:
    /// it may have pruned them, or a failover node may not know them. The index has them by now.
    private func refetchFromIndex(pending: [Transaction]) async throws -> [Transaction] {
        guard !pending.isEmpty else {
            return []
        }
        var timestamps = [String: Int]()
        for transaction in pending {
            timestamps[transaction.hash] = transaction.timestamp
        }
        do {
            let finished = try await fetch(hashes: pending.map(\.hash)) { timestamps[$0] ?? 0 }.filter { !$0.0.isPending }
            try transactionStorage.save(transactions: finished)
            return finished.map(\.0)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }
}
