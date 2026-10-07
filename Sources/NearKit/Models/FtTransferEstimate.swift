import BigInt
import Foundation

public struct FtTransferEstimate: Equatable {
    /// Counts the gas a token call is expected to burn; the balance check covers all attached gas.
    public let fee: FeeEstimate
    /// yoctoNEAR paid to register the receiver with the token contract, or nil.
    public let storageDeposit: BigUInt?

    public init(fee: FeeEstimate, storageDeposit: BigUInt?) {
        self.fee = fee
        self.storageDeposit = storageDeposit
    }
}
