import BigInt
@testable import NearKit
import XCTest

/// A send is only reported as failed when it certainly did not reach the chain; anything uncertain
/// stays recorded as pending, so the wallet does not invite a second send (Android `TransactionSenderTest`).
final class TransactionSenderTests: XCTestCase {
    private var near: FakeNear!
    private var sender: TransactionSender!
    private var reported: [String]!
    private var signer: Signer!
    private var accountId: String!
    private var signed: SignedTransaction!

    private let included = StubRpcTransport.Answer.result(["final_execution_status": "INCLUDED"])
    private let invalidNonce = StubRpcTransport.Answer.error(cause: "INVALID_TRANSACTION", data: ["TxExecutionError": ["InvalidTxError": ["InvalidNonce": ["tx_nonce": 1, "ak_nonce": 1]]]])
    private let notEnoughBalance = StubRpcTransport.Answer.error(cause: "INVALID_TRANSACTION", data: ["TxExecutionError": ["InvalidTxError": ["NotEnoughBalance": [String: Any]()]]])

    override func setUpWithError() throws {
        near = try FakeNear()
        reported = []
        let vectors = try Fixtures.json("near-js-vectors")
        signer = try Signer.instance(secretKey: Fixtures.objects(vectors, "keys")[0].text("secretKey"))
        accountId = signer.publicKey.implicitAccountId
        signed = try signer.sign(NearTransaction(signerId: accountId, publicKey: signer.publicKey, nonce: 1, receiverId: "bob.near", blockHash: Data(count: 32), actions: [.transfer(deposit: 10)]))
        sender = TransactionSender(accountId: accountId, rpcApiProvider: near.rpcApiProvider, mainStorage: near.mainStorage, transactionStorage: near.transactionStorage) { [unowned self] transaction in
            reported.append(transaction.hash)
        }
    }

    override func tearDown() {
        near.assertNoUnexpectedRequests()
        super.tearDown()
    }

    private func submit() async throws -> Transaction {
        try await sender.submit(signed: signed, referenceHeight: 100)
    }

    private func stored() throws -> Transaction? {
        try near.transactionStorage.transaction(hash: signed.hash)
    }

    private func assertThrows(_ check: (Error) -> Bool, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> some Any) async {
        do {
            _ = try await body()
            XCTFail("no error", file: file, line: line)
        } catch {
            XCTAssertTrue(check(error), "unexpected \(error)", file: file, line: line)
        }
    }

    private static func isRejected(_ error: Error) -> Bool {
        if case .rejected = error as? SendError { return true }
        return false
    }

    // MARK: - Android TransactionSenderTest

    func testRecordsAcceptedSend() async throws {
        near.rpc.answer("send_tx", included)

        let transaction = try await submit()

        XCTAssertEqual(transaction.hash, signed.hash)
        XCTAssertEqual(try stored()?.isPending, true)
        XCTAssertEqual(try stored()?.expiresAfterHeight, 100 + TransactionSender.transactionValidityBlocks)
        XCTAssertEqual(reported, [signed.hash])
    }

    func testDuplicateRefusedAfterDroppedConnectionIsNotAFailure() async throws {
        // the first node included it but the connection dropped; the second refuses the used nonce
        near.rpc.answer("send_tx", .failure(URLError(.networkConnectionLost)), invalidNonce)
        near.rpc.answer("EXPERIMENTAL_tx_status", included)

        let transaction = try await submit()

        XCTAssertEqual(transaction.hash, signed.hash)
        XCTAssertEqual(try stored()?.isPending, true)
    }

    func testRejectionOfUnknownTransactionFails() async throws {
        near.rpc.answer("send_tx", notEnoughBalance)
        near.rpc.answer("EXPERIMENTAL_tx_status", .error(cause: "UNKNOWN_TRANSACTION"))

        await assertThrows({ error in
            guard case let .rejected(details) = error as? SendError else { return false }
            return details.contains("NotEnoughBalance")
        }) { try await submit() }

        XCTAssertNil(try stored())
        XCTAssertEqual(reported, [])
    }

    func testRejectionThatCannotBeCheckedKeepsRecord() async throws {
        near.rpc.answer("send_tx", notEnoughBalance)
        near.rpc.answer("EXPERIMENTAL_tx_status", .failure(URLError(.timedOut)), .failure(URLError(.timedOut)))

        await assertThrows(Self.isRejected) { try await submit() }

        XCTAssertEqual(try stored()?.isPending, true)
    }

    // Android throws an unknown error name at once (deny-list); here it is not deterministic, so
    // both nodes are asked and the send ends with NoEndpointAvailable. The record is kept either way.
    func testUnexpectedNodeErrorKeepsRecord() async throws {
        near.rpc.answer("send_tx", .error(cause: "SOMETHING_NEW"), .error(cause: "SOMETHING_NEW"))

        await assertThrows({ error in
            ((error as? NoEndpointAvailable)?.underlying as? RpcError)?.name == "SOMETHING_NEW"
        }) { try await submit() }

        XCTAssertEqual(try stored()?.isPending, true)
    }

    func testUnreachableNodesKeepRecord() async throws {
        near.rpc.answer("send_tx", .failure(URLError(.timedOut)), .failure(URLError(.timedOut)))

        await assertThrows({ $0 is NoEndpointAvailable }) { try await submit() }

        XCTAssertEqual(try stored()?.isPending, true)
        XCTAssertEqual(reported, [signed.hash])
    }

    // MARK: - iOS

    // nonce and block hash come from one view_access_key answer; its height bounds the pending record
    func testSendSignsWithNextNonceAndReferenceHeight() async throws {
        near.rpc.answer("query.view_access_key", .result(FakeNear.accessKey(nonce: 41, blockHeight: 5000)))
        near.rpc.answer("send_tx", included)

        let transaction = try await sender.send(signer: signer, receiverId: "bob.near", actions: [.transfer(deposit: 10)])

        let sentBase64 = try XCTUnwrap(near.rpc.calls("send_tx").first?.params["signed_tx_base64"] as? String)
        let sent = try SignedTransaction.decode(XCTUnwrap(Data(base64Encoded: sentBase64)))
        XCTAssertEqual(sent.transaction.nonce, 42)
        XCTAssertEqual(sent.transaction.blockHash, Data(count: 32))
        XCTAssertEqual(transaction.expiresAfterHeight, 5000 + TransactionSender.transactionValidityBlocks)
        XCTAssertEqual(near.rpc.calls("query.view_access_key").first?.params["finality"] as? String, "final")
    }

    // older nodes report a missing key inside a successful result
    func testMissingAccessKeyErrorInsideResult() async throws {
        near.rpc.answer("query.view_access_key", .result(["error": "access key ed25519:abc does not exist while viewing", "block_height": 1, "block_hash": "x"]))

        await assertThrows({ ($0 as? SendError) == .accessKeyNotFound }) {
            try await sender.send(signer: signer, receiverId: "bob.near", actions: [.transfer(deposit: 10)])
        }
        // deterministic: the second node is not asked
        XCTAssertEqual(near.rpc.calls("query.view_access_key").count, 1)
    }

    func testFunctionCallKeyCannotSend() async throws {
        near.rpc.answer("query.view_access_key", .result(FakeNear.accessKey(fullAccess: false)))

        await assertThrows({ ($0 as? SendError) == .notFullAccessKey }) {
            try await sender.send(signer: signer, receiverId: "bob.near", actions: [.transfer(deposit: 10)])
        }
    }

    // a transaction signed elsewhere expires relative to the latest known height
    func testSubmitWithoutReferenceHeightUsesChainState() async throws {
        try near.mainStorage.save(chainState: ChainState(blockHeight: 7000, gasPrice: 1))
        near.rpc.answer("send_tx", included)

        let transaction = try await sender.submit(signed: signed, referenceHeight: nil)

        XCTAssertEqual(transaction.expiresAfterHeight, 7000 + TransactionSender.transactionValidityBlocks)
    }

    // a node reporting a height near Int.max must not crash every send
    func testAbsurdHeightFromNodeDoesNotTrap() async throws {
        near.rpc.answer("query.view_access_key", .result(FakeNear.accessKey(blockHeight: Int.max)))
        near.rpc.answer("send_tx", included)

        let transaction = try await sender.send(signer: signer, receiverId: "bob.near", actions: [.transfer(deposit: 10)])

        XCTAssertEqual(transaction.expiresAfterHeight, Int.max &+ TransactionSender.transactionValidityBlocks)
    }
}
