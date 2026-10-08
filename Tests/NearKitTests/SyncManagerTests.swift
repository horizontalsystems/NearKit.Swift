import BigInt
@testable import HsToolKit
@testable import NearKit
import XCTest

final class SyncManagerTests: XCTestCase {
    private static let accountId = "alice.near"
    private static let usdt = "usdt.tether-token.near"
    private static let tokensPath = "/v1/account/\(accountId)/ft"

    private var near: FakeNear!
    private var transactionSyncer: TransactionSyncer!
    private var syncManager: SyncManager!

    override func setUpWithError() throws {
        near = try FakeNear()
        transactionSyncer = TransactionSyncer(accountId: Self.accountId, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider, mainStorage: near.mainStorage, transactionStorage: near.transactionStorage)
        let apiSyncer = ApiSyncer(connectionManager: StubConnectionManager(connected: true), syncInterval: 60)
        syncManager = try SyncManager(accountId: Self.accountId, apiSyncer: apiSyncer, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider, transactionSyncer: transactionSyncer, storage: near.mainStorage)
    }

    override func tearDown() {
        near.assertNoUnexpectedRequests()
        super.tearDown()
    }

    private static func tokens(_ balances: [(String, String)]) -> StubIndexerTransport.Answer {
        .json(["account_id": accountId, "tokens": balances.map { ["contract_id": $0.0, "balance": $0.1] }])
    }

    /// What HsToolKit `NetworkManager` throws for any failure that has an HTTP response.
    private static func http(_ code: Int) -> StubRpcTransport.Answer {
        .failure(NetworkManager.ResponseError(statusCode: code, json: nil, rawData: nil))
    }

    /// Queues one full cycle; each step can be replaced by a failure.
    private func queueCycle(
        block: [StubRpcTransport.Answer] = [.result(FakeNear.block())],
        account: [StubRpcTransport.Answer] = [.result(FakeNear.account())],
        tokens: StubIndexerTransport.Answer? = SyncManagerTests.tokens([]),
        history: StubIndexerTransport.Answer? = .json(FakeNear.page([]))
    ) {
        near.rpc.answer("block", block)
        near.rpc.answer("query.view_account", account)
        if let tokens {
            near.indexer.answer(Self.tokensPath, tokens)
        }
        if let history {
            near.indexer.answer("/v0/account", history)
        }
    }

    private func balance(_ contractId: String) -> BigUInt? {
        syncManager.ftBalances.first { $0.contractId == contractId }?.balance
    }

    func testSuccessfulCycleSyncsAccountAndHistory() async throws {
        queueCycle(tokens: Self.tokens([(Self.usdt, "5")]))

        await syncManager.syncNow()

        XCTAssertEqual(syncManager.syncState, .synced)
        XCTAssertEqual(transactionSyncer.syncState, .synced)
        XCTAssertEqual(syncManager.chainState?.blockHeight, 1000)
        XCTAssertTrue(syncManager.accountState.exists)
        XCTAssertEqual(syncManager.accountState.amount, BigUInt("5000000000000000000000000"))
        XCTAssertEqual(balance(Self.usdt), 5)
        // persisted, so a new instance starts from it
        XCTAssertEqual(try near.mainStorage.accountState()?.amount, BigUInt("5000000000000000000000000"))
        XCTAssertEqual(try near.mainStorage.ftBalances().map(\.contractId), [Self.usdt])
    }

    // A failed balance step makes both the account and the history not synced (Android Syncer);
    // a failed history step only the history: balances stay synced.
    func testStepFailuresAreReportedByTheirOwnState() async throws {
        let down = StubRpcTransport.Answer.error(cause: "INTERNAL_ERROR")
        let cases: [(String, Bool, (SyncManagerTests) -> Void)] = [
            ("block", true, { $0.queueCycle(block: [down, down], account: [], tokens: nil, history: nil) }),
            ("view_account", true, { $0.queueCycle(account: [down, down], tokens: nil, history: nil) }),
            ("history", false, { $0.queueCycle(history: .failure(InvalidResponse("down"))) }),
        ]

        for (step, balancesFail, queue) in cases {
            try setUpWithError()
            // the first history sync is done, so the failure is the account syncer's to report
            try near.mainStorage.save(transactionSyncState: TransactionSyncState(lastSyncedBlockHeight: 900, initialSyncDone: true, backfillResumeToken: nil))
            queue(self)

            await syncManager.syncNow()

            XCTAssertEqual(syncManager.syncState.notSynced, balancesFail, step)
            XCTAssertTrue(transactionSyncer.syncState.notSynced, step)
            near.assertNoUnexpectedRequests()
        }
    }

    // A-1: a token can be sent to an implicit account that never received NEAR; its balance is synced anyway.
    func testTokensSyncWhenAccountDoesNotExist() async throws {
        queueCycle(account: [.error(cause: "UNKNOWN_ACCOUNT")], tokens: Self.tokens([(Self.usdt, "100000000")]))

        await syncManager.syncNow()

        XCTAssertEqual(syncManager.syncState, .synced)
        XCTAssertFalse(syncManager.accountState.exists)
        XCTAssertEqual(balance(Self.usdt), 100_000_000)
    }

    // The one tolerated failure: an index outage keeps the previous token list.
    func testTokenListFailureKeepsPreviousList() async throws {
        queueCycle(tokens: Self.tokens([(Self.usdt, "5")]))
        await syncManager.syncNow()

        queueCycle(tokens: .failure(URLError(.timedOut)))
        await syncManager.syncNow()

        XCTAssertEqual(syncManager.syncState, .synced)
        XCTAssertEqual(balance(Self.usdt), 5)
    }

    // Watched tokens are read from the contract, which overrides the index; a failed read keeps the index value.
    func testWatchedTokensAreReadFromContracts() async throws {
        syncManager.watchedTokens = ["new.near", Self.usdt, "wrap.near"]
        queueCycle(tokens: Self.tokens([(Self.usdt, "5"), ("wrap.near", "9")]))
        // sorted: new.near, usdt.tether-token.near, wrap.near
        near.rpc.answer("query.call_function", .result(FakeNear.callResult("3")), .result(FakeNear.callResult("7")), .error(cause: "TIMEOUT_ERROR"), .error(cause: "TIMEOUT_ERROR"))

        await syncManager.syncNow()

        XCTAssertEqual(syncManager.syncState, .synced)
        XCTAssertEqual(syncManager.ftBalances.map(\.contractId), [Self.usdt, "wrap.near", "new.near"])
        XCTAssertEqual(balance(Self.usdt), 7)
        XCTAssertEqual(balance("wrap.near"), 9)
        XCTAssertEqual(balance("new.near"), 3)
        let args = try XCTUnwrap(near.rpc.calls("query.call_function").first?.params)
        XCTAssertEqual(args["method_name"] as? String, "ft_balance_of")
        XCTAssertEqual(args["args_base64"] as? String, Data(#"{"account_id":"alice.near"}"#.utf8).base64EncodedString())
    }

    // After a successful sync one transport failure keeps the state and retries shortly; a second is reported.
    func testTransientFailureIsToleratedOnceAfterSync() async throws {
        queueCycle()
        await syncManager.syncNow()

        let dropped = StubRpcTransport.Answer.failure(URLError(.networkConnectionLost))
        queueCycle(block: [dropped, dropped], account: [], tokens: nil, history: nil)
        await syncManager.syncNow()
        XCTAssertEqual(syncManager.syncState, .synced)

        queueCycle(block: [dropped, dropped], account: [], tokens: nil, history: nil)
        await syncManager.syncNow()
        XCTAssertTrue(syncManager.syncState.notSynced)
        XCTAssertTrue(transactionSyncer.syncState.notSynced)
    }

    // Client HTTP errors such as 401 are reported at once; 429 and 5xx are transient (Android `NetworkErrors`).
    func testClientHttpErrorIsReportedAtOnce() async throws {
        queueCycle()
        await syncManager.syncNow()

        queueCycle(block: [Self.http(401), Self.http(401)], account: [], tokens: nil, history: nil)
        await syncManager.syncNow()

        XCTAssertTrue(syncManager.syncState.notSynced)
    }

    // Before the first successful sync nothing is tolerated.
    func testTransientFailureBeforeFirstSyncIsReported() async throws {
        let dropped = StubRpcTransport.Answer.failure(URLError(.networkConnectionLost))
        queueCycle(block: [dropped, dropped], account: [], tokens: nil, history: nil)

        await syncManager.syncNow()

        XCTAssertTrue(syncManager.syncState.notSynced)
    }
}
