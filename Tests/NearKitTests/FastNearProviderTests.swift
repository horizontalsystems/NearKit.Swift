import BigInt
@testable import HsToolKit
@testable import NearKit
import XCTest

final class FastNearProviderTests: XCTestCase {
    private var transport: StubIndexerTransport!
    private var provider: FastNearProvider!

    override func setUp() {
        super.setUp()
        transport = StubIndexerTransport()
        provider = .stub(transport)
    }

    override func tearDown() {
        XCTAssertEqual(transport.unexpected, [])
        super.tearDown()
    }

    func testTokenBalancesSkipUnreadableEntries() async throws {
        transport.answer("/v1/account/bob.near/ft", .json(["account_id": "bob.near", "tokens": [
            ["contract_id": "usdt.tether-token.near", "balance": "5000000", "last_update_block_height": 1],
            // the indexer reports an empty balance for contracts it could not read
            ["contract_id": "broken.near", "balance": ""],
            ["contract_id": "wrap.near", "balance": "0"],
            ["balance": "1"],
        ]]))

        let balances = try await provider.ftBalances(accountId: "bob.near")

        XCTAssertEqual(balances, [
            FtBalanceInfo(contractId: "usdt.tether-token.near", balance: 5_000_000),
            FtBalanceInfo(contractId: "wrap.near", balance: 0),
        ])
    }

    func testTokenBalancesWithoutListIsInvalid() async {
        transport.answer("/v1/account/bob.near/ft", .json(["account_id": "bob.near"]))

        do {
            _ = try await provider.ftBalances(accountId: "bob.near")
            XCTFail("no error")
        } catch {
            XCTAssertTrue(error is InvalidResponse)
        }
    }

    func testAccountIdsForPublicKey() async throws {
        transport.answer("/v0/public_key/ed25519:abc", .json(["public_key": "ed25519:abc", "account_ids": ["alice.near", "bob.near"]]))

        let ids = try await provider.accountIds(publicKey: "ed25519:abc")

        XCTAssertEqual(ids, ["alice.near", "bob.near"])
    }

    func testAccountTransactionsRequestAndPage() async throws {
        transport.answer("/v0/account", .json([
            "account_txs": [
                ["account_id": "bob.near", "transaction_hash": "h1", "tx_block_height": 100, "tx_block_timestamp": 1_790_000_000_123_456_789],
                ["account_id": "bob.near", "transaction_hash": "h2", "tx_block_height": 101],
                ["account_id": "bob.near", "tx_block_height": 102],
            ],
            "resume_token": "next",
            "txs_count": 3,
        ]))

        let page = try await provider.accountTransactions(accountId: "bob.near", fromBlockHeight: 50, newestFirst: false, resumeToken: "prev", limit: 100)

        XCTAssertEqual(page.rows, [
            AccountTxRow(hash: "h1", blockHeight: 100, blockTimestampNanos: 1_790_000_000_123_456_789),
            AccountTxRow(hash: "h2", blockHeight: 101, blockTimestampNanos: 0),
        ])
        XCTAssertEqual(page.resumeToken, "next")
        XCTAssertEqual(page.totalCount, 3)

        let request = try XCTUnwrap(transport.requests("/v0/account").first)
        XCTAssertEqual(request.url.host, "tx.fastnear.test")
        XCTAssertEqual(request.body?["account_id"] as? String, "bob.near")
        XCTAssertEqual(request.body?["desc"] as? Bool, false)
        XCTAssertEqual(request.body?["limit"] as? Int, 100)
        XCTAssertEqual(request.body?["from_tx_block_height"] as? Int, 50)
        XCTAssertEqual(request.body?["resume_token"] as? String, "prev")
    }

    // The API returns a token even on the last page; an empty page ends the walk.
    func testEmptyPageHasNoResumeToken() async throws {
        transport.answer("/v0/account", .json(["account_txs": [], "resume_token": "next"]))

        let page = try await provider.accountTransactions(accountId: "bob.near", fromBlockHeight: nil, newestFirst: true, resumeToken: nil, limit: 100)

        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertNil(page.resumeToken)
        let body = try XCTUnwrap(transport.requests("/v0/account").first?.body)
        XCTAssertNil(body["from_tx_block_height"])
        XCTAssertNil(body["resume_token"])
    }

    func testTransactionsParseTheAndroidFixture() async throws {
        let fixture = try Fixtures.json("fastnear-transactions")
        transport.answer("/v0/transactions", .json(fixture))
        let hashes = try Fixtures.objects(fixture, "transactions").map { try XCTUnwrap($0.object("transaction")).text("hash") }

        let items = try await provider.transactions(hashes: hashes)

        XCTAssertEqual(items.compactMap { $0.object("transaction")?.string("hash") }, hashes)
        XCTAssertEqual(transport.requests("/v0/transactions").first?.body?["tx_hashes"] as? [String], hashes)
        for item in items {
            XCTAssertNoThrow(try TransactionConverter.convert(item: item, accountId: "bob.near", fallbackTimestamp: 0))
        }
    }

    func testNoHashesNoRequest() async throws {
        let items = try await provider.transactions(hashes: [])
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - API key

    func testApiKeyIsSentAsBearerToEveryFastNearHost() async throws {
        provider = .stub(transport, apiKey: "secret")
        transport.answer("/v1/account/bob.near/ft", .json(["tokens": []]))
        transport.answer("/v0/account", .json(["account_txs": []]))

        _ = try await provider.ftBalances(accountId: "bob.near")
        _ = try await provider.accountTransactions(accountId: "bob.near", fromBlockHeight: nil, newestFirst: true, resumeToken: nil, limit: 1)

        XCTAssertEqual(transport.requests.map { $0.headers["Authorization"] }, ["Bearer secret", "Bearer secret"])
    }

    func testBlankApiKeyMeansNoKey() async throws {
        for key in [nil, "", "  "] {
            let transport = StubIndexerTransport()
            transport.answer("/v1/account/bob.near/ft", .json(["tokens": []]))

            _ = try await FastNearProvider.stub(transport, apiKey: key).ftBalances(accountId: "bob.near")

            XCTAssertEqual(transport.requests.first?.headers, [:])
        }
    }

    // A revoked key is dropped for good and the request repeated without it (Android `FastNearAuth`).
    func testRejectedKeyIsDroppedAndTheRequestRepeatedWithoutIt() async throws {
        provider = .stub(transport, apiKey: "secret")
        let rejected = NetworkManager.ResponseError(statusCode: 403, json: nil, rawData: nil)
        transport.answer("/v1/account/bob.near/ft", .failure(rejected), .json(["tokens": []]), .json(["tokens": []]))

        _ = try await provider.ftBalances(accountId: "bob.near")
        _ = try await provider.ftBalances(accountId: "bob.near")

        XCTAssertEqual(transport.requests.map { $0.headers["Authorization"] }, ["Bearer secret", nil, nil])
    }

    // Other failures keep the key.
    func testOtherErrorsKeepTheKey() async throws {
        provider = .stub(transport, apiKey: "secret")
        transport.answer("/v1/account/bob.near/ft", .failure(NetworkManager.ResponseError(statusCode: 429, json: nil, rawData: nil)), .json(["tokens": []]))

        _ = try? await provider.ftBalances(accountId: "bob.near")
        _ = try await provider.ftBalances(accountId: "bob.near")

        XCTAssertEqual(transport.requests.map { $0.headers["Authorization"] }, ["Bearer secret", "Bearer secret"])
    }

    // The RPC transport sends the key to FastNEAR's own nodes only, never to another provider in the list.
    func testKeyGoesToFastNearHostsOnly() {
        let auth = FastNearAuth(apiKey: "secret")
        let hosts = ["https://free.rpc.fastnear.com/", "https://tx.main.fastnear.com/v0/account", "https://near.drpc.org/", "https://fastnear.com.evil.example/"]

        XCTAssertEqual(hosts.map { auth.headers(url: URL(string: $0)!)["Authorization"] }, ["Bearer secret", "Bearer secret", nil, nil])
    }
}
