import Foundation
import HsCryptoKit

/// An unsigned NEAR transaction (the V0 layout, which every node accepts).
public struct NearTransaction: Equatable {
    public static let blockHashSize = 32

    public let signerId: String
    public let publicKey: PublicKey
    public let nonce: UInt64
    public let receiverId: String
    public let blockHash: Data
    public let actions: [Action]
    private var encoded = Data()

    /// Throws when the transaction cannot be encoded, e.g. a deposit above u128.
    public init(signerId: String, publicKey: PublicKey, nonce: UInt64, receiverId: String, blockHash: Data, actions: [Action]) throws {
        guard blockHash.count == Self.blockHashSize else {
            throw CodecError.invalidLength(expected: Self.blockHashSize, actual: blockHash.count)
        }
        self.signerId = signerId
        self.publicKey = publicKey
        self.nonce = nonce
        self.receiverId = receiverId
        self.blockHash = blockHash
        self.actions = actions

        var writer = BorshWriter()
        try write(to: &writer)
        encoded = writer.data
    }

    public func encode() -> Data {
        encoded
    }

    /// SHA-256 of the Borsh encoding: the value that is signed and, base58-encoded, the tx hash.
    public func hash() -> Data {
        Hashes.sha256(encoded)
    }

    public func hashString() -> String {
        Base58.encode(hash())
    }

    private func write(to writer: inout BorshWriter) throws {
        try writer.string(signerId)
        writer.publicKey(publicKey)
        writer.u64(nonce)
        try writer.string(receiverId)
        writer.fixedBytes(blockHash)
        try writer.vec(actions) { try $1.write(to: &$0) }
    }

    /// Decodes a Borsh-encoded V0 transaction. Throws on trailing bytes or unknown variants.
    public static func decode(_ data: Data) throws -> NearTransaction {
        var reader = BorshReader(data)
        let transaction = try read(from: &reader)
        try reader.finish()
        return transaction
    }

    static func read(from reader: inout BorshReader) throws -> NearTransaction {
        // nearcore reads a leading 1 as the V1 tag; as a V0 signer id length it would be below the 2-character minimum
        guard try reader.peekU8() != 1 else {
            throw CodecError.unsupportedTransactionVersion
        }
        return try NearTransaction(
            signerId: reader.string(),
            publicKey: reader.publicKey(),
            nonce: reader.u64(),
            receiverId: reader.string(),
            blockHash: reader.fixedBytes(blockHashSize),
            actions: reader.vec { try Action.read(from: &$0) }
        )
    }
}

/// A transaction with its Ed25519 signature, ready for `send_tx`.
public struct SignedTransaction: Equatable {
    public static let signatureSize = 64

    public let transaction: NearTransaction
    public let signature: Data

    public init(transaction: NearTransaction, signature: Data) throws {
        guard signature.count == Self.signatureSize else {
            throw CodecError.invalidLength(expected: Self.signatureSize, actual: signature.count)
        }
        self.transaction = transaction
        self.signature = signature
    }

    public var hash: String {
        transaction.hashString()
    }

    public func encode() -> Data {
        var writer = BorshWriter()
        writer.fixedBytes(transaction.encode())
        writer.u8(keyTypeEd25519)
        writer.fixedBytes(signature)
        return writer.data
    }

    public var base64: String {
        encode().base64EncodedString()
    }

    public static func decode(_ data: Data) throws -> SignedTransaction {
        var reader = BorshReader(data)
        let transaction = try NearTransaction.read(from: &reader)
        let keyType = try reader.u8()
        guard keyType == keyTypeEd25519 else {
            throw CodecError.unsupportedKeyType(keyType)
        }
        let signature = try reader.fixedBytes(signatureSize)
        try reader.finish()
        return try SignedTransaction(transaction: transaction, signature: signature)
    }
}

let keyTypeEd25519: UInt8 = 0

extension BorshWriter {
    mutating func publicKey(_ key: PublicKey) {
        u8(keyTypeEd25519)
        fixedBytes(key.data)
    }
}

extension BorshReader {
    mutating func publicKey() throws -> PublicKey {
        let keyType = try u8()
        guard keyType == keyTypeEd25519 else {
            throw CodecError.unsupportedKeyType(keyType)
        }
        return try PublicKey(data: fixedBytes(PublicKey.size))
    }
}
