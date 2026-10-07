import BigInt
import Foundation

/// `query` `view_account`.
struct AccountView {
    static let emptyCodeHash = "11111111111111111111111111111111"

    /// Liquid balance in yoctoNEAR.
    let amount: BigUInt
    /// Balance locked by validator staking (not by delegation to a pool).
    let locked: BigUInt
    let storageUsage: UInt64
    let codeHash: String
    let blockHeight: Int

    var hasContract: Bool {
        codeHash != Self.emptyCodeHash
    }
}
