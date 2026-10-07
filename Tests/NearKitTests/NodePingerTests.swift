@testable import NearKit
import XCTest

/// A node is valid only when it answers `status` as a synced node of the expected network.
final class NodePingerTests: XCTestCase {
    private let url = URL(string: "https://rpc.example/")!

    private func status(chainId: String = "mainnet", height: Any = 150_000_000, syncing: Any = false) -> Any {
        ["jsonrpc": "2.0", "id": "nearkit", "result": ["chain_id": chainId, "sync_info": ["latest_block_height": height, "syncing": syncing]]]
    }

    private func result(_ json: Any, network: Network = .mainNet) -> NodePingResult {
        NodePinger.result(url: url, responseTime: 0.2, jsonObject: json, network: network)
    }

    func testSyncedNodeOfTheNetworkIsValid() {
        let result = result(status())

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.isReachable)
        XCTAssertEqual(result.height, 150_000_000)
        XCTAssertEqual(result.responseTime, 0.2)
    }

    func testSyncingNodeIsInvalid() {
        let result = result(status(syncing: true))

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.height, 150_000_000)
    }

    func testNodeOfAnotherNetworkIsInvalid() {
        XCTAssertFalse(result(status(chainId: "testnet")).isValid)
        XCTAssertTrue(result(status(chainId: "testnet"), network: .testNet).isValid)
    }

    func testZeroHeightIsInvalid() {
        XCTAssertFalse(result(status(height: 0)).isValid)
    }

    func testMalformedAnswersAreInvalid() {
        let answers: [Any] = [
            ["jsonrpc": "2.0", "id": "nearkit"],
            ["error": ["name": "HANDLER_ERROR", "cause": ["name": "INTERNAL_ERROR"]]],
            status(syncing: 0),
            status(height: "150000000"),
            ["result": ["sync_info": ["latest_block_height": 1, "syncing": false]]],
            "not an object",
        ]
        for answer in answers {
            let result = result(answer)
            XCTAssertFalse(result.isValid, "\(answer)")
            XCTAssertEqual(result.height, 0)
            // it answered, so it is reachable, just not usable
            XCTAssertTrue(result.isReachable)
        }
    }

    func testStatusRequest() {
        let body = StatusJsonRpc().body
        XCTAssertEqual(body["method"] as? String, "status")
        XCTAssertEqual((body["params"] as? [Any])?.count, 0)
    }
}
