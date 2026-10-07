import Foundation
import HsCryptoKit
import HsExtensions

/// An Ed25519 public key, shown by NEAR as `ed25519:<base58>`. The kit does not handle secp256k1 keys.
public struct PublicKey: Equatable, Hashable {
    public static let prefix = "ed25519:"
    public static let size = 32

    public let data: Data

    public init(data: Data) throws {
        guard data.count == Self.size else {
            throw CodecError.invalidLength(expected: Self.size, actual: data.count)
        }
        self.data = data
    }

    /// Accepts `ed25519:<base58>` or bare base58.
    public init(string: String) throws {
        let body = string.hasPrefix(Self.prefix) ? String(string.dropFirst(Self.prefix.count)) : string
        guard !body.contains(":") else {
            throw CodecError.unsupportedKeyScheme
        }
        try self.init(data: Base58.strictDecode(body, count: Self.size))
    }

    /// The NEAR-implicit account id this key controls: the 64-character lowercase hex of the key.
    public var implicitAccountId: String {
        data.hs.hex
    }
}

extension PublicKey: CustomStringConvertible {
    public var description: String {
        Self.prefix + Base58.encode(data)
    }
}
