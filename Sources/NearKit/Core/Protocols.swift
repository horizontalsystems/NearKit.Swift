import Combine
import Foundation

/// Reachability as the other kits see it: HsToolKit `ReachabilityManager` in production, a stub in
/// tests. The value is known synchronously at creation, so the first `start()` decides on the real
/// status, not a placeholder.
protocol IConnectionManager {
    var isConnected: Bool { get }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { get }
}

/// Reads throw like writes do: a failed read means the database itself is broken, and answering
/// "no state" would show a funded wallet as empty and send the sync back to the beginning.
protocol IMainStorage {
    func accountState() throws -> AccountState?
    func save(accountState: AccountState) throws
    func chainState() throws -> ChainState?
    func save(chainState: ChainState) throws
    func ftBalances() throws -> [FtBalance]
    /// Replaces the whole list in one database transaction.
    func replace(ftBalances: [FtBalance]) throws
    func ftMetadata(contractId: String) throws -> FtMetadata?
    func save(ftMetadata: FtMetadata) throws
    func transactionSyncState() throws -> TransactionSyncState?
    func save(transactionSyncState: TransactionSyncState) throws
}

protocol ITransactionStorage {
    /// Each transaction with the tokens it is listed under, written with its tags in one database transaction.
    func save(transactions: [(Transaction, Set<String>)]) throws
    func transaction(hash: String) throws -> Transaction?
    func pendingTransactions() throws -> [Transaction]
    /// The hashes of `hashes` stored with a block height: records built from the RPC or predicted
    /// at send time have none yet, and the index fills it in.
    func indexedHashes(_ hashes: [String]) throws -> Set<String>
    /// Newest first, ordered by (timestamp, hash). `token` is nil for all transactions.
    func transactions(token: String?, beforeTimestamp: Int?, beforeHash: String?, limit: Int) throws -> [Transaction]
}

/// The history and token index (FastNEAR), the second provider next to the RPC (TronKit `IHistoryProvider` form).
protocol IIndexerProvider {
    func ftBalances(accountId: String) async throws -> [FtBalanceInfo]
    /// Accounts the indexer believes hold `publicKey` as a full-access key. Verify before trusting.
    func accountIds(publicKey: String) async throws -> [String]
    /// One page of transactions touching `accountId`: signed by it, received by it, or naming it in
    /// an event log (token transfers). `fromBlockHeight` is inclusive.
    func accountTransactions(accountId: String, fromBlockHeight: Int?, newestFirst: Bool, resumeToken: String?, limit: Int) async throws -> AccountTxPage
    /// Full transactions with receipts and outcomes, at most `FastNearProvider.maxHashesPerRequest` per call.
    func transactions(hashes: [String]) async throws -> [RpcJson]
}

/// Readiness of the polling loop, separate from the public `SyncState`.
enum SyncerState: Equatable {
    case ready
    case notReady(error: Error)

    static func == (lhs: SyncerState, rhs: SyncerState) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready): return true
        case let (.notReady(lhsError), .notReady(rhsError)): return "\(lhsError)" == "\(rhsError)"
        default: return false
        }
    }
}

protocol IApiSyncerDelegate: AnyObject {
    func didUpdateSyncerState(_ state: SyncerState)
    /// One timer tick: run a sync cycle.
    func sync()
}
