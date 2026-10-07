import CryptoKit
import Foundation
import HdWalletKit
import HsCryptoKit

/// Ed25519 signer. The private key is the 32-byte Ed25519 seed; NEAR's "secret key" string is that
/// seed followed by the public key, base58-encoded with an `ed25519:` prefix.
///
/// The public key comes from `Curve25519.Signing`: `Crypto.publicKey(privateKey:curve: .ed25519)`
/// (and `HDPrivateKey.publicKey(curve:)` behind it) builds an X25519 key, not an Ed25519 one.
public class Signer {
    private let signingKey: Curve25519.Signing.PrivateKey

    public let publicKey: PublicKey

    init(privateKey: Data) throws {
        guard privateKey.count == 32, let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw SignError.invalidPrivateKey
        }
        self.signingKey = signingKey
        publicKey = try PublicKey(data: signingKey.publicKey.rawRepresentation)
    }

    /// Signs SHA-256 of the transaction's Borsh encoding, as nearcore verifies it.
    func sign(_ transaction: NearTransaction) throws -> SignedTransaction {
        guard transaction.publicKey == publicKey else {
            throw SignError.publicKeyMismatch
        }
        return try SignedTransaction(transaction: transaction, signature: sign(data: transaction.hash()))
    }

    /// Signs a NEP-413 message (`near_signMessage`).
    func sign(_ payload: MessagePayload) throws -> Data {
        try sign(data: payload.hash())
    }

    /// Private on purpose: signing caller-chosen bytes would sign a transaction for anyone who
    /// passes its hash. Everything signed goes through a typed, domain-separated payload.
    private func sign(data: Data) throws -> Data {
        do {
            return try Data(signingKey.signature(for: data))
        } catch {
            throw SignError.signingFailed(underlying: error)
        }
    }
}

public extension Signer {
    static let coinType: UInt32 = 397

    /// SLIP-10 Ed25519 at m/44'/397'/0', the path near-seed-phrase (MyNearWallet, near-cli) and
    /// Trust Wallet use, so the same words give the same account everywhere. Ledger uses
    /// 44'/397'/0'/0'/1' and is a different key.
    static let derivationPath = "m/44'/397'/0'"

    static func instance(seed: Data) throws -> Signer {
        try Signer(privateKey: privateKey(seed: seed))
    }

    /// Parses `ed25519:<base58>` holding either the 64-byte secret key or the 32-byte seed.
    static func instance(secretKey: String) throws -> Signer {
        let trimmed = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix(PublicKey.prefix) ? String(trimmed.dropFirst(PublicKey.prefix.count)) : trimmed
        guard !body.contains(":") else {
            throw SignError.invalidSecretKey(.unsupportedScheme)
        }
        guard let bytes = try? Base58.strictDecode(body) else {
            throw SignError.invalidSecretKey(.invalidBase58)
        }

        switch bytes.count {
        case 32:
            return try Signer(privateKey: bytes)
        case 64:
            let signer = try Signer(privateKey: bytes.prefix(32))
            guard signer.publicKey.data == bytes.suffix(32) else {
                throw SignError.invalidSecretKey(.publicKeyMismatch)
            }
            return signer
        default:
            throw SignError.invalidSecretKey(.invalidLength(bytes.count))
        }
    }

    static func instance(privateKey: Data) throws -> Signer {
        try Signer(privateKey: privateKey)
    }

    static func publicKey(seed: Data) throws -> PublicKey {
        try instance(seed: seed).publicKey
    }

    /// The implicit account id of the seed's key.
    static func address(seed: Data) throws -> String {
        try publicKey(seed: seed).implicitAccountId
    }

    internal static func privateKey(seed: Data) throws -> Data {
        do {
            let hdWallet = HDWallet(seed: seed, coinType: coinType, xPrivKey: 0, curve: .ed25519)
            return try hdWallet.privateKey(account: 0).raw
        } catch {
            throw SignError.invalidSeed(underlying: error)
        }
    }
}

public extension Signer {
    enum SignError: Error {
        case invalidSeed(underlying: Error)
        case invalidPrivateKey
        case invalidSecretKey(SecretKeyError)
        /// The transaction names a different public key than the signer's.
        case publicKeyMismatch
        case signingFailed(underlying: Error)
    }

    enum SecretKeyError: Error, Equatable {
        case unsupportedScheme
        case invalidBase58
        case invalidLength(Int)
        /// A 64-byte secret key whose second half is not the public key of its first half.
        case publicKeyMismatch
    }
}
