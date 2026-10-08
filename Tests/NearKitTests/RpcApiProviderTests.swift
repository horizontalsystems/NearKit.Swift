import Alamofire
import BigInt
@testable import HsToolKit
@testable import NearKit
import XCTest

/// Failover policy: errors about the request itself are thrown at once, anything else asks the next node.
final class RpcApiProviderTests: XCTestCase {
    private static let urlA = URL(string: "https://a.example/")!
    private static let urlB = URL(string: "https://b.example/")!
    private static let urlC = URL(string: "https://c.example/")!

    private var transport: StubRpcTransport!
    private var provider: RpcApiProvider!

    override func setUp() {
        super.setUp()
        transport = StubRpcTransport()
        provider = RpcApiProvider(urls: [Self.urlA, Self.urlB], transport: transport)
    }

    /// What HsToolKit `NetworkManager` throws for any failure that has an HTTP response.
    private func http(_ code: Int) -> Error {
        NetworkManager.ResponseError(statusCode: code, json: nil, rawData: nil)
    }

    private func error(name: String?, cause: String?) -> StubRpcTransport.Answer {
        var error: RpcJson = ["code": -32000, "message": "Server error", "data": "details"]
        if let name {
            error["name"] = name
        }
        if let cause {
            error["cause"] = ["name": cause]
        }
        return .raw(["error": error])
    }

    // MARK: - Deterministic errors

    func testEveryDeterministicErrorIsThrownWithoutFailover() async {
        let names = [
            "UNKNOWN_ACCOUNT", "UNKNOWN_ACCESS_KEY", "INVALID_ACCOUNT", "INVALID_TRANSACTION", "UNKNOWN_TRANSACTION",
            "PARSE_ERROR", "REQUEST_VALIDATION_ERROR", "NO_CONTRACT_CODE", "CONTRACT_EXECUTION_ERROR",
        ]
        for name in names {
            let transport = StubRpcTransport()
            let provider = RpcApiProvider(urls: [Self.urlA, Self.urlB], transport: transport)
            transport.answer("block", .error(cause: name))

            do {
                _ = try await provider.latestBlock()
                XCTFail("\(name): no error")
            } catch {
                XCTAssertEqual((error as? RpcError)?.name, name)
                XCTAssertTrue((error as? RpcError)?.isDeterministic == true, name)
            }
            XCTAssertEqual(transport.calls.map(\.url), [Self.urlA], name)
        }
    }

    // MARK: - Next node

    func testNonDeterministicFailuresMoveToTheNextNode() async throws {
        let failures: [(String, StubRpcTransport.Answer)] = [
            ("lagging node", .error(cause: "UNKNOWN_BLOCK")),
            ("node-side", .error(cause: "TIMEOUT_ERROR")),
            ("unnamed", error(name: nil, cause: nil)),
            ("top-level name only", error(name: "SOMETHING_NEW", cause: nil)),
            ("HTTP 429", .failure(http(429))),
            ("HTTP 503", .failure(http(503))),
            ("transport", .failure(URLError(.timedOut))),
            ("missing result", .raw(["jsonrpc": "2.0"])),
        ]
        for (label, failure) in failures {
            let transport = StubRpcTransport()
            let provider = RpcApiProvider(urls: [Self.urlA, Self.urlB], transport: transport)
            transport.answer("block", failure, .result(FakeNear.block(height: 7)))

            let block = try await provider.latestBlock()

            XCTAssertEqual(block.height, 7, label)
            XCTAssertEqual(transport.calls.map(\.url), [Self.urlA, Self.urlB], label)
        }
    }

    func testUnnamedErrorIsUnknown() {
        let error = JsonRpcResponse.parseError(["code": -32000, "message": "boom"])
        XCTAssertEqual(error.name, "UNKNOWN")
        XCTAssertEqual(error.message, "boom")
        XCTAssertFalse(error.isDeterministic)
    }

    func testCauseNameWinsOverTopLevelName() {
        let error = JsonRpcResponse.parseError(["name": "HANDLER_ERROR", "cause": ["name": "UNKNOWN_ACCOUNT"], "data": "acc"])
        XCTAssertEqual(error.name, "UNKNOWN_ACCOUNT")
        XCTAssertEqual(error.message, "acc")
    }

    // Legacy `QUERY_ERROR` (an `error` string inside a successful `query` result) is not
    // deterministic: the next node is asked.
    func testLegacyQueryErrorMovesToTheNextNode() async throws {
        transport.answer("query.call_function", .result(["error": "wasm execution failed", "block_height": 1, "block_hash": "x"]), .result(FakeNear.callResult("ok")))

        let result = try await provider.callFunctionJson(contractId: "token.near", methodName: "ft_metadata")

        XCTAssertEqual(result as? String, "ok")
        XCTAssertEqual(transport.calls.map(\.url), [Self.urlA, Self.urlB])
    }

    // Older nodes report missing accounts and keys inside the result; they read as not found, from one node.
    func testLegacyNotFoundInsideResult() async throws {
        transport.answer("query.view_account", .result(["error": "account bob.near does not exist while viewing", "block_height": 1, "block_hash": "x"]))
        transport.answer("query.view_access_key", .result(["error": "access key ed25519:abc does not exist while viewing", "block_height": 1, "block_hash": "x"]))

        let account = try await provider.viewAccount(accountId: "bob.near")
        let accessKey = try await provider.viewAccessKey(accountId: "bob.near", publicKey: "ed25519:abc")

        XCTAssertNil(account)
        XCTAssertNil(accessKey)
        XCTAssertEqual(transport.calls.count, 2)
    }

    func testAllNodesFailingThrowsNoEndpointAvailable() async {
        transport.answer("block", .error(cause: "INTERNAL_ERROR"), .failure(URLError(.timedOut)))

        do {
            _ = try await provider.latestBlock()
            XCTFail("no error")
        } catch {
            let underlying = (error as? NoEndpointAvailable)?.underlying
            XCTAssertEqual((underlying as? URLError)?.code, .timedOut)
        }
        // not a DNS failure: one pass only
        XCTAssertEqual(transport.calls.count, 2)
    }

    // Every host failing to resolve means the network is not up yet: one more pass after a pause.
    func testDnsFailureEverywhereRetriesOnce() async throws {
        transport.answer("block", .failure(URLError(.cannotFindHost)), .failure(URLError(.cannotFindHost)), .result(FakeNear.block(height: 9)))

        let block = try await provider.latestBlock()

        XCTAssertEqual(block.height, 9)
        XCTAssertEqual(transport.calls.map(\.url), [Self.urlA, Self.urlB, Self.urlA])
    }

    // Through HsToolKit the DNS failure arrives wrapped in AFError.sessionTaskFailed.
    func testDnsFailureWrappedByAlamofireRetriesOnce() async throws {
        let dns = StubRpcTransport.Answer.failure(AFError.sessionTaskFailed(error: URLError(.cannotFindHost)))
        transport.answer("block", dns, dns, .result(FakeNear.block(height: 9)))

        let block = try await provider.latestBlock()

        XCTAssertEqual(block.height, 9)
        XCTAssertEqual(transport.calls.map(\.url), [Self.urlA, Self.urlB, Self.urlA])
    }

    // MARK: - Preferred node

    // The node that answered stays first for later calls, as in Android.
    func testPreferredNodeSticks() async throws {
        transport.answer("block", .failure(URLError(.timedOut)), .result(FakeNear.block()), .result(FakeNear.block()))

        _ = try await provider.latestBlock()
        _ = try await provider.latestBlock()

        XCTAssertEqual(transport.calls.map(\.url), [Self.urlA, Self.urlB, Self.urlB])
        XCTAssertEqual(provider.preferredIndex, 1)
    }

    // statusInfo shows the node calls start from, not the first in the list.
    func testSourceIsPreferredNode() async throws {
        XCTAssertEqual(provider.source, "a.example")
        transport.answer("block", .failure(URLError(.timedOut)), .result(FakeNear.block()))

        _ = try await provider.latestBlock()

        XCTAssertEqual(provider.source, "b.example")
    }

    // set(urls:) swaps the list at once and starts again from its first URL.
    func testSetUrlsReplacesListAndResetsPreferredIndex() async throws {
        transport.answer("block", .failure(URLError(.timedOut)), .result(FakeNear.block()), .result(FakeNear.block()))
        _ = try await provider.latestBlock()
        XCTAssertEqual(provider.preferredIndex, 1)

        try provider.set(urls: [Self.urlC, Self.urlA])

        XCTAssertEqual(provider.preferredIndex, 0)
        XCTAssertEqual(provider.urls, [Self.urlC, Self.urlA])
        _ = try await provider.latestBlock()
        XCTAssertEqual(transport.calls.last?.url, Self.urlC)
    }

    func testSetEmptyUrlsThrowsAndKeepsList() {
        XCTAssertThrowsError(try provider.set(urls: [])) { error in
            XCTAssertTrue(error is NoEndpointAvailable)
        }
        XCTAssertEqual(provider.urls, [Self.urlA, Self.urlB])
    }

    // MARK: - Transient errors

    // Transport failures, rate limits and 5xx are transient (Android `NetworkErrors.isTransient`); other HTTP errors are reported at once.
    func testTransportFailuresRateLimitsAndServerErrorsAreTransient() {
        XCTAssertTrue(NetworkErrors.isTransient(NoEndpointAvailable(underlying: URLError(.timedOut))))
        XCTAssertTrue(NetworkErrors.isTransient(AFError.sessionTaskFailed(error: URLError(.networkConnectionLost))))
        XCTAssertTrue(NetworkErrors.isTransient(NoEndpointAvailable(underlying: http(429))))
        XCTAssertTrue(NetworkErrors.isTransient(NoEndpointAvailable(underlying: http(503))))
        XCTAssertFalse(NetworkErrors.isTransient(NoEndpointAvailable(underlying: http(401))))
        XCTAssertFalse(NetworkErrors.isTransient(NoEndpointAvailable(underlying: http(404))))
        XCTAssertTrue(NetworkErrors.isRateLimited(NoEndpointAvailable(underlying: http(429))))
        XCTAssertTrue(NetworkErrors.isRateLimited(http(429)))
        XCTAssertFalse(NetworkErrors.isRateLimited(http(503)))
        XCTAssertTrue(NetworkErrors.isTransient(NoEndpointAvailable(underlying: AFError.sessionTaskFailed(error: URLError(.cannotFindHost)))))
        XCTAssertFalse(NetworkErrors.isTransient(NoEndpointAvailable(underlying: RpcError(name: "TIMEOUT_ERROR", data: nil, message: nil))))
        XCTAssertFalse(NetworkErrors.isTransient(InvalidResponse("x")))
        XCTAssertTrue(NetworkErrors.isDnsFailure(NoEndpointAvailable(underlying: URLError(.cannotFindHost))))
        XCTAssertTrue(NetworkErrors.isDnsFailure(NoEndpointAvailable(underlying: AFError.sessionTaskFailed(error: URLError(.cannotFindHost)))))
        XCTAssertTrue(NetworkErrors.isDnsFailure(AFError.sessionTaskFailed(error: URLError(.dnsLookupFailed))))
        XCTAssertFalse(NetworkErrors.isDnsFailure(NoEndpointAvailable(underlying: URLError(.timedOut))))
        XCTAssertFalse(NetworkErrors.isDnsFailure(NoEndpointAvailable(underlying: http(503))))
    }

    // MARK: - Requests

    func testRequestShapes() async throws {
        transport.answer("query.view_account", .result(FakeNear.account()))
        transport.answer("EXPERIMENTAL_tx_status", .error(cause: "UNKNOWN_TRANSACTION"))
        transport.answer("send_tx", .result(["final_execution_status": "INCLUDED"]))

        let account = try await provider.viewAccount(accountId: "bob.near")
        let status = try await provider.transactionStatus(hash: "h", senderAccountId: "bob.near")
        let sent = try await provider.sendTransaction(signedTxBase64: "AAAA")

        XCTAssertEqual(account?.amount, BigUInt("5000000000000000000000000"))
        XCTAssertEqual(account?.hasContract, false)
        XCTAssertNil(status)
        XCTAssertEqual(sent.finalExecutionStatus, "INCLUDED")
        XCTAssertFalse(sent.isExecuted)

        let query = try XCTUnwrap(transport.calls("query.view_account").first?.params)
        XCTAssertEqual(query["finality"] as? String, "final")
        XCTAssertEqual(query["account_id"] as? String, "bob.near")
        let txStatus = try XCTUnwrap(transport.calls("EXPERIMENTAL_tx_status").first?.params)
        XCTAssertEqual(txStatus["wait_until"] as? String, "NONE")
        XCTAssertEqual(txStatus["sender_account_id"] as? String, "bob.near")
        let send = try XCTUnwrap(transport.calls("send_tx").first?.params)
        XCTAssertEqual(send["wait_until"] as? String, "INCLUDED")
        XCTAssertEqual(send["signed_tx_base64"] as? String, "AAAA")
    }

    // Only send_tx waits longer than the session's timeout: the node answers once the transaction is in a block.
    func testOnlySendTxOverridesTimeout() async throws {
        transport.answer("block", .result(FakeNear.block()))
        transport.answer("query.view_account", .result(FakeNear.account()))
        transport.answer("send_tx", .result(["final_execution_status": "INCLUDED"]))

        _ = try await provider.latestBlock()
        _ = try await provider.viewAccount(accountId: "bob.near")
        _ = try await provider.sendTransaction(signedTxBase64: "AAAA")

        XCTAssertEqual(transport.calls.map(\.timeout), [nil, nil, 30])
    }

    func testAmountsMustBeDecimalStrings() async {
        transport.answer("query.view_account", .result(["amount": 5, "locked": "0", "storage_usage": 1, "code_hash": "x", "block_height": 1]))
        transport.answer("query.view_account", .result(["amount": 5, "locked": "0", "storage_usage": 1, "code_hash": "x", "block_height": 1]))

        do {
            _ = try await provider.viewAccount(accountId: "bob.near")
            XCTFail("no error")
        } catch {
            XCTAssertTrue((error as? NoEndpointAvailable)?.underlying is InvalidResponse)
        }
    }
}
