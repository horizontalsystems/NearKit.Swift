import Foundation

/// `query` `view_access_key`.
struct AccessKeyView {
    let nonce: UInt64
    let isFullAccess: Bool
    /// Recent block hash from the same response; usable as the transaction's block hash.
    let blockHash: String
    let blockHeight: Int
}
