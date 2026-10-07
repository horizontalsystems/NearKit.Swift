import Foundation

/// A NEP-413 off-chain message (https://github.com/near/NEPs/blob/master/neps/nep-0413.md), the
/// payload of WalletConnect `near_signMessage`. The signed value is SHA-256 of the Borsh encoding
/// behind a 2^31 + 413 tag, which no transaction encoding can start with, so a signed message can
/// never be replayed as a signed transaction.
public struct MessagePayload: Equatable {
    /// 2^31 + 413: too large for the u32 length of a transaction's leading signer id.
    public static let tag: UInt32 = 2_147_484_061
    public static let nonceSize = 32

    public let message: String
    /// 32 bytes chosen by the dApp, so the signature cannot be replayed.
    public let nonce: Data
    /// Who the message is for, e.g. the dApp's domain or contract id.
    public let recipient: String
    public let callbackUrl: String?

    public init(message: String, nonce: Data, recipient: String, callbackUrl: String? = nil) throws {
        guard nonce.count == Self.nonceSize else {
            throw CodecError.invalidLength(expected: Self.nonceSize, actual: nonce.count)
        }
        self.message = message
        self.nonce = nonce
        self.recipient = recipient
        self.callbackUrl = callbackUrl
    }

    public func encode() throws -> Data {
        var writer = BorshWriter()
        writer.u32(Self.tag)
        try writer.string(message)
        writer.fixedBytes(nonce)
        try writer.string(recipient)
        try writer.option(callbackUrl) { try $0.string($1) }
        return writer.data
    }

    public func hash() throws -> Data {
        try Hashes.sha256(encode())
    }
}

/// A NEP-413 signature, in the shape `near_signMessage` returns.
public struct SignedMessage: Equatable {
    public let accountId: String
    public let publicKey: PublicKey
    public let signature: Data

    public init(accountId: String, publicKey: PublicKey, signature: Data) {
        self.accountId = accountId
        self.publicKey = publicKey
        self.signature = signature
    }

    public var signatureBase64: String {
        signature.base64EncodedString()
    }
}
