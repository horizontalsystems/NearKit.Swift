import BigInt
import Foundation

/// What a transaction costs, from the runtime fee config (`EXPERIMENTAL_protocol_config`).
///
/// Converting the transaction burns the "send" costs and executing its receipt the "execution"
/// costs; a function call also buys the gas attached to it. Gas is bought up front at no less
/// than `min_gas_purchase_price` and burnt at the block gas price, and the difference comes back
/// as a refund. So the balance a send needs is well above what it finally costs.
struct FeeCalculator {
    private let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    /// Total gas for `actions`. A transfer to a NEAR-implicit or ETH-implicit account always pays
    /// for creating the account and its key, because at conversion time the runtime cannot know
    /// whether the account exists.
    func gas(actions: [Action], receiverIsImplicit: Bool) -> BigUInt {
        gas(actions: actions, receiverIsImplicit: receiverIsImplicit, expectedCallGas: nil)
    }

    /// `createsAccount`: the receiver does not exist and a transfer will create it.
    /// `expectedCallGas`: gas each function call is expected to use, for the fee only. Unused
    /// attached gas is refunded, but the node still requires the balance to buy all of it.
    ///
    /// The account creation charge is added to both the fee and the required balance on top of
    /// the creation gas, as the Android kit does.
    func estimate(actions: [Action], receiverIsImplicit: Bool, createsAccount: Bool, gasPrice: BigUInt, expectedCallGas: UInt64? = nil) -> FeeEstimate {
        let totalGas = gas(actions: actions, receiverIsImplicit: receiverIsImplicit)
        let usedGas = gas(actions: actions, receiverIsImplicit: receiverIsImplicit, expectedCallGas: expectedCallGas)
        let charge: BigUInt = createsAccount ? config.accountCreationCharge : 0

        return FeeEstimate(
            gas: UInt64(clamping: totalGas),
            fee: usedGas * gasPrice + charge,
            requiredBalance: totalGas * Swift.max(gasPrice, config.minGasPurchasePrice) + charge
        )
    }

    private func gas(actions: [Action], receiverIsImplicit: Bool, expectedCallGas: UInt64?) -> BigUInt {
        var total = config.actionReceipt.total
        for action in actions {
            switch action {
            case .transfer:
                total += config.transfer.total
                if receiverIsImplicit {
                    total += config.createAccount.total + config.addFullAccessKey.total
                }
            case let .functionCall(methodName, args, callGas, _):
                let bytes = BigUInt(methodName.utf8.count + args.count)
                let usedCallGas = expectedCallGas.map { Swift.min(callGas, $0) } ?? callGas
                total += config.functionCall.total + config.functionCallPerByte.total * bytes + BigUInt(usedCallGas)
            default:
                total += config.otherAction.total
            }
        }
        return total
    }
}

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

extension FeeCalculator {
    /// Gas of one item: burnt on conversion (`send`, at the not-sender-is-receiver price) and on execution.
    struct Cost: Equatable {
        let send: UInt64
        let execution: UInt64

        var total: BigUInt {
            BigUInt(send) + BigUInt(execution)
        }
    }

    struct Config: Equatable {
        let actionReceipt: Cost
        let transfer: Cost
        let createAccount: Cost
        let addFullAccessKey: Cost
        let functionCall: Cost
        let functionCallPerByte: Cost
        /// Every other action is small next to the receipt cost; this bounds them.
        let otherAction: Cost
        /// yoctoNEAR charged when a transfer creates an account.
        let accountCreationCharge: BigUInt
        /// yoctoNEAR per gas at which gas is bought, whatever the block gas price.
        let minGasPurchasePrice: BigUInt

        /// Mainnet values, protocol version 86 (September 2026).
        static let `default` = Config(
            actionReceipt: Cost(send: 108_059_500_000, execution: 108_059_500_000),
            transfer: Cost(send: 115_123_062_500, execution: 115_123_062_500),
            createAccount: Cost(send: 500_000_000_000, execution: 7_200_000_000_000),
            addFullAccessKey: Cost(send: 101_765_125_000, execution: 101_765_125_000),
            functionCall: Cost(send: 200_000_000_000, execution: 780_000_000_000),
            functionCallPerByte: Cost(send: 47_683_715, execution: 2_235_934),
            otherAction: Cost(send: 200_000_000_000, execution: 200_000_000_000),
            accountCreationCharge: BigUInt(7) * BigUInt(10).power(21),
            minGasPurchasePrice: 1_000_000_000
        )

        /// Reads the config from `EXPERIMENTAL_protocol_config`; nil when the shape is unexpected.
        static func from(protocolConfig: RpcJson) -> Config? {
            guard let runtime = protocolConfig.object("runtime_config"),
                  let transactionCosts = runtime.object("transaction_costs"),
                  let actionCosts = transactionCosts.object("action_creation_config"),
                  let actionReceipt = cost(transactionCosts.object("action_receipt_creation_config")),
                  let transfer = cost(actionCosts.object("transfer_cost")),
                  let createAccount = cost(actionCosts.object("create_account_cost")),
                  let addFullAccessKey = cost(actionCosts.object("add_key_cost")?.object("full_access_cost")),
                  let functionCall = cost(actionCosts.object("function_call_cost")),
                  let functionCallPerByte = cost(actionCosts.object("function_call_cost_per_byte"))
            else {
                return nil
            }

            return Config(
                actionReceipt: actionReceipt,
                transfer: transfer,
                createAccount: createAccount,
                addFullAccessKey: addFullAccessKey,
                functionCall: functionCall,
                functionCallPerByte: functionCallPerByte,
                otherAction: Config.default.otherAction,
                // older protocol versions have neither field: no charge, and gas bought at the block price
                accountCreationCharge: lenientBigUInt(runtime["account_creation_charge"]) ?? 0,
                minGasPurchasePrice: lenientBigUInt(runtime["min_gas_purchase_price"]) ?? 0
            )
        }

        private static func cost(_ json: RpcJson?) -> Cost? {
            guard let json, let send = lenientUInt64(json["send_not_sir"]), let execution = lenientUInt64(json["execution"]) else {
                return nil
            }
            return Cost(send: send, execution: execution)
        }

        // Read like the Android kit's Gson helpers: a number or a numeric string.

        private static func lenientUInt64(_ raw: Any?) -> UInt64? {
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                return UInt64(exactly: number)
            }
            return (raw as? String).flatMap { UInt64($0) }
        }

        private static func lenientBigUInt(_ raw: Any?) -> BigUInt? {
            let string: String?
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                string = number.stringValue
            } else {
                string = raw as? String
            }
            guard let string, !string.isEmpty, string.allSatisfy(\.isASCIIDigit) else {
                return nil
            }
            return BigUInt(string)
        }
    }
}
