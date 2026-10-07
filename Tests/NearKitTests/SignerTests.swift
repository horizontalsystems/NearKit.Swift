import BigInt
import CryptoKit
import HdWalletKit
import HsCryptoKit
import HsExtensions
@testable import NearKit
import XCTest

/// Vectors in near-js-vectors.json come from near-seed-phrase 0.2 (the derivation MyNearWallet and
/// near-cli use), @near-js/transactions 2.5.1 and, for NEP-413 messages, @near-js/signers 2.5.1.
/// CryptoKit Ed25519 signatures are randomized, so signatures are checked with `isValidSignature`
/// instead of byte for byte; the signed hashes and unsigned bytes must match exactly.
final class SignerTests: XCTestCase {
    private var vectors: [String: Any]!

    override func setUpWithError() throws {
        vectors = try Fixtures.json("near-js-vectors")
    }

    private func keys() throws -> [[String: Any]] {
        try Fixtures.objects(vectors, "keys")
    }

    private func verify(signature: Data, of message: Data, by publicKey: PublicKey) throws -> Bool {
        try Curve25519.Signing.PublicKey(rawRepresentation: publicKey.data).isValidSignature(signature, for: message)
    }

    func testDerivesTheSameKeysAsNearSeedPhrase() throws {
        for v in try keys() {
            let words = try v.text("mnemonic").split(separator: " ").map(String.init)
            let seed = try XCTUnwrap(Mnemonic.seed(mnemonic: words))
            let signer = try Signer.instance(seed: seed)

            XCTAssertEqual(signer.publicKey.description, try v.text("publicKey"))
            XCTAssertEqual(signer.publicKey.implicitAccountId, try v.text("implicitAccount"))
            XCTAssertEqual(try Signer.address(seed: seed), try v.text("implicitAccount"))

            // the secret key string is base58(private key ‖ public key)
            let secretKey = try Base58.strictDecode(String(v.text("secretKey").dropFirst(PublicKey.prefix.count)), count: 64)
            XCTAssertEqual(try Signer.privateKey(seed: seed) + signer.publicKey.data, secretKey)
        }
    }

    func testImportsSecretKeyString() throws {
        let v = try keys()[1]
        let signer = try Signer.instance(secretKey: v.text("secretKey"))
        XCTAssertEqual(signer.publicKey.description, try v.text("publicKey"))
    }

    func testRejectsSecretKeyWithForeignPublicKey() throws {
        let keys = try keys()
        let a = try Base58.strictDecode(String(keys[0].text("secretKey").dropFirst(PublicKey.prefix.count)))
        let b = try Signer.instance(secretKey: keys[1].text("secretKey"))
        let mixed = Base58.encode(a.prefix(32) + b.publicKey.data)

        XCTAssertThrowsError(try Signer.instance(secretKey: "ed25519:\(mixed)")) { error in
            guard case .invalidSecretKey(.publicKeyMismatch) = error as? Signer.SignError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testKeyWithLeadingZeroByteStays32Bytes() throws {
        let key = try XCTUnwrap(("00ff" + String(repeating: "11", count: 30)).hs.hexData)
        let signer = try Signer.instance(privateKey: key)

        // base58 keeps the leading zero byte as a leading "1"
        let imported = try Signer.instance(secretKey: "ed25519:" + Base58.encode(key))
        XCTAssertEqual(imported.publicKey, signer.publicKey)
        XCTAssertEqual(signer.publicKey.data.count, 32)

        for v in try keys() {
            let words = try v.text("mnemonic").split(separator: " ").map(String.init)
            XCTAssertEqual(try Signer.privateKey(seed: XCTUnwrap(Mnemonic.seed(mnemonic: words))).count, 32)
        }
    }

    func testTransferMatchesNearJs() throws {
        try assertVector("transfer", actions: [
            .transfer(deposit: BigUInt("1500000000000000000000000")),
        ])
    }

    func testFtTransferWithStorageDepositMatchesNearJs() throws {
        try assertVector("ft_transfer_with_storage", actions: [
            .functionCall(
                methodName: "storage_deposit",
                args: Data(#"{"account_id":"bob.near","registration_only":true}"#.utf8),
                gas: 30_000_000_000_000,
                deposit: BigUInt("1250000000000000000000")
            ),
            .functionCall(
                methodName: "ft_transfer",
                args: Data(#"{"receiver_id":"bob.near","amount":"1000000"}"#.utf8),
                gas: 30_000_000_000_000,
                deposit: 1
            ),
        ])
    }

    func testDecodesSignedTransactionBackToTheSameBytes() throws {
        for v in try Fixtures.objects(vectors, "txs") {
            let bytes = try XCTUnwrap(Data(base64Encoded: v.text("signedTxBase64")))
            let decoded = try SignedTransaction.decode(bytes)

            XCTAssertEqual(decoded.encode(), bytes)
            XCTAssertEqual(decoded.hash, try v.text("hash"))
            XCTAssertEqual(decoded.transaction.receiverId, try v.text("receiverId"))
        }
    }

    func testSignsNep413MessagesLikeNearJs() throws {
        let signer = try Signer.instance(secretKey: keys()[0].text("secretKey"))

        for v in try Fixtures.objects(vectors, "nep413") {
            let payload = try MessagePayload(
                message: v.text("message"),
                nonce: XCTUnwrap(v.text("nonceHex").hs.hexData),
                recipient: v.text("recipient"),
                callbackUrl: v["callbackUrl"] as? String
            )
            XCTAssertEqual(signer.publicKey.description, try v.text("publicKey"))

            let nearJsSignature = try XCTUnwrap(Data(base64Encoded: v.text("signatureBase64")))
            XCTAssertTrue(try verify(signature: nearJsSignature, of: payload.hash(), by: signer.publicKey), "near-js signature does not verify over our payload hash")
            XCTAssertTrue(try verify(signature: signer.sign(payload), of: payload.hash(), by: signer.publicKey))
        }
    }

    func testNep413PayloadStartsWithTagNoTransactionCanHave() throws {
        let payload = try MessagePayload(message: "hi", nonce: Data(count: 32), recipient: "app.near")
        // 2^31 + 413, little-endian: as a transaction's signer id length it would be over 2 GB
        XCTAssertEqual(try payload.encode().prefix(4).hs.hex, "9d010080")
    }

    func testRejectsTransactionOfAnotherKey() throws {
        let keys = try keys()
        let signer = try Signer.instance(secretKey: keys[0].text("secretKey"))
        let other = try PublicKey(string: keys[1].text("publicKey"))
        let tx = try NearTransaction(signerId: "alice.near", publicKey: other, nonce: 1, receiverId: "bob.near", blockHash: Data(count: 32), actions: [.transfer(deposit: 1)])

        XCTAssertThrowsError(try signer.sign(tx)) { error in
            guard case .publicKeyMismatch = error as? Signer.SignError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testRejectsMalformedSecretKeys() throws {
        let cases: [(String, Signer.SecretKeyError)] = [
            ("secp256k1:abc", .unsupportedScheme),
            ("ed25519:0OIl", .invalidBase58),
            ("ed25519:" + Base58.encode(Data(repeating: 7, count: 33)), .invalidLength(33)),
        ]
        for (secretKey, expected) in cases {
            XCTAssertThrowsError(try Signer.instance(secretKey: secretKey)) { error in
                guard case let .invalidSecretKey(reason) = error as? Signer.SignError else {
                    return XCTFail("unexpected \(error)")
                }
                XCTAssertEqual(reason, expected, secretKey)
            }
        }
    }

    private func assertVector(_ name: String, actions: [Action]) throws {
        let v = try XCTUnwrap(Fixtures.objects(vectors, "txs").first { $0["name"] as? String == name })
        let signer = try Signer.instance(secretKey: keys()[0].text("secretKey"))
        let tx = try NearTransaction(
            signerId: v.text("signerId"),
            publicKey: PublicKey(string: v.text("publicKey")),
            nonce: XCTUnwrap(UInt64(v.text("nonce"))),
            receiverId: v.text("receiverId"),
            blockHash: Base58.strictDecode(v.text("blockHash"), count: 32),
            actions: actions
        )
        XCTAssertEqual(tx.encode().hs.hex, try v.text("txHex"))
        XCTAssertEqual(tx.hashString(), try v.text("hash"))

        let nearJsSignature = try XCTUnwrap(v.text("signatureHex").hs.hexData)
        XCTAssertTrue(try verify(signature: nearJsSignature, of: tx.hash(), by: signer.publicKey), "near-js signature does not verify over our hash")
        XCTAssertEqual(try SignedTransaction(transaction: tx, signature: nearJsSignature).base64, try v.text("signedTxBase64"))

        let signed = try signer.sign(tx)
        XCTAssertTrue(try verify(signature: signed.signature, of: tx.hash(), by: signer.publicKey))
        XCTAssertEqual(try SignedTransaction.decode(signed.encode()), signed)
        XCTAssertEqual(try NearTransaction.decode(tx.encode()).encode().hs.hex, try v.text("txHex"))
    }
}
