import BigInt
import Combine
import Foundation
import HsExtensions
import HsToolKit

/// Drives one sync cycle per timer tick: latest block, account state, token balances, then
/// transaction history (Android `Syncer`). The single writer to the main tables.
///
/// A failure in any step makes both the account and the history not synced, as in Android; only a
/// failed token list from the index keeps the previous list. Unlike Android, token balances are
/// synced whether or not the account exists: a token can be sent to an implicit account that never
/// received NEAR, and NEP-141 keeps the balance anyway.
final class SyncManager {
    private static let maxToleratedFailures = 2
    private static let transientRetryDelay: TimeInterval = 3

    private let accountId: String
    private let apiSyncer: ApiSyncer
    private let rpcApiProvider: RpcApiProvider
    private let indexerProvider: IIndexerProvider
    private let transactionSyncer: TransactionSyncer
    private let storage: IMainStorage
    private let logger: Logger?

    @DistinctPublished private(set) var syncState: SyncState = .notSynced(error: SyncError.notStarted)
    @DistinctPublished private(set) var chainState: ChainState?
    @DistinctPublished private(set) var accountState: AccountState
    @DistinctPublished private(set) var ftBalances: [FtBalance]

    private let lock = NSLock()
    private var syncing = false
    private var started = false
    private var _watchedTokens = Set<String>()

    // A connectivity blip right after the app resumes fails one cycle and clears itself within
    // seconds. Once the kit has synced successfully, the first transient failure keeps the
    // current state and retries shortly; only a repeated failure is reported.
    private var hasSyncedOnce = false
    private var consecutiveFailures = 0

    private var tasks = Set<AnyTask>()

    init(accountId: String, apiSyncer: ApiSyncer, rpcApiProvider: RpcApiProvider, indexerProvider: IIndexerProvider, transactionSyncer: TransactionSyncer, storage: IMainStorage, logger: Logger? = nil) throws {
        self.accountId = accountId
        self.apiSyncer = apiSyncer
        self.rpcApiProvider = rpcApiProvider
        self.indexerProvider = indexerProvider
        self.transactionSyncer = transactionSyncer
        self.storage = storage
        self.logger = logger

        chainState = try storage.chainState()
        accountState = try storage.accountState() ?? .empty
        ftBalances = try storage.ftBalances()

        apiSyncer.delegate = self
    }

    /// Token contracts whose balance is read from the RPC even when the index does not list them.
    var watchedTokens: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _watchedTokens
        }
        set {
            lock.lock()
            _watchedTokens = newValue
            lock.unlock()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        apiSyncer.start()
    }

    func stop() {
        started = false
        tasks = Set()
        apiSyncer.stop()
        syncState = .notSynced(error: SyncError.notStarted)
        transactionSyncer.setNotStarted()
    }

    func pause() {
        apiSyncer.pause()
    }

    func resume() {
        apiSyncer.resume()
    }

    /// Runs a cycle now if the poller is ready; a stopped poller is restarted instead. Pausing only
    /// stops the timer, so a refresh while paused still runs a cycle (as Android and XrpKit do).
    func refresh() {
        guard started else { return }

        switch apiSyncer.state {
        case .ready:
            sync()
        case .notReady:
            apiSyncer.stop()
            apiSyncer.start()
        }
    }

    /// Runs a full cycle now, outside the timer (after a send).
    func syncNow() async {
        guard acquire() else { return }
        defer { release() }
        await performSync()
    }

    private func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if syncing {
            return false
        }
        syncing = true
        return true
    }

    private func release() {
        lock.lock()
        syncing = false
        lock.unlock()
    }

    private func performSync() async {
        do {
            let block = try await rpcApiProvider.latestBlock()
            let chainState = ChainState(blockHeight: block.height, gasPrice: block.gasPrice)
            if chainState != self.chainState {
                try storage.save(chainState: chainState)
                self.chainState = chainState
            }

            let view = try await rpcApiProvider.viewAccount(accountId: accountId)
            let accountState = view.map {
                AccountState(exists: true, amount: $0.amount, locked: $0.locked, storageUsage: $0.storageUsage, hasContract: $0.hasContract)
            } ?? .empty
            if accountState != self.accountState {
                try storage.save(accountState: accountState)
                self.accountState = accountState
            }

            try await syncFtBalances()

            try await transactionSyncer.sync(blockHeight: block.height)

            hasSyncedOnce = true
            consecutiveFailures = 0
            syncState = .synced
        } catch is CancellationError {
            return
        } catch {
            consecutiveFailures += 1
            let tolerate = hasSyncedOnce && consecutiveFailures < Self.maxToleratedFailures && NetworkErrors.isTransient(error)
            if tolerate {
                Task { [weak self] in
                    try await Task.sleep(nanoseconds: UInt64(Self.transientRetryDelay * 1_000_000_000))
                    self?.sync()
                }.store(in: &tasks)
            } else {
                syncState = .notSynced(error: error)
                transactionSyncer.setNotSynced(error: error)
            }
        }
    }

    /// The index lists every token the account ever touched; watched tokens are read from the
    /// contracts themselves, which is authoritative and not subject to index lag. An index outage
    /// keeps the previous list instead of failing the whole sync.
    private func syncFtBalances() async throws {
        var contractIds = [String]()
        var balances = [String: BigUInt]()
        func put(_ contractId: String, _ balance: BigUInt) {
            if balances.updateValue(balance, forKey: contractId) == nil {
                contractIds.append(contractId)
            }
        }

        do {
            for info in try await indexerProvider.ftBalances(accountId: accountId) {
                put(info.contractId, info.balance)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger?.warning("FastNEAR token list failed: \(error)")
            for balance in ftBalances {
                put(balance.contractId, balance.balance)
            }
        }

        let args = try FtActions.accountIdArgs(accountId)
        for contractId in watchedTokens.sorted() {
            do {
                let result = try await rpcApiProvider.callFunctionJson(contractId: contractId, methodName: "ft_balance_of", argsJson: args)
                if let balance = RpcJson.lenientBigUInt(result) {
                    put(contractId, balance)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger?.warning("ft_balance_of failed for \(contractId): \(error)")
            }
        }

        let list = contractIds.compactMap { contractId in balances[contractId].map { FtBalance(contractId: contractId, balance: $0) } }
        if list != ftBalances {
            try storage.replace(ftBalances: list)
            ftBalances = list
        }
    }
}

extension SyncManager: IApiSyncerDelegate {
    func didUpdateSyncerState(_ state: SyncerState) {
        switch state {
        case .ready:
            syncState = .syncing(progress: nil)
        case let .notReady(error):
            transactionSyncer.setNotSynced(error: error)
            syncState = .notSynced(error: error)
        }
    }

    func sync() {
        guard started, acquire() else { return }

        Task { [weak self] in
            guard let self else { return }
            defer { self.release() }
            await performSync()
        }.store(in: &tasks)
    }
}
