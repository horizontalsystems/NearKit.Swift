import BigInt
import Foundation

public struct FeeEstimate: Equatable {
    public let gas: UInt64
    /// yoctoNEAR the sender ends up paying: gas burnt at the current gas price plus the account
    /// creation charge. For function calls it assumes all attached gas is used, unless the
    /// estimate was given the gas a call is expected to use.
    public let fee: BigUInt
    /// yoctoNEAR (besides deposits) the account must hold for the node to accept the transaction.
    /// Use it to compute the maximum sendable amount.
    public let requiredBalance: BigUInt

    public init(gas: UInt64, fee: BigUInt, requiredBalance: BigUInt) {
        self.gas = gas
        self.fee = fee
        self.requiredBalance = requiredBalance
    }
}
