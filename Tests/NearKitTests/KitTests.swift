import BigInt
import GRDB
@testable import NearKit
import XCTest

/// Facade rules that sit above the providers: receiver checks, token deposits, hot RPC swap,
/// per-instance watched tokens, wallet-free lookups and the storage layout.
final class KitTests: XCTestCase {
    private static let accountId = "alice.near"
    private static let usdt = "usdt.tether-token.near"

    private var near: FakeNear!
    private var kit: Kit!
    private var signer: Signer!

    override func setUpWithError() throws {
        near = try FakeNear()
        kit = try near.kit(accountId: Self.accountId)
        signer = try Signer.instance(privateKey: Data(repeating: 7, count: 32))
    }

    override func tearDown() {
        near.assertNoUnexpectedRequests()
        super.tearDown()
    }

    private func assertThrows(_ expected: SendError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> some Any) async {
        do {
            _ = try await body()
            XCTFail("no error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SendError, expected, file: file, line: line)
        }
    }

    // MARK: - Receiver checks

    // A named receiver that does not exist is refused before anything is signed.
    func testSendNearRefusesMissingNamedReceiver() async {
        near.rpc.answer("query.view_account", .error(cause: "UNKNOWN_ACCOUNT"))

        await assertThrows(.receiverNotFound("bob.near")) {
            try await kit.sendNear(receiverId: "bob.near", amount: 1, signer: signer)
        }
        XCTAssertTrue(near.rpc.calls("query.view_access_key").isEmpty)
    }

    // An implicit receiver is not checked: the transfer creates it. The send goes on to the access key.
    func testSendNearDoesNotCheckImplicitReceiver() async {
        near.rpc.answer("query.view_access_key", .error(cause: "UNKNOWN_ACCESS_KEY"))

        await assertThrows(.accessKeyNotFound) {
            try await kit.sendNear(receiverId: String(repeating: "a", count: 64), amount: 1, signer: signer)
        }
        XCTAssertTrue(near.rpc.calls("query.view_account").isEmpty)
    }

    func testSendNearRefusesZeroAmount() async {
        await assertThrows(.invalidAmount) {
            try await kit.sendNear(receiverId: String(repeating: "a", count: 64), amount: 0, signer: signer)
        }
    }

    // MARK: - Token sends

    private func queueUnregisteredReceiver(min: String = "1250000000000000000000") {
        near.rpc.answer("query.call_function", .result(FakeNear.callResult(NSNull())), .result(FakeNear.callResult(["min": min, "max": NSNull()])))
    }

    // The receiver is not checked for a token send (Android parity); a deposit other than the
    // confirmed one is refused before anything is signed.
    func testSendFtRefusesChangedStorageDepositWithoutCheckingReceiver() async {
        queueUnregisteredReceiver()
        let estimate = FtTransferEstimate(fee: FeeEstimate(gas: 1, fee: 1, requiredBalance: 1), storageDeposit: nil)

        await assertThrows(.storageDepositChanged(confirmed: nil, required: BigUInt("1250000000000000000000"))) {
            try await kit.sendFt(contractId: Self.usdt, receiverId: "bob.near", amount: 5, estimate: estimate, signer: signer)
        }
        XCTAssertTrue(near.rpc.calls("query.view_account").isEmpty)
        XCTAssertTrue(near.rpc.calls("query.view_access_key").isEmpty)
        XCTAssertEqual(near.rpc.calls("query.call_function").map { $0.params["method_name"] as? String }, ["storage_balance_of", "storage_balance_bounds"])
    }

    // A token contract cannot ask for more than 0.1 NEAR to register the receiver.
    func testStorageDepositAboveCapIsRefused() async {
        queueUnregisteredReceiver(min: "100000000000000000000001")

        await assertThrows(.storageDepositTooHigh(BigUInt("100000000000000000000001"))) {
            try await kit.ftStorageDepositRequired(contractId: Self.usdt, accountId: "bob.near")
        }
    }

    func testRegisteredReceiverNeedsNoDeposit() async throws {
        near.rpc.answer("query.call_function", .result(FakeNear.callResult(["total": "1250000000000000000000", "available": "0"])))

        let deposit = try await kit.ftStorageDepositRequired(contractId: Self.usdt, accountId: "bob.near")

        XCTAssertNil(deposit)
    }

    // MARK: - Signing for someone else

    func testSignTransactionRequiresTheKitsAccount() throws {
        let transaction = try NearTransaction(signerId: "mallory.near", publicKey: signer.publicKey, nonce: 1, receiverId: "bob.near", blockHash: Data(count: 32), actions: [.transfer(deposit: 1)])

        XCTAssertThrowsError(try kit.signTransaction(transaction, signer: signer)) { error in
            XCTAssertEqual(error as? SendError, .signerMismatch)
        }
    }

    // MARK: - Instance state

    // Watched tokens belong to one kit instance; invalid ids are dropped.
    func testWatchedTokensArePerKitInstance() throws {
        let otherNear = try FakeNear()
        let other = try otherNear.kit(accountId: Self.accountId)

        kit.watchTokens(contractIds: [Self.usdt, "Not Valid!"])

        XCTAssertEqual(kit.watchedTokens, [Self.usdt])
        XCTAssertEqual(other.watchedTokens, [])
    }

    // The RPC list is swapped in place: the next call starts from the first new URL.
    func testSetRpcUrlsHotSwap() async throws {
        let replacement = [URL(string: "https://rpc3.test/")!, URL(string: "https://rpc4.test/")!]
        near.rpc.answer("query.view_account", .failure(URLError(.timedOut)), .result(FakeNear.account()), .result(FakeNear.account()))
        _ = try await kit.doesAccountExist(accountId: "bob.near")
        XCTAssertEqual(near.rpcApiProvider.preferredIndex, 1)

        try kit.set(rpcUrls: replacement)
        let exists = try await kit.doesAccountExist(accountId: "bob.near")

        XCTAssertTrue(exists)
        XCTAssertEqual(near.rpc.calls.last?.url, replacement[0])
        XCTAssertEqual(near.rpcApiProvider.urls, replacement)
        XCTAssertThrowsError(try kit.set(rpcUrls: [])) { XCTAssertTrue($0 is NoEndpointAvailable) }
        XCTAssertEqual(near.rpcApiProvider.urls, replacement)
    }

    // MARK: - Wallet-free lookups

    // The implicit account comes first, even unfunded; named accounts the index reports are kept
    // only when the key is a full-access key there.
    func testFindAccounts() async throws {
        let publicKey = signer.publicKey
        let implicit = publicKey.implicitAccountId
        near.indexer.answer("/v0/public_key/\(publicKey.description)", .json(["account_ids": ["alice.near", implicit, "bob.near", "Not Valid!"]]))
        near.rpc.answer("query.view_access_key", .result(FakeNear.accessKey()), .result(FakeNear.accessKey(fullAccess: false)))

        let accounts = try await Kit.findAccounts(publicKey: publicKey, rpcApiProvider: near.rpcApiProvider, indexerProvider: near.fastNearProvider)

        XCTAssertEqual(accounts, [implicit, "alice.near"])
        XCTAssertEqual(near.rpc.calls("query.view_access_key").map { $0.params["account_id"] as? String }, ["alice.near", "bob.near"])
    }

    func testFtMetadataIsValidatedAndCached() async throws {
        near.rpc.answer("query.call_function", .result(FakeNear.callResult(["spec": "ft-1.0.0", "name": "Tether USD", "symbol": "USDt", "decimals": 6])))

        let metadata = try await kit.ftMetadata(contractId: Self.usdt)
        let cached = try await kit.ftMetadata(contractId: Self.usdt)

        XCTAssertEqual(metadata, FtMetadata(contractId: Self.usdt, name: "Tether USD", symbol: "USDt", decimals: 6, spec: "ft-1.0.0"))
        XCTAssertEqual(cached, metadata)
        XCTAssertEqual(near.rpc.calls("query.call_function").count, 1)
    }

    func testFtMetadataWithInvalidDecimalsIsRefused() async {
        near.rpc.answer("query.call_function", .result(FakeNear.callResult(["name": "X", "symbol": "X", "decimals": 65])))

        do {
            _ = try await kit.ftMetadata(contractId: Self.usdt)
            XCTFail("no error")
        } catch {
            XCTAssertTrue(error is InvalidResponse)
        }
    }

    // MARK: - Storage

    // `transaction` is an SQLite keyword; the table is `transactions`, as in XrpKit and SolanaKit.
    func testTransactionTableIsNamedTransactions() throws {
        let tables = try near.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }

        XCTAssertTrue(tables.contains("transactions"))
        XCTAssertFalse(tables.contains("transaction"))
        XCTAssertTrue(tables.contains("transactionTag"))
    }

    // Newest first by (timestamp, hash), paged with the last item's timestamp and hash, filtered by token tag.
    func testTransactionsPageByTimestampAndHash() throws {
        func record(_ hash: String, _ timestamp: Int) -> Transaction {
            Transaction(hash: hash, blockHeight: 1, timestamp: timestamp, signerId: Self.accountId, receiverId: "bob.near", actions: [], nearTransfers: [], ftTransfers: [], fee: 0, status: .success, failure: nil, expiresAfterHeight: nil)
        }
        let tagged: [(Transaction, Set<String>)] = [
            (record("a", 10), [TransactionTag.tokenNative]),
            (record("b", 20), [TransactionTag.tokenNative, Self.usdt]),
            (record("c", 20), [Self.usdt]),
            (record("d", 30), [TransactionTag.tokenNative]),
        ]
        try near.transactionStorage.save(transactions: tagged)

        XCTAssertEqual(try kit.transactions().map(\.hash), ["d", "c", "b", "a"])
        XCTAssertEqual(try kit.transactions(beforeTimestamp: 20, beforeHash: "c", limit: 2).map(\.hash), ["b", "a"])
        XCTAssertEqual(try kit.transactions(token: Self.usdt).map(\.hash), ["c", "b"])
        XCTAssertEqual(try kit.transactions(token: TransactionTag.tokenNative, limit: 2).map(\.hash), ["d", "b"])
    }
}
