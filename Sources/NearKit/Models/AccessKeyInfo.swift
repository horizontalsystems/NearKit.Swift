import Foundation

/// A key on an account (`view_access_key_list`). `publicKey` is as the node reports it
/// (`ed25519:…` or `secp256k1:…`); a key without full access can only call the methods it was
/// granted.
public struct AccessKeyInfo: Equatable {
    public let publicKey: String
    public let isFullAccess: Bool

    public init(publicKey: String, isFullAccess: Bool) {
        self.publicKey = publicKey
        self.isFullAccess = isFullAccess
    }
}
