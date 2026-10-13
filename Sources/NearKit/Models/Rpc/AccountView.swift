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
    /// A NEP-591 global contract the account uses, by code hash or by the deploying account. Its
    /// `codeHash` is then the empty one, so these are what tell such an account has code.
    let globalContractHash: String?
    let globalContractAccountId: String?
    let blockHeight: Int

    var hasContract: Bool {
        codeHash != Self.emptyCodeHash || globalContractHash != nil || globalContractAccountId != nil
    }
}
