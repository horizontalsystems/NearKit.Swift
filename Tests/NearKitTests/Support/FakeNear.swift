import Foundation
import GRDB
@testable import NearKit
import XCTest

/// Two RPC nodes, the FastNEAR APIs and a fresh database (Android `FakeNear`): send and sync logic
/// runs against the real providers and storages, without a network.
final class FakeNear {
    static let rpcUrls = [URL(string: "https://rpc1.test/")!, URL(string: "https://rpc2.test/")!]

    let rpc = StubRpcTransport()
    let indexer = StubIndexerTransport()
    let rpcApiProvider: RpcApiProvider
    let fastNearProvider: FastNearProvider
    let dbPool: DatabasePool
    let mainStorage: MainStorage
    let transactionStorage: TransactionStorage

    private let databasePath = NSTemporaryDirectory() + "nearkit-\(UUID().uuidString).sqlite"

    init(rpcUrls: [URL] = FakeNear.rpcUrls) throws {
        rpcApiProvider = RpcApiProvider(urls: rpcUrls, transport: rpc)
        fastNearProvider = .stub(indexer)
        dbPool = try DatabasePool(path: databasePath)
        mainStorage = try MainStorage(dbPool: dbPool)
        transactionStorage = try TransactionStorage(dbPool: dbPool)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databasePath + suffix)
        }
    }

    func assertNoUnexpectedRequests(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rpc.unexpected, [], "RPC", file: file, line: line)
        XCTAssertEqual(indexer.unexpected, [], "FastNEAR", file: file, line: line)
    }

    func kit(accountId: String) throws -> Kit {
        try Kit.instance(
            accountId: accountId, network: .mainNet, rpcApiProvider: rpcApiProvider, indexerProvider: fastNearProvider,
            dbPool: dbPool, connectionManager: StubConnectionManager(connected: true), logger: nil
        )
    }

    // MARK: - Responses

    static func block(height: Int = 1000, gasPrice: String = "100000000") -> Any {
        ["header": ["height": height, "hash": "11111111111111111111111111111111", "timestamp_nanosec": "1790000000000000000", "gas_price": gasPrice]]
    }

    static func account(amount: String = "5000000000000000000000000", locked: String = "0", storageUsage: Int = 182) -> Any {
        ["amount": amount, "locked": locked, "storage_usage": storageUsage, "code_hash": "11111111111111111111111111111111", "block_height": 1000, "block_hash": "x"]
    }

    static func accessKey(nonce: UInt64 = 5, fullAccess: Bool = true, blockHeight: Int = 1000) -> Any {
        let permission: Any = fullAccess ? "FullAccess" : ["FunctionCall": ["allowance": NSNull(), "receiver_id": "app.near", "method_names": [String]()]]
        return ["nonce": nonce, "permission": permission, "block_hash": "11111111111111111111111111111111", "block_height": blockHeight]
    }

    /// A `call_function` result: the view method's return value as JSON bytes.
    static func callResult(_ json: Any) -> Any {
        let data = try! JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed)
        return ["result": [UInt8](data).map { Int($0) }, "logs": [String](), "block_height": 1000, "block_hash": "x"]
    }

    static func page(_ rows: [(hash: String, height: Int)], resumeToken: String? = nil) -> Any {
        var page: RpcJson = ["account_txs": rows.map { ["transaction_hash": $0.hash, "tx_block_height": $0.height, "tx_block_timestamp": 1_790_000_000_000_000_000] }]
        if let resumeToken {
            page["resume_token"] = resumeToken
        }
        return page
    }
}
