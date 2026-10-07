import HdWalletKit
import HsToolKit
@testable import NearKit
import XCTest

/// Read-only mainnet checks with the well-known "abandon … about" test mnemonic, whose implicit
/// account strangers keep funding (Android `MainnetReadTest`). Skipped unless
/// `NEARKIT_INTEGRATION=true` in the test process; CI never sets it. From the command line pass it
/// as `TEST_RUNNER_NEARKIT_INTEGRATION=true xcodebuild test ...` so xcodebuild forwards it.
final class MainnetReadTests: XCTestCase {
    private static let usdt = "usdt.tether-token.near"

    private let network = Network.mainNet
    private var networkManager: NetworkManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NEARKIT_INTEGRATION"] == "true", "set NEARKIT_INTEGRATION=true to run against mainnet")
        networkManager = NetworkManager(timeout: Kit.requestTimeout)
    }

    func testReadsAccountTokensAndHistory() async throws {
        let words = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".split(separator: " ").map(String.init)
        let publicKey = try Signer.instance(seed: XCTUnwrap(Mnemonic.seed(mnemonic: words))).publicKey
        let accountId = publicKey.implicitAccountId

        for url in network.rpcUrls {
            let single = RpcApiProvider(urls: [url], networkManager: networkManager)
            let view = try await single.viewAccount(accountId: accountId)
            print("\(url): \(view.map { "\($0.amount)" } ?? "nil") yocto, block \(view.map { "\($0.blockHeight)" } ?? "nil")")
            XCTAssertNotNil(view, url.absoluteString)
        }

        let rpc = RpcApiProvider(urls: network.rpcUrls, networkManager: networkManager)
        let missing = try await rpc.viewAccount(accountId: "this-account-does-not-exist-nearkit.near")
        XCTAssertNil(missing)
        // the account's owner has since rotated this key away, which is why it is not asserted
        let ownKey = try await rpc.viewAccessKey(accountId: accountId, publicKey: publicKey.description)
        print("key on account: \(ownKey != nil)")
        if try await rpc.viewAccessKey(accountId: "near", publicKey: "ed25519:5zset1JX4qp4PcR3N9KDSY6ATdgkrbBW5wFBGgz7vnAQ") == nil {
            let near = try await rpc.viewAccount(accountId: "near")
            XCTAssertNotNil(near)
        }
        let block = try await rpc.latestBlock()
        print("block \(block.height), gas price \(block.gasPrice)")

        let fastNear = FastNearProvider(network: network, apiKey: nil, networkManager: networkManager)
        let tokens = try await fastNear.ftBalances(accountId: accountId)
        print("tokens: \(tokens.map { ($0.contractId, $0.balance.description) })")
        XCTAssertTrue(tokens.contains { $0.contractId == Self.usdt })

        let ownDeposit = try await FtActions.storageDepositRequired(rpcApiProvider: rpc, contractId: Self.usdt, accountId: accountId)
        XCTAssertNil(ownDeposit)
        let strangerDeposit = try await FtActions.storageDepositRequired(rpcApiProvider: rpc, contractId: Self.usdt, accountId: String(repeating: "0", count: 63) + "1")
        XCTAssertNotNil(strangerDeposit)

        let page = try await fastNear.accountTransactions(accountId: accountId, fromBlockHeight: nil, newestFirst: true, resumeToken: nil, limit: 20)
        let rows = Array(page.rows.prefix(20))
        let converted = try await fastNear.transactions(hashes: rows.map(\.hash)).map { try TransactionConverter.convert(item: $0, accountId: accountId, fallbackTimestamp: 0) }
        for (transaction, tags) in converted {
            print("\(transaction.hash) \(transaction.status) near=\(transaction.nearNetChange(accountId: accountId)) ft=\(transaction.ftTransfers.count) tags=\(tags)")
        }
        XCTAssertEqual(converted.count, rows.count)

        let accounts = try await Kit.findAccounts(publicKey: publicKey, network: network)
        print("accounts for key: \(accounts)")
        XCTAssertEqual(accounts.first, accountId)
    }
}
