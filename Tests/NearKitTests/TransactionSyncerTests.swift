import Combine
@testable import NearKit
import XCTest

final class TransactionSyncerTests: XCTestCase {
    private var near: FakeNear!
    private var indexedItem: RpcJson!
    private var pendingHash: String!
    private var accountId: String!
    private var syncer: TransactionSyncer!

    override func setUpWithError() throws {
        near = try FakeNear()
        indexedItem = try Fixtures.objects(Fixtures.json("fastnear-transactions"), "transactions")[0]
        let transaction = try XCTUnwrap(indexedItem.object("transaction"))
        pendingHash = try transaction.text("hash")
        accountId = try transaction.text("signer_id")
        syncer = TransactionSyncer(accountId: accountId, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider, mainStorage: near.mainStorage, transactionStorage: near.transactionStorage)
    }

    override func tearDown() {
        near.assertNoUnexpectedRequests()
        super.tearDown()
    }

    private func sync(blockHeight: Int = 1000) async throws {
        try await syncer.sync(blockHeight: blockHeight)
    }

    private func stored(_ hash: String) throws -> Transaction? {
        try near.transactionStorage.transaction(hash: hash)
    }

    /// The fixture's token transfer under another hash and block height.
    private func item(hash: String, height: Int) -> RpcJson {
        var item = indexedItem!
        var transaction = item.object("transaction")!
        transaction["hash"] = hash
        item["transaction"] = transaction
        var outcome = item.object("execution_outcome")!
        outcome["block_height"] = height
        item["execution_outcome"] = outcome
        return item
    }

    private func savePending(expiresAfterHeight: Int = 100) throws {
        let pending = Transaction(
            hash: pendingHash, blockHeight: nil, timestamp: 1, signerId: accountId, receiverId: "usdt.tether-token.near", actions: [],
            nearTransfers: [], ftTransfers: [], fee: nil, status: .pending, failure: nil, expiresAfterHeight: expiresAfterHeight
        )
        try near.transactionStorage.save(transactions: [(pending, Set([TransactionTag.tokenNative]))])
    }

    private func saveSyncState(lastSyncedBlockHeight: Int, backfillResumeToken: String? = nil) throws {
        try near.mainStorage.save(transactionSyncState: TransactionSyncState(lastSyncedBlockHeight: lastSyncedBlockHeight, initialSyncDone: true, backfillResumeToken: backfillResumeToken))
    }

    private func accountRequests() -> [RpcJson] {
        near.indexer.requests("/v0/account").compactMap(\.body)
    }

    // MARK: - Android TransactionSyncerTest

    // A pending send past its validity window is only marked failed when the index does not have it either.
    private func setUpExpiredPending() throws {
        try saveSyncState(lastSyncedBlockHeight: 1)
        try savePending()
        // the node has forgotten it, and the history index has nothing new
        near.rpc.answer("EXPERIMENTAL_tx_status", .error(cause: "UNKNOWN_TRANSACTION"))
        near.indexer.answer("/v0/account", .json(["account_txs": []]))
    }

    func testIndexedTransactionIsNotMarkedExpired() async throws {
        try setUpExpiredPending()
        near.indexer.answer("/v0/transactions", .json(["transactions": [indexedItem!]]))

        try await sync()

        let stored = try XCTUnwrap(stored(pendingHash))
        XCTAssertNil(stored.failure)
        XCTAssertNotNil(stored.blockHeight)
        XCTAssertTrue(stored.isSuccess)
    }

    func testTransactionUnknownEverywhereIsMarkedExpired() async throws {
        try setUpExpiredPending()
        near.indexer.answer("/v0/transactions", .json(["transactions": []]))

        try await sync()

        let stored = try XCTUnwrap(stored(pendingHash))
        XCTAssertTrue(stored.isFailed)
        XCTAssertEqual(stored.failure, TransactionSyncer.expired)
    }

    func testStaysPendingWhileIndexIsUnreachable() async throws {
        try setUpExpiredPending()
        near.indexer.answer("/v0/transactions", .failure(URLError(.timedOut)))

        try await sync()

        XCTAssertEqual(try stored(pendingHash)?.isPending, true)
    }

    // MARK: - iOS: pending resolution

    // An executed send is replaced by its outcome, keeping the submission time until the index has the block time.
    func testExecutedPendingIsResolvedFromTheNode() async throws {
        let rpc = try Fixtures.json("rpc-tx-status")
        let rpcHash = try XCTUnwrap(rpc.object("transaction")).text("hash")
        let signerId = try XCTUnwrap(rpc.object("transaction")).text("signer_id")
        syncer = TransactionSyncer(accountId: signerId, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider, mainStorage: near.mainStorage, transactionStorage: near.transactionStorage)
        let pending = Transaction(
            hash: rpcHash, blockHeight: nil, timestamp: 77, signerId: signerId, receiverId: "x.near", actions: [],
            nearTransfers: [], ftTransfers: [], fee: nil, status: .pending, failure: nil, expiresAfterHeight: 100_000
        )
        try near.transactionStorage.save(transactions: [(pending, Set([TransactionTag.tokenNative]))])
        try saveSyncState(lastSyncedBlockHeight: 1)
        near.rpc.answer("EXPERIMENTAL_tx_status", .result(rpc))
        near.indexer.answer("/v0/account", .json(["account_txs": []]))

        var published = [[Transaction]]()
        let cancellable = syncer.transactionsPublisher.sink { published.append($0) }
        defer { cancellable.cancel() }

        try await sync()

        let stored = try XCTUnwrap(stored(rpcHash))
        XCTAssertTrue(stored.isSuccess)
        XCTAssertEqual(stored.timestamp, 77)
        XCTAssertEqual(published.map { $0.map(\.hash) }, [[rpcHash]])
    }

    // Before its validity window ends an unknown send just stays pending: the index is not asked.
    func testUnknownPendingWithinValidityStaysPending() async throws {
        try saveSyncState(lastSyncedBlockHeight: 1)
        try savePending(expiresAfterHeight: 5000)
        near.rpc.answer("EXPERIMENTAL_tx_status", .error(cause: "UNKNOWN_TRANSACTION"))
        near.indexer.answer("/v0/account", .json(["account_txs": []]))

        try await sync()

        XCTAssertEqual(try stored(pendingHash)?.isPending, true)
        XCTAssertTrue(near.indexer.requests("/v0/transactions").isEmpty)
    }

    // MARK: - iOS: history pagination

    func testInitialSyncStoresNewestPageAndRemembersBackfill() async throws {
        let rows = (0 ..< TransactionSyncer.pageLimit).map { (hash: "h\($0)", height: 2000 - $0) }
        near.indexer.answer("/v0/account", .json(FakeNear.page(rows, resumeToken: "r1")))
        near.indexer.answer("/v0/transactions", .json(["transactions": [item(hash: "h0", height: 2000)]]))
        for _ in 1 ..< TransactionSyncer.pageLimit / FastNearProvider.maxHashesPerRequest {
            near.indexer.answer("/v0/transactions", .json(["transactions": []]))
        }

        try await sync()

        let request = try XCTUnwrap(accountRequests().first)
        XCTAssertEqual(request["desc"] as? Bool, true)
        XCTAssertNil(request["from_tx_block_height"])
        XCTAssertEqual(request["limit"] as? Int, TransactionSyncer.pageLimit)
        XCTAssertNotNil(try stored("h0"))
        let state = try XCTUnwrap(near.mainStorage.transactionSyncState())
        XCTAssertTrue(state.initialSyncDone)
        XCTAssertEqual(state.lastSyncedBlockHeight, 2000)
        XCTAssertEqual(state.backfillResumeToken, "r1")
        XCTAssertEqual(syncer.syncState, .synced)
    }

    // The API returns a resume token on the last page too; only a full page continues the walk.
    func testBackfillStopsAtAnIncompletePage() async throws {
        try saveSyncState(lastSyncedBlockHeight: 2000, backfillResumeToken: "r1")
        near.indexer.answer("/v0/account", .json(FakeNear.page([])), .json(FakeNear.page([(hash: "old", height: 10)], resumeToken: "r2")))
        near.indexer.answer("/v0/transactions", .json(["transactions": [item(hash: "old", height: 10)]]))

        try await sync()

        let backfill = try XCTUnwrap(accountRequests().last)
        XCTAssertEqual(backfill["resume_token"] as? String, "r1")
        XCTAssertEqual(backfill["desc"] as? Bool, true)
        XCTAssertNil(backfill["from_tx_block_height"])
        XCTAssertNotNil(try stored("old"))
        XCTAssertNil(try near.mainStorage.transactionSyncState()?.backfillResumeToken)

        // the next cycle only looks for newer rows
        near.indexer.answer("/v0/account", .json(FakeNear.page([])))
        try await sync()
        XCTAssertEqual(accountRequests().count, 3)
    }

    // N-1: the index adds a row where the account only appears in a receipt or an event log a few
    // blocks late. The incremental fetch starts 300 blocks below the cursor, so a row that shows up
    // below a height already synced past is picked up by the next cycle; stored rows are not fetched again.
    func testLateRowBelowCursorIsPickedUpNextCycle() async throws {
        try saveSyncState(lastSyncedBlockHeight: 1000)

        near.indexer.answer("/v0/account", .json(FakeNear.page([(hash: "a", height: 1000), (hash: "b", height: 1005)])))
        near.indexer.answer("/v0/transactions", .json(["transactions": [item(hash: "a", height: 1000), item(hash: "b", height: 1005)]]))
        try await sync()

        XCTAssertEqual(accountRequests().last?["from_tx_block_height"] as? Int, 1000 - TransactionSyncer.reindexWindowBlocks)
        XCTAssertEqual(accountRequests().last?["desc"] as? Bool, false)
        XCTAssertEqual(try near.mainStorage.transactionSyncState()?.lastSyncedBlockHeight, 1005)

        // the late row at 1003 is now in the index, below the cursor
        near.indexer.answer("/v0/account", .json(FakeNear.page([(hash: "a", height: 1000), (hash: "c", height: 1003), (hash: "b", height: 1005)])))
        near.indexer.answer("/v0/transactions", .json(["transactions": [item(hash: "c", height: 1003)]]))
        try await sync()

        XCTAssertEqual(accountRequests().last?["from_tx_block_height"] as? Int, 1005 - TransactionSyncer.reindexWindowBlocks)
        XCTAssertEqual(near.indexer.requests("/v0/transactions").last?.body?["tx_hashes"] as? [String], ["c"])
        XCTAssertNotNil(try stored("c"))
        XCTAssertEqual(try near.mainStorage.transactionSyncState()?.lastSyncedBlockHeight, 1005)
    }

    func testOverlapDoesNotGoBelowZero() async throws {
        try saveSyncState(lastSyncedBlockHeight: 120)
        near.indexer.answer("/v0/account", .json(FakeNear.page([])))

        try await sync()

        XCTAssertEqual(accountRequests().last?["from_tx_block_height"] as? Int, 0)
    }

    // A failed sync is reported by the history state and never thrown: history is optional to the kit.
    func testFailedInitialSyncIsNotSynced() async throws {
        near.indexer.answer("/v0/account", .failure(URLError(.timedOut)))

        try await sync()

        XCTAssertTrue(syncer.syncState.notSynced)
    }
}
