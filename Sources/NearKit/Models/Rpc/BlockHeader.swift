import BigInt
import Foundation

/// The header of `block` with `finality: final`.
struct BlockHeader {
    let height: Int
    let hash: String
    /// Nanoseconds since the Unix epoch.
    let timestampNanos: UInt64
    let gasPrice: BigUInt
}
