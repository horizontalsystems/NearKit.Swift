import BigInt
@testable import NearKit
import XCTest

/// Wallet-free lookups an app uses to let a restored phrase pick its account (Android NearKit
/// `accountState`, `hasFullAccess`, `accessKeys`), and how `findAccounts` holds up against a key
/// that strangers have added to their own accounts.
final class AccountLookupTests: XCTestCase {
    private var near: FakeNear!
    private var publicKey: PublicKey!

    override func setUpWithError() throws {
        near = try FakeNear()
        publicKey = try Signer.instance(privateKey: Data(repeating: 7, count: 32)).publicKey
    }

    override func tearDown() {
        near.assertNoUnexpectedRequests()
        super.tearDown()
    }

    private static func key(_ publicKey: String, fullAccess: Bool) -> Any {
        let permission: Any = fullAccess ? "FullAccess" : ["FunctionCall": ["allowance": "250000000000000000000000", "receiver_id": "app.near", "method_names": ["claim"]]]
        return ["public_key": publicKey, "access_key": ["nonce": 7, "permission": permission]]
    }

    private static func keyList(_ keys: [Any]) -> Any {
        ["keys": keys, "block_height": 1000, "block_hash": "x"]
    }

    // MARK: - accountState

    func testAccountStateOfExistingAccount() async throws {
        near.rpc.answer("query.view_account", .result(FakeNear.account(amount: "3000000000000000000000000", storageUsage: 182)))

        let state = try await Kit.accountState(accountId: "alice.near", rpcApiProvider: near.rpcApiProvider)

        XCTAssertTrue(state.exists)
        XCTAssertEqual(state.available, BigUIntHelper.near(3))
        XCTAssertFalse(state.hasContract)
    }

    func testAccountStateOfMissingAccountIsEmpty() async throws {
        near.rpc.answer("query.view_account", .error(cause: "UNKNOWN_ACCOUNT"))

        let state = try await Kit.accountState(accountId: "nobody.near", rpcApiProvider: near.rpcApiProvider)

        XCTAssertEqual(state, .empty)
    }

    // NEP-591: an account on a global contract reports the empty code hash and names the contract apart
    func testGlobalContractCountsAsContract() async throws {
        var byHash = try XCTUnwrap(FakeNear.account() as? [String: Any])
        byHash["global_contract_hash"] = "BtA1BEFNS619KkvXFsgcpQ21Tb5yMm32aaUkn7xNothk"
        var byAccount = try XCTUnwrap(FakeNear.account() as? [String: Any])
        byAccount["global_contract_account_id"] = "factory.near"
        near.rpc.answer("query.view_account", .result(byHash), .result(byAccount))

        let first = try await Kit.accountState(accountId: "a.near", rpcApiProvider: near.rpcApiProvider)
        let second = try await Kit.accountState(accountId: "b.near", rpcApiProvider: near.rpcApiProvider)

        XCTAssertTrue(first.hasContract)
        XCTAssertTrue(second.hasContract)
    }

    // MARK: - hasFullAccess

    func testFullAccessKey() async throws {
        near.rpc.answer("query.view_access_key", .result(FakeNear.accessKey()), .result(FakeNear.accessKey(fullAccess: false)))

        let full = try await Kit.hasFullAccess(accountId: "alice.near", publicKey: publicKey, rpcApiProvider: near.rpcApiProvider)
        let limited = try await Kit.hasFullAccess(accountId: "alice.near", publicKey: publicKey, rpcApiProvider: near.rpcApiProvider)

        XCTAssertTrue(full)
        XCTAssertFalse(limited)
        XCTAssertEqual(near.rpc.calls("query.view_access_key").first?.params["public_key"] as? String, publicKey.description)
    }

    func testMissingKeyOrAccountIsNoAccess() async throws {
        near.rpc.answer("query.view_access_key", .error(cause: "UNKNOWN_ACCESS_KEY"), .error(cause: "UNKNOWN_ACCOUNT"))

        let missingKey = try await Kit.hasFullAccess(accountId: "alice.near", publicKey: publicKey, rpcApiProvider: near.rpcApiProvider)
        let missingAccount = try await Kit.hasFullAccess(accountId: "nobody.near", publicKey: publicKey, rpcApiProvider: near.rpcApiProvider)

        XCTAssertFalse(missingKey)
        XCTAssertFalse(missingAccount)
    }

    // MARK: - accessKeys

    // a function-call key's permission is an object; a secp256k1 key must not break the list
    func testAccessKeysTellFullFromFunctionCall() async throws {
        near.rpc.answer("query.view_access_key_list", .result(Self.keyList([
            Self.key(publicKey.description, fullAccess: true),
            Self.key("ed25519:5zset1JX4qp4PcR3N9KDSY6ATdgkrbBW5wFBGgz7vnAQ", fullAccess: false),
            Self.key("secp256k1:4H2tSbJcyq2FvnUVBUMr7gvd8eXdGoXr7idEhQ3gfLZbYqmyR8AuyGnGyHWnB9JVZo84ZnnaA2EX5YrNFV8oMYHT", fullAccess: true),
        ])))

        let keys = try await Kit.accessKeys(accountId: "alice.near", rpcApiProvider: near.rpcApiProvider)

        XCTAssertEqual(keys, [
            AccessKeyInfo(publicKey: publicKey.description, isFullAccess: true),
            AccessKeyInfo(publicKey: "ed25519:5zset1JX4qp4PcR3N9KDSY6ATdgkrbBW5wFBGgz7vnAQ", isFullAccess: false),
            AccessKeyInfo(publicKey: "secp256k1:4H2tSbJcyq2FvnUVBUMr7gvd8eXdGoXr7idEhQ3gfLZbYqmyR8AuyGnGyHWnB9JVZo84ZnnaA2EX5YrNFV8oMYHT", isFullAccess: true),
        ])
    }

    // nodes answer an empty list for an account that does not exist; older ones an error
    func testMissingAccountHasNoKeys() async throws {
        near.rpc.answer("query.view_access_key_list", .result(Self.keyList([])), .error(cause: "UNKNOWN_ACCOUNT"))

        let empty = try await Kit.accessKeys(accountId: "nobody.near", rpcApiProvider: near.rpcApiProvider)
        let unknown = try await Kit.accessKeys(accountId: "nobody.near", rpcApiProvider: near.rpcApiProvider)

        XCTAssertEqual(empty, [])
        XCTAssertEqual(unknown, [])
    }

    // MARK: - findAccounts

    // one candidate no node answers for is left out instead of failing the search
    func testUnanswerableCandidateIsSkipped() async throws {
        let implicit = publicKey.implicitAccountId
        near.indexer.answer("/v0/public_key/\(publicKey.description)", .json(["account_ids": ["alice.near", "bob.near"]]))
        // alice: both nodes time out; bob: full access
        near.rpc.answer("query.view_access_key", .failure(URLError(.timedOut)), .failure(URLError(.timedOut)), .result(FakeNear.accessKey()))

        let accounts = try await Kit.findAccounts(publicKey: publicKey, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider)

        XCTAssertEqual(accounts, [implicit, "bob.near"])
    }

    // when no candidate could be checked the search itself fails, so the app can offer a retry
    // rather than open the implicit account as if nothing else existed
    func testSearchFailsWhenNoCandidateCanBeChecked() async {
        near.indexer.answer("/v0/public_key/\(publicKey.description)", .json(["account_ids": ["alice.near"]]))
        near.rpc.answer("query.view_access_key", .failure(URLError(.timedOut)), .failure(URLError(.timedOut)))

        do {
            _ = try await Kit.findAccounts(publicKey: publicKey, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider)
            XCTFail("no error")
        } catch {
            XCTAssertNotNil(error as? NoEndpointAvailable)
        }
    }

    // a key flooded with strangers' accounts checks a bounded number of them
    func testCandidatesAreCapped() async throws {
        let flood = (1 ... 25).map { "spam\($0).near" }
        near.indexer.answer("/v0/public_key/\(publicKey.description)", .json(["account_ids": flood]))
        near.rpc.answer("query.view_access_key", Array(repeating: StubRpcTransport.Answer.error(cause: "UNKNOWN_ACCESS_KEY"), count: Kit.maxAccountCandidates))

        let accounts = try await Kit.findAccounts(publicKey: publicKey, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider)

        XCTAssertEqual(accounts, [publicKey.implicitAccountId])
        XCTAssertEqual(near.rpc.calls("query.view_access_key").count, Kit.maxAccountCandidates)
    }
}

private enum BigUIntHelper {
    static func near(_ value: Int) -> BigUInt {
        BigUInt(value) * BigUInt(10).power(24)
    }
}
