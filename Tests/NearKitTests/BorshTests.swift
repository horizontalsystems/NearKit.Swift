import BigInt
import HsExtensions
@testable import NearKit
import XCTest

/// Hand-assembled Borsh layouts for the actions near-js-vectors.json does not cover, plus the
/// decoder's refusals; WalletConnect requests are decoded with this code.
final class BorshTests: XCTestCase {
    private let key1 = try! PublicKey(data: Data(repeating: 1, count: 32))
    private let key3 = try! PublicKey(data: Data(repeating: 3, count: 32))

    private func hex(_ byte: String, _ count: Int) -> String {
        String(repeating: byte, count: count)
    }

    /// signer "ab", key 0x01…, nonce 1, receiver "ab", block hash 0x02…, followed by the action vector.
    private func transactionHex(actions: String, count: Int = 1) -> String {
        "02000000" + "6162" + "00" + hex("01", 32) + "0100000000000000" + "02000000" + "6162" + hex("02", 32) + u32(count) + actions
    }

    private func u32(_ value: Int) -> String {
        withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }.hs.hex
    }

    private func transaction(_ actions: [Action]) throws -> NearTransaction {
        try NearTransaction(signerId: "ab", publicKey: key1, nonce: 1, receiverId: "ab", blockHash: Data(repeating: 2, count: 32), actions: actions)
    }

    private func assertRoundTrip(_ actions: [Action], _ actionsHex: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = transactionHex(actions: actionsHex, count: actions.count)
        XCTAssertEqual(try transaction(actions).encode().hs.hex, expected, file: file, line: line)
        XCTAssertEqual(try NearTransaction.decode(XCTUnwrap(expected.hs.hexData)), try transaction(actions), file: file, line: line)
    }

    private func assertDecodeFails(_ hexString: String, _ expected: CodecError, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(hexString.hs.hexData)
        XCTAssertThrowsError(try NearTransaction.decode(data), file: file, line: line) { error in
            XCTAssertEqual(error as? CodecError, expected, file: file, line: line)
        }
    }

    func testAddFullAccessKey() throws {
        try assertRoundTrip(
            [.addKey(publicKey: key3, accessKey: AccessKey(nonce: 0, permission: .fullAccess))],
            "05" + "00" + hex("03", 32) + hex("00", 8) + "01"
        )
    }

    func testAddFunctionCallKeyWithAllowance() throws {
        try assertRoundTrip(
            [.addKey(publicKey: key3, accessKey: AccessKey(nonce: 7, permission: .functionCall(allowance: 1, receiverId: "ab", methodNames: ["m"])))],
            "05" + "00" + hex("03", 32) + "07" + hex("00", 7) + "00" + "01" + "01" + hex("00", 15) + "02000000" + "6162" + "01000000" + "01000000" + "6d"
        )
    }

    func testAddFunctionCallKeyWithoutAllowance() throws {
        try assertRoundTrip(
            [.addKey(publicKey: key3, accessKey: AccessKey(nonce: 0, permission: .functionCall(allowance: nil, receiverId: "ab", methodNames: [])))],
            "05" + "00" + hex("03", 32) + hex("00", 8) + "00" + "00" + "02000000" + "6162" + "00000000"
        )
    }

    func testDeleteKeyAndOtherActions() throws {
        try assertRoundTrip(
            [
                .deleteKey(publicKey: key3),
                .createAccount,
                .deployContract(code: Data([0xAA])),
                .stake(stake: 2, publicKey: key3),
                .deleteAccount(beneficiaryId: "ab"),
            ],
            "06" + "00" + hex("03", 32)
                + "00"
                + "01" + "01000000" + "aa"
                + "04" + "02" + hex("00", 15) + "00" + hex("03", 32)
                + "07" + "02000000" + "6162"
        )
    }

    func testU128IsLittleEndianAndBounded() throws {
        var writer = BorshWriter()
        try writer.u128(BigUInt(1) << 64 + 2)
        XCTAssertEqual(writer.data.hs.hex, "02" + hex("00", 7) + "01" + hex("00", 7))

        try writer.u128((BigUInt(1) << 128) - 1)
        XCTAssertThrowsError(try writer.u128(BigUInt(1) << 128)) { error in
            XCTAssertEqual(error as? CodecError, .outOfRange)
        }
        XCTAssertThrowsError(try transaction([.transfer(deposit: BigUInt(1) << 128)]))
    }

    func testRejectsTransactionV1() throws {
        try assertDecodeFails("01" + transactionHex(actions: "00"), .unsupportedTransactionVersion)
    }

    func testRejectsUnsupportedActions() throws {
        for tag in [8, 9, 10, 255] {
            try assertDecodeFails(transactionHex(actions: String(format: "%02x", tag)), .unsupportedAction(UInt8(tag)))
        }
    }

    func testRejectsUnknownAccessKeyPermission() throws {
        for permission in [2, 3] {
            try assertDecodeFails(
                transactionHex(actions: "05" + "00" + hex("03", 32) + hex("00", 8) + String(format: "%02x", permission)),
                .invalidAccessKeyPermission(UInt8(permission))
            )
        }
    }

    func testRejectsNonEd25519Keys() throws {
        for keyType in [1, 2] {
            let tx = "02000000" + "6162" + String(format: "%02x", keyType) + hex("01", 32) + "0100000000000000" + "02000000" + "6162" + hex("02", 32) + "00000000"
            try assertDecodeFails(tx, .unsupportedKeyType(UInt8(keyType)))
        }
        let signed = transactionHex(actions: "00") + "01" + hex("05", 64)
        XCTAssertThrowsError(try SignedTransaction.decode(XCTUnwrap(signed.hs.hexData))) { error in
            XCTAssertEqual(error as? CodecError, .unsupportedKeyType(1))
        }
    }

    func testRejectsInvalidUtf8() throws {
        try assertDecodeFails(transactionHex(actions: "07" + "02000000" + "c328"), .invalidUtf8)
    }

    func testRejectsTrailingBytesAndTruncation() throws {
        try assertDecodeFails(transactionHex(actions: "00") + "00", .trailingBytes)
        try assertDecodeFails(transactionHex(actions: "03" + hex("00", 15)), .unexpectedEnd)
        try assertDecodeFails(transactionHex(actions: "07" + "ffffffff"), .lengthExceedsData)
        try assertDecodeFails(transactionHex(actions: "", count: 1000), .lengthExceedsData)
    }
}
