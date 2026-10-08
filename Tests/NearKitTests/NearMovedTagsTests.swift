import BigInt
@testable import NearKit
import XCTest

/// Shapes of mainnet transactions from the wallet's history test vectors (hash prefixes in the
/// test names), reduced to the movements of `me` (Android `NearMovedTagsTest`).
final class NearMovedTagsTests: XCTestCase {
    private static let me = "me.near"
    private static let other = "other.near"
    private static let wrap = "wrap.near"
    private static let usdt = "usdt.tether-token.near"
    private static let token = "token.near"
    private static let intents = "intents.near"
    private static let dex = "v2.ref-finance.near"

    func testStorageDepositRefund_CXahHFrS() {
        // registering itself on wrap.near: 0.01 NEAR attached, 0.00875 sent back
        let tx = tx(
            signer: Self.me, receiver: Self.wrap,
            actions: [call("storage_deposit", near("0.01"))],
            near: [
                NearTransfer(from: Self.me, to: Self.wrap, amount: near("0.01"), kind: .functionCallDeposit, success: true, methodName: "storage_deposit"),
                NearTransfer(from: Self.wrap, to: Self.me, amount: near("0.00875"), kind: .transfer, success: true),
            ]
        )
        // a registration on its own is a NEAR payment, and its refund is netted
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), -BigInt(near("0.00125")))
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [TransactionTag.tokenNative])
    }

    func testRegistrationBundledWithTokenSend_F2vmbn2C() {
        let tx = tx(
            signer: Self.me, receiver: Self.usdt,
            actions: [call("storage_deposit", near("0.00125")), call("ft_transfer", 1)],
            near: [
                NearTransfer(from: Self.me, to: Self.usdt, amount: near("0.00125"), kind: .functionCallDeposit, success: true, methodName: "storage_deposit"),
                NearTransfer(from: Self.me, to: Self.usdt, amount: 1, kind: .functionCallDeposit, success: true, methodName: "ft_transfer"),
            ],
            ft: [FtTransfer(contractId: Self.usdt, from: Self.me, to: Self.other, amount: 2_001_000_000, memo: nil)]
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), 0)
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [Self.usdt])
    }

    func testBundledRegistrationFullyRefunded_btg9XFgo() {
        // the receiver was already registered, so the whole deposit comes back
        let tx = tx(
            signer: Self.me, receiver: Self.token,
            actions: [call("storage_deposit", near("0.01")), call("ft_transfer", 1)],
            near: [
                NearTransfer(from: Self.me, to: Self.token, amount: near("0.01"), kind: .functionCallDeposit, success: true, methodName: "storage_deposit"),
                NearTransfer(from: Self.me, to: Self.token, amount: 1, kind: .functionCallDeposit, success: true, methodName: "ft_transfer"),
                NearTransfer(from: Self.token, to: Self.me, amount: near("0.01"), kind: .transfer, success: true),
            ],
            ft: [FtTransfer(contractId: Self.token, from: Self.me, to: Self.other, amount: 10, memo: nil)]
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), 0)
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [Self.token])
    }

    func testFailedIncomingTransfer_5vg9o62B() {
        // someone else's transaction whose transfer to me failed and was refunded to them
        let tx = tx(
            signer: Self.other, receiver: Self.me,
            actions: [TxAction(type: "Transfer", deposit: near("0.001"))],
            near: [NearTransfer(from: Self.other, to: Self.me, amount: near("0.001"), kind: .transfer, success: false)],
            status: .failed
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), 0)
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [])
    }

    func testFailedOwnSendStaysInNearHistory() {
        let tx = tx(
            signer: Self.me, receiver: Self.other,
            actions: [TxAction(type: "Transfer", deposit: near("1"))],
            near: [NearTransfer(from: Self.me, to: Self.other, amount: near("1"), kind: .transfer, success: false)],
            status: .failed
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), 0)
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [TransactionTag.tokenNative])
    }

    func testWrapDeposit_FdAexqEm() {
        let tx = tx(
            signer: Self.me, receiver: Self.wrap,
            actions: [call("near_deposit", near("60"))],
            near: [NearTransfer(from: Self.me, to: Self.wrap, amount: near("60"), kind: .functionCallDeposit, success: true, methodName: "near_deposit")],
            ft: [FtTransfer(contractId: Self.wrap, from: nil, to: Self.me, amount: near("60"), memo: nil)]
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), -BigInt(near("60")))
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [TransactionTag.tokenNative, Self.wrap])
    }

    func testWrapWithdraw_CYSanB9J() {
        let tx = tx(
            signer: Self.me, receiver: Self.wrap,
            actions: [call("near_withdraw", 1)],
            near: [
                NearTransfer(from: Self.me, to: Self.wrap, amount: 1, kind: .functionCallDeposit, success: true, methodName: "near_withdraw"),
                NearTransfer(from: Self.wrap, to: Self.me, amount: near("5.11"), kind: .transfer, success: true),
            ],
            ft: [FtTransfer(contractId: Self.wrap, from: Self.me, to: nil, amount: near("5.11"), memo: nil)]
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), BigInt(near("5.11")))
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [TransactionTag.tokenNative, Self.wrap])
    }

    func testOneYoctoProofOnNonTokenCall_CuWAXw5d() {
        // NEP-245 mt_transfer on intents.near: no NEAR is paid, but the call stays in NEAR's history
        let tx = tx(
            signer: Self.me, receiver: Self.intents,
            actions: [call("mt_transfer", 1)],
            near: [NearTransfer(from: Self.me, to: Self.intents, amount: 1, kind: .functionCallDeposit, success: true, methodName: "mt_transfer")]
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), 0)
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [TransactionTag.tokenNative])
    }

    func testStorageDepositOnNonTokenContract_rd4hWHps() {
        let tx = tx(
            signer: Self.me, receiver: Self.dex,
            actions: [call("storage_deposit", near("0.01")), call("register_tokens", 1)],
            near: [
                NearTransfer(from: Self.me, to: Self.dex, amount: near("0.01"), kind: .functionCallDeposit, success: true, methodName: "storage_deposit"),
                NearTransfer(from: Self.me, to: Self.dex, amount: 1, kind: .functionCallDeposit, success: true, methodName: "register_tokens"),
            ]
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), -BigInt(near("0.01")))
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [TransactionTag.tokenNative])
    }

    func testWithdrawNextToTokenSendIsNotTakenForARefund() {
        // a wrap.near payout larger than the registration deposit is a real movement
        let tx = tx(
            signer: Self.me, receiver: Self.wrap,
            actions: [call("storage_deposit", near("0.00125")), call("ft_transfer", 1), call("near_withdraw", 1)],
            near: [
                NearTransfer(from: Self.me, to: Self.wrap, amount: near("0.00125"), kind: .functionCallDeposit, success: true, methodName: "storage_deposit"),
                NearTransfer(from: Self.me, to: Self.wrap, amount: 1, kind: .functionCallDeposit, success: true, methodName: "ft_transfer"),
                NearTransfer(from: Self.me, to: Self.wrap, amount: 1, kind: .functionCallDeposit, success: true, methodName: "near_withdraw"),
                NearTransfer(from: Self.wrap, to: Self.me, amount: near("2"), kind: .transfer, success: true),
            ],
            ft: [FtTransfer(contractId: Self.wrap, from: Self.me, to: nil, amount: near("2"), memo: nil)]
        )
        XCTAssertEqual(tx.nearMoved(accountId: Self.me), BigInt(near("2")))
        XCTAssertEqual(TransactionConverter.tags(transaction: tx, accountId: Self.me), [TransactionTag.tokenNative, Self.wrap])
    }

    // the method name survives storage; records written before it existed decode without one
    func testNearTransferMethodNameIsStored() throws {
        let transfer = NearTransfer(from: Self.me, to: Self.usdt, amount: 1, kind: .functionCallDeposit, success: true, methodName: "ft_transfer")
        let decoded = try JSONDecoder().decode(NearTransfer.self, from: JSONEncoder().encode(transfer))
        XCTAssertEqual(decoded, transfer)

        let legacy = Data(#"{"from":"me.near","to":"usdt.tether-token.near","amount":"1","kind":"FunctionCallDeposit","success":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(NearTransfer.self, from: legacy).methodName)
    }

    private func tx(signer: String, receiver: String, actions: [TxAction], near: [NearTransfer] = [], ft: [FtTransfer] = [], status: Transaction.Status = .success) -> Transaction {
        Transaction(
            hash: "hash", blockHeight: 1, timestamp: 1, signerId: signer, receiverId: receiver, actions: actions,
            nearTransfers: near, ftTransfers: ft, fee: 1, status: status, failure: nil, expiresAfterHeight: nil
        )
    }

    private func call(_ method: String, _ deposit: BigUInt) -> TxAction {
        TxAction(type: "FunctionCall", deposit: deposit, methodName: method)
    }

    private func near(_ value: String) -> BigUInt {
        NearAmount.toYocto(near: Decimal(string: value)!)!
    }
}
