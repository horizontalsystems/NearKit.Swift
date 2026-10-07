import HsCryptoKit
@testable import NearKit
import XCTest

final class AccountIdTests: XCTestCase {
    func testAcceptsValidIds() {
        for id in [
            "near", "alice.near", "a-b_c.tg", "usdt.tether-token.near", "0x1234567890abcdef1234567890abcdef12345678",
            "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412", "ab",
        ] {
            XCTAssertTrue(AccountId.isValid(id), id)
        }
    }

    func testRejectsInvalidIds() {
        for id in [
            "a", "Alice.near", "alice..near", ".near", "near.", "a--b", "a_-b", "alice near", "alice@near",
            String(repeating: "a", count: 65), "", "ed25519:6j4b6zUaty6fD1awqcGCCU9JYGCWYUgdJhQrzfZhqE25",
        ] {
            XCTAssertFalse(AccountId.isValid(id), id)
        }
    }

    func testClassifiesIds() {
        XCTAssertEqual(AccountId.kind("alice.near"), .named)
        XCTAssertEqual(AccountId.kind("5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"), .nearImplicit)
        XCTAssertEqual(AccountId.kind("0x1234567890abcdef1234567890abcdef12345678"), .ethImplicit)
        XCTAssertEqual(AccountId.kind("0s1234567890abcdef1234567890abcdef12345678"), .deterministic)
        XCTAssertNil(AccountId.kind("0X1234"))
        // 64 hex characters but upper case is not a valid account id at all
        XCTAssertNil(AccountId.kind("5510E2B44CAE6EB807E3E0E45D579DDA058C274ABCBA15E5CB84636F5D1EE412"))
    }

    func testBase58RoundTripsLeadingZeros() throws {
        let data = Data([0, 0, 1, 2, 3, 0xFF])
        XCTAssertEqual(try Base58.strictDecode(Base58.encode(data)), data)
        XCTAssertEqual(Base58.encode(Data([0, 0])), "11")
        XCTAssertEqual(try Base58.strictDecode("11111111111111111111111111111111"), Data(count: 32))
    }

    func testBase58RejectsZeroLetter() {
        XCTAssertThrowsError(try Base58.strictDecode("0OIl")) { error in
            XCTAssertEqual(error as? CodecError, .invalidBase58)
        }
    }

    // iOS additions

    func testRejectsNonAsciiDigitsAndTrailingNewline() {
        // fullwidth and Arabic-Indic digits are Unicode digits, which `\d` would match in ICU
        XCTAssertFalse(AccountId.isValid("alice\u{FF11}.near"))
        XCTAssertFalse(AccountId.isValid("alice\u{0661}.near"))
        XCTAssertFalse(AccountId.isValid("\u{FF11}\u{FF12}"))
        XCTAssertFalse(AccountId.isValid("alice.near\n"))
        // 64 characters but more than 64 bytes
        XCTAssertFalse(AccountId.isValid(String(repeating: "a", count: 63) + "é"))
    }

    func testValidateThrowsForInvalidId() {
        XCTAssertNoThrow(try AccountId.validate("alice.near"))
        XCTAssertThrowsError(try AccountId.validate("Alice")) { error in
            XCTAssertEqual(error as? AccountIdError, .invalid("Alice"))
        }
        XCTAssertTrue(AccountId.isImplicit("0x1234567890abcdef1234567890abcdef12345678"))
        XCTAssertFalse(AccountId.isImplicit("0s1234567890abcdef1234567890abcdef12345678"))
        XCTAssertFalse(AccountId.isImplicit("alice.near"))
    }

    func testStrictBase58RejectsWhatHsCryptoKitDecodesToNothing() {
        XCTAssertEqual(Base58.decode("abc0"), Data())
        XCTAssertThrowsError(try Base58.strictDecode("abc0"))
        XCTAssertEqual(try Base58.strictDecode(""), Data())
        XCTAssertThrowsError(try Base58.strictDecode("1112", count: 32)) { error in
            XCTAssertEqual(error as? CodecError, .invalidLength(expected: 32, actual: 4))
        }
    }

    func testParsesPublicKeyString() throws {
        let key = try PublicKey(string: "ed25519:6j4b6zUaty6fD1awqcGCCU9JYGCWYUgdJhQrzfZhqE25")
        XCTAssertEqual(key.implicitAccountId, "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412")
        XCTAssertEqual(key.description, "ed25519:6j4b6zUaty6fD1awqcGCCU9JYGCWYUgdJhQrzfZhqE25")
        XCTAssertEqual(try PublicKey(string: "6j4b6zUaty6fD1awqcGCCU9JYGCWYUgdJhQrzfZhqE25"), key)
        XCTAssertThrowsError(try PublicKey(string: "secp256k1:6j4b6zUaty6fD1awqcGCCU9JYGCWYUgdJhQrzfZhqE25"))
        XCTAssertThrowsError(try PublicKey(string: "ed25519:0OIl"))
        XCTAssertThrowsError(try PublicKey(data: Data(count: 31)))
    }
}
