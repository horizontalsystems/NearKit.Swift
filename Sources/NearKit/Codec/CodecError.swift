import Foundation

public enum CodecError: Error, Equatable {
    case unexpectedEnd
    /// A length prefix larger than the bytes left, which bounds a hostile prefix before allocating.
    case lengthExceedsData
    case invalidOptionTag(UInt8)
    case unsupportedKeyType(UInt8)
    /// A key string with a scheme other than `ed25519:`.
    case unsupportedKeyScheme
    case invalidAccessKeyPermission(UInt8)
    /// Delegate (8), DeployGlobalContract (9), UseGlobalContract (10) and later variants are not supported.
    case unsupportedAction(UInt8)
    /// A `TransactionV1`, which starts with the byte 1 where a V0 transaction has its signer id length.
    case unsupportedTransactionVersion
    case trailingBytes
    case invalidUtf8
    /// A number that does not fit the field's fixed width. The codec rejects rather than truncates.
    case outOfRange
    case invalidBase58
    case invalidLength(expected: Int, actual: Int)
}
