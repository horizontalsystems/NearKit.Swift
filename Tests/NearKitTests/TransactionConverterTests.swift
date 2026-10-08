import BigInt
@testable import NearKit
import XCTest

/// Fixtures are mainnet transactions as FastNEAR `/v0/transactions` and RPC `EXPERIMENTAL_tx_status`
/// returned them (Android `TransactionConverterTest`).
final class TransactionConverterTests: XCTestCase {
    private static let sender = "9c484fa5d2d069569ba063fc555c34e621ccd88fdbb0295fc79bad232621c5c1"
    private static let receiver = "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"
    private static let usdt = "usdt.tether-token.near"
    private static let ftSender = "closemeat6237.near"
    private static let ftReceiver = "28f6283e2f11a3364e374e944bbc1fd497e765dbd7fec35835501d9a592d9197"
    private static let wrap = "wrap.testnet"
    private static let testnetSender = "nearkit-1790327773094.testnet"
    private static let testnetReceiver = "9d0aa40809e3438c41c6af127b3711c18ae2698f8f4371f172c436bdd608cd1a"

    private var fastNear: [RpcJson]!

    override func setUpWithError() throws {
        fastNear = try Fixtures.objects(Fixtures.json("fastnear-transactions"), "transactions")
    }

    private func fastNearTx(_ hashPrefix: String) throws -> RpcJson {
        try XCTUnwrap(fastNear.first { ($0.object("transaction")?.string("hash") ?? "").hasPrefix(hashPrefix) })
    }

    func testIncomingNearTransfer() throws {
        let (tx, tags) = try TransactionConverter.convert(item: fastNearTx("BiuX"), accountId: Self.receiver, fallbackTimestamp: 0)

        XCTAssertEqual(tx.status, .success)
        XCTAssertEqual(tx.blockHeight, 217_084_526)
        XCTAssertEqual(tx.timestamp, 1_790_273_822)
        XCTAssertEqual(tx.nearTransfers, [NearTransfer(from: Self.sender, to: Self.receiver, amount: BigUInt("847680490000000000000000"), kind: .transfer, success: true)])
        XCTAssertEqual(tx.nearNetChange(accountId: Self.receiver), BigInt("847680490000000000000000"))
        // the gas refund from `system` to the sender is not a transfer
        XCTAssertFalse(tx.nearTransfers.contains { $0.from == "system" })
        XCTAssertEqual(tags, [TransactionTag.tokenNative])
    }

    func testRpcShapeGivesTheSameRecordAsFastNear() throws {
        let rpc = try Fixtures.json("rpc-tx-status")
        let (fromRpc, rpcTags) = try TransactionConverter.convert(item: rpc, accountId: Self.receiver, fallbackTimestamp: 42)
        let (fromIndex, indexTags) = try TransactionConverter.convert(item: fastNearTx("BiuX"), accountId: Self.receiver, fallbackTimestamp: 0)

        XCTAssertEqual(fromRpc.status, fromIndex.status)
        XCTAssertEqual(fromRpc.nearTransfers, fromIndex.nearTransfers)
        XCTAssertEqual(fromRpc.fee, fromIndex.fee)
        XCTAssertEqual(fromRpc.actions, fromIndex.actions)
        XCTAssertEqual(rpcTags, indexTags)
        // RPC outcomes carry no block time, so the fallback is used
        XCTAssertEqual(fromRpc.timestamp, 42)
    }

    func testFailedTransactionKeepsFailureAndFee() throws {
        let (tx, tags) = try TransactionConverter.convert(item: fastNearTx("Hdg"), accountId: Self.receiver, fallbackTimestamp: 0)

        XCTAssertEqual(tx.status, .failed)
        XCTAssertTrue(try XCTUnwrap(tx.failure).contains("LackBalanceForState"))
        XCTAssertEqual(tx.actions.map(\.type), ["AddKey"])
        XCTAssertGreaterThan(try XCTUnwrap(tx.fee), 0)
        XCTAssertEqual(tags, [TransactionTag.tokenNative])
    }

    func testOutgoingTokenTransferFromEventLog() throws {
        let (tx, tags) = try TransactionConverter.convert(item: fastNearTx("JDtz"), accountId: Self.ftSender, fallbackTimestamp: 0)

        XCTAssertEqual(tx.status, .success)
        XCTAssertEqual(tx.ftTransfers, [FtTransfer(contractId: Self.usdt, from: Self.ftSender, to: Self.ftReceiver, amount: 5_000_000_000, memo: nil)])
        // the 1 yocto proof deposit is a NEAR movement to the token contract, but no NEAR payment
        XCTAssertEqual(tx.nearTransfers, [NearTransfer(from: Self.ftSender, to: Self.usdt, amount: 1, kind: .functionCallDeposit, success: true, methodName: "ft_transfer")])
        XCTAssertEqual(tx.nearMoved(accountId: Self.ftSender), 0)
        XCTAssertEqual(tx.fee, BigUInt("31368617837000000000") + BigUInt("208972821341200000000"))
        XCTAssertEqual(tx.actions.map(\.methodName), ["ft_transfer"])
        XCTAssertTrue(try XCTUnwrap(tx.actions.first?.args).contains(Self.ftReceiver))
        // a token send stays out of NEAR's history (Android `TransactionConverter.tags`)
        XCTAssertEqual(tags, [Self.usdt])
    }

    func testIncomingTokenTransferIsTaggedWithTheTokenOnly() throws {
        let (tx, tags) = try TransactionConverter.convert(item: fastNearTx("JDtz"), accountId: Self.ftReceiver, fallbackTimestamp: 0)

        XCTAssertEqual(tx.ftTransfers.map(\.to), [Self.ftReceiver])
        XCTAssertEqual(tx.nearNetChange(accountId: Self.ftReceiver), 0)
        XCTAssertEqual(tags, [Self.usdt])
    }

    func testUnrelatedAccountSeesNoMovements() throws {
        let (tx, tags) = try TransactionConverter.convert(item: fastNearTx("JDtz"), accountId: "someone.near", fallbackTimestamp: 0)

        XCTAssertTrue(tx.ftTransfers.isEmpty)
        XCTAssertTrue(tx.nearTransfers.isEmpty)
        XCTAssertTrue(tags.isEmpty)
    }

    func testMissingOutcomeIsPending() throws {
        var item = try fastNearTx("BiuX")
        item["receipts"] = nil

        let (tx, _) = try TransactionConverter.convert(item: item, accountId: Self.receiver, fallbackTimestamp: 7)

        XCTAssertEqual(tx.status, .pending)
        XCTAssertNil(tx.fee)
    }

    func testPendingTokenSendPredictsTheTransfer() throws {
        let unsigned = try NearTransaction(
            signerId: Self.ftSender,
            publicKey: PublicKey(data: Data(count: 32)),
            nonce: 1,
            receiverId: Self.usdt,
            blockHash: Data(count: 32),
            actions: [
                .functionCall(methodName: "storage_deposit", args: Data(#"{"account_id":"bob.near","registration_only":true}"#.utf8), gas: 10, deposit: BigUInt("1250000000000000000000")),
                .functionCall(methodName: "ft_transfer", args: Data(#"{"receiver_id":"bob.near","amount":"7","memo":"hi"}"#.utf8), gas: 10, deposit: 1),
            ]
        )

        let (tx, tags) = TransactionConverter.pending(transaction: unsigned, hash: "hash", expiresAfterHeight: 100, timestamp: 5)

        XCTAssertEqual(tx.status, .pending)
        XCTAssertEqual(tx.ftTransfers, [FtTransfer(contractId: Self.usdt, from: Self.ftSender, to: "bob.near", amount: 7, memo: "hi")])
        XCTAssertEqual(tx.nearNetChange(accountId: Self.ftSender), -BigInt("1250000000000000000001"))
        XCTAssertEqual(tx.expiresAfterHeight, 100)
        // the registration deposit and the 1 yocto proof belong to the token send
        XCTAssertEqual(tx.nearMoved(accountId: Self.ftSender), 0)
        XCTAssertEqual(tags, [Self.usdt])
    }

    func testLegacyTransferLogWithMemo() throws {
        // wrap.testnet predates NEP-297 events and logs plain text, like wrap.near on mainnet
        let rpc = try Fixtures.json("rpc-legacy-ft-transfer")
        let (tx, tags) = try TransactionConverter.convert(item: rpc, accountId: Self.testnetSender, fallbackTimestamp: 0)

        XCTAssertEqual(tx.ftTransfers, [FtTransfer(contractId: Self.wrap, from: Self.testnetSender, to: Self.testnetReceiver, amount: BigUInt("100000000000000000000000"), memo: "nearkit")])
        XCTAssertEqual(tags, [Self.wrap])
    }

    func testLegacyWrapDepositIsAMint() throws {
        let rpc = try Fixtures.json("rpc-legacy-wrap")
        let (tx, _) = try TransactionConverter.convert(item: rpc, accountId: Self.testnetSender, fallbackTimestamp: 0)

        XCTAssertEqual(tx.ftTransfers, [FtTransfer(contractId: Self.wrap, from: nil, to: Self.testnetSender, amount: BigUInt("500000000000000000000000"), memo: nil)])
        // 0.5 NEAR wrapped plus the 0.00125 NEAR storage registration, both attached as deposits
        XCTAssertEqual(tx.nearNetChange(accountId: Self.testnetSender), -BigInt("501250000000000000000000"))
        XCTAssertEqual(tx.actions.map(\.methodName), ["storage_deposit", "near_deposit"])
    }
}
