import BigInt
import Foundation

/// A token balance as the FastNEAR index reports it.
struct FtBalanceInfo: Equatable {
    let contractId: String
    let balance: BigUInt
}

/// One row of the FastNEAR account history.
struct AccountTxRow: Equatable {
    let hash: String
    let blockHeight: Int
    /// Nanoseconds since the Unix epoch.
    let blockTimestampNanos: UInt64
}

struct AccountTxPage {
    let rows: [AccountTxRow]
    let resumeToken: String?
    let totalCount: Int?
}
