@testable import HsToolKit
@testable import NearKit
import XCTest

/// How the FastNEAR history index differs from a finished-transaction feed: it serves transactions
/// while their receipts still execute, can repeat a hash within one response, adds an account's
/// row late, and rate limits keyless clients (Android `TransactionSyncerIndexTest`).
final class TransactionSyncerIndexTests: XCTestCase {
    private static let account = "alice.near"
    private static let hash = "WithdrawTx111111111111111111111111111111111"

    private var near: FakeNear!
    private var syncer: TransactionSyncer!
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        near = try FakeNear()
        syncer = TransactionSyncer(
            accountId: Self.account, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider,
            mainStorage: near.mainStorage, transactionStorage: near.transactionStorage, now: { [unowned self] in now }
        )
        try near.mainStorage.save(transactionSyncState: TransactionSyncState(lastSyncedBlockHeight: 1000, initialSyncDone: true, backfillResumeToken: nil))
    }

    override func tearDown() {
        near.assertNoUnexpectedRequests()
        super.tearDown()
    }

    private func sync() async throws {
        try await syncer.sync(blockHeight: 2000)
    }

    private func stored() throws -> Transaction {
        try XCTUnwrap(near.transactionStorage.transaction(hash: Self.hash))
    }

    private func accountPage(_ hashes: String...) -> StubIndexerTransport.Answer {
        .json(["account_txs": hashes.map { ["transaction_hash": $0, "tx_block_height": 1001, "tx_block_timestamp": "1700000000000000000"] }])
    }

    private func transactions(_ items: RpcJson...) -> StubIndexerTransport.Answer {
        .json(["transactions": items])
    }

    private static func http(_ code: Int) -> StubIndexerTransport.Answer {
        .failure(NetworkManager.ResponseError(statusCode: code, json: nil, rawData: nil))
    }

    func testTransactionStillExecutingIsKeptPendingUntilTheIndexHasAllReceipts() async throws {
        near.indexer.answer("/v0/account", accountPage(Self.hash))
        near.indexer.answer("/v0/transactions", transactions(withdraw(complete: false)))
        try await sync()
        // wrap.near returned a value, but the NEAR payout receipt has not run yet
        XCTAssertTrue(try stored().isPending)
        XCTAssertTrue(try stored().nearTransfers.filter { $0.to == Self.account }.isEmpty)

        // the node lost it; the index has finished it
        near.rpc.answer("EXPERIMENTAL_tx_status", .error(cause: "UNKNOWN_TRANSACTION"))
        near.indexer.answer("/v0/transactions", transactions(withdraw(complete: true)))
        near.indexer.answer("/v0/account", accountPage(Self.hash))
        try await sync()
        XCTAssertTrue(try stored().isSuccess)
        XCTAssertEqual(try stored().nearTransfers.filter { $0.to == Self.account }.map(\.amount), [5000])
        // unwrapping pays NEAR out, so it shows in both histories
        XCTAssertEqual(TransactionConverter.tags(transaction: try stored(), accountId: Self.account), [TransactionTag.tokenNative, "wrap.near"])
    }

    func testRepeatedHashInOneResponseKeepsTheMostCompleteSnapshot() async throws {
        near.indexer.answer("/v0/account", accountPage(Self.hash))
        near.indexer.answer("/v0/transactions", transactions(withdraw(complete: true), withdraw(complete: false)))
        try await sync()

        XCTAssertTrue(try stored().isSuccess)
        XCTAssertEqual(try stored().nearTransfers.filter { $0.to == Self.account }.count, 1)
    }

    func testIncrementalSyncLooksBackForRowsAddedLate() async throws {
        near.indexer.answer("/v0/account", accountPage())
        try await sync()

        XCTAssertEqual(near.indexer.requests("/v0/account").first?.body?["from_tx_block_height"] as? Int, 1000 - TransactionSyncer.reindexWindowBlocks)
    }

    // Unlike Android there is no Retry-After (HsToolKit keeps no headers): the pause starts at 30 s.
    func testRateLimitPausesTheIndexAndKeepsHistorySynced() async throws {
        near.indexer.answer("/v0/account", accountPage())
        try await sync()
        XCTAssertEqual(syncer.syncState, .synced)

        near.indexer.answer("/v0/account", Self.http(429))
        try await sync()
        XCTAssertEqual(syncer.syncState, .synced)

        // inside the pause no request reaches the index
        now += 20
        let before = near.indexer.requests.count
        try await sync()
        XCTAssertEqual(near.indexer.requests.count, before)

        now += 11
        near.indexer.answer("/v0/account", accountPage())
        try await sync()
        XCTAssertEqual(near.indexer.requests.count, before + 1)
        XCTAssertEqual(syncer.syncState, .synced)
    }

    func testRepeatedRateLimitIsReported() async throws {
        near.indexer.answer("/v0/account", accountPage())
        try await sync()

        for _ in 0 ..< 3 {
            near.indexer.answer("/v0/account", Self.http(429))
            try await sync()
            now += 600
        }
        XCTAssertTrue(syncer.syncState.notSynced)
    }

    func testMostCompleteKeepsFirstSeenOrder() throws {
        let a = withdraw(complete: false)
        var b = withdraw(complete: false)
        var transaction = try XCTUnwrap(b.object("transaction"))
        transaction["hash"] = "Other"
        b["transaction"] = transaction

        let picked = TransactionSyncer.mostComplete([a, b, withdraw(complete: true)])

        XCTAssertEqual(picked.map(\.0), [Self.hash, "Other"])
        XCTAssertEqual(picked.first?.1.array("receipts")?.count, 2)
    }

    /// alice.near unwraps 5000 yocto: wrap.near logs the withdrawal, then a receipt pays the NEAR out.
    private func withdraw(complete: Bool) -> RpcJson {
        let call = receipt(
            id: "R1", predecessor: Self.account, receiver: "wrap.near",
            actions: #"[{"FunctionCall":{"method_name":"near_withdraw","args":"e30=","gas":10000000000000,"deposit":"1"}}]"#,
            createdReceipts: ["R2"], logs: ["Withdraw 5000 NEAR from \(Self.account)"]
        )
        let payout = receipt(id: "R2", predecessor: "wrap.near", receiver: Self.account, actions: #"[{"Transfer":{"deposit":"5000"}}]"#)
        let receipts = ([call] + (complete ? [payout] : [])).joined(separator: ",")
        let text = """
        {"transaction":{"hash":"\(Self.hash)","signer_id":"\(Self.account)","receiver_id":"wrap.near",
          "actions":[{"FunctionCall":{"method_name":"near_withdraw","args":"e30=","gas":10000000000000,"deposit":"1"}}]},
         "execution_outcome":{"block_height":1001,"block_timestamp":1700000000000000000,"id":"\(Self.hash)",
          "outcome":{"logs":[],"receipt_ids":["R1"],"tokens_burnt":"100","executor_id":"\(Self.account)","status":{"SuccessReceiptId":"R1"}}},
         "receipts":[\(receipts)]}
        """
        return RpcJson.object(text: text)!
    }

    private func receipt(id: String, predecessor: String, receiver: String, actions: String, createdReceipts: [String] = [], logs: [String] = []) -> String {
        """
        {"receipt":{"receipt_id":"\(id)","predecessor_id":"\(predecessor)","receiver_id":"\(receiver)","receipt":{"Action":{"actions":\(actions)}}},
         "execution_outcome":{"id":"\(id)","block_height":1002,"outcome":{"logs":[\(logs.map { "\"\($0)\"" }.joined(separator: ","))],
          "receipt_ids":[\(createdReceipts.map { "\"\($0)\"" }.joined(separator: ","))],"tokens_burnt":"10","executor_id":"\(receiver)","status":{"SuccessValue":""}}}}
        """
    }
}
