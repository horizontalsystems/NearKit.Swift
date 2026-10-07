import BigInt
import Foundation

/// NEP-141 transfer building (https://nomicon.io/Standards/Tokens/FungibleToken/Core) with NEP-145 storage registration.
enum FtActions {
    /// Gas attached to token calls; the NEP-141 reference contracts need well under this.
    static let gas: UInt64 = 30_000_000_000_000

    /// Gas a token call is expected to burn, for the fee shown before sending. USDC burns about
    /// 2.4 Tgas for `ft_transfer` and less for `storage_deposit`; this leaves room for heavier
    /// contracts while staying far below `gas`.
    static let expectedGas: UInt64 = 5_000_000_000_000

    /// The most yoctoNEAR (0.1 NEAR) the kit attaches as a storage deposit. Real tokens ask for
    /// 0.00125 to about 0.0125 NEAR; the amount comes from the token contract (or the RPC node), so
    /// a scam token could otherwise ask for the whole balance.
    static let maxStorageDeposit = BigUInt(10).power(23)

    /// NEAR `accountId` still has to deposit with the token contract to hold it, or nil when registered.
    static func storageDepositRequired(rpcApiProvider: RpcApiProvider, contractId: String, accountId: String) async throws -> BigUInt? {
        let balance = try await rpcApiProvider.callFunctionJson(contractId: contractId, methodName: "storage_balance_of", argsJson: accountIdArgs(accountId))
        guard balance is NSNull else {
            return nil
        }
        guard let bounds = try await rpcApiProvider.callFunctionJson(contractId: contractId, methodName: "storage_balance_bounds") as? RpcJson else {
            throw InvalidResponse("storage_balance_bounds: not an object")
        }
        guard let text = RpcJson.lenientString(bounds["min"]), let min = BigInt(text, radix: 10) else {
            throw InvalidResponse("storage_balance_bounds: missing min")
        }
        return try checkStorageDeposit(min)
    }

    /// `storage_balance_bounds.min` as the contract reported it, checked against `maxStorageDeposit`.
    static func checkStorageDeposit(_ deposit: BigInt) throws -> BigUInt {
        guard deposit.sign == .plus || deposit.isZero else {
            throw InvalidResponse("storage_balance_bounds: negative min")
        }
        let deposit = deposit.magnitude
        guard deposit <= maxStorageDeposit else {
            throw SendError.storageDepositTooHigh(deposit)
        }
        return deposit
    }

    /// `storage_deposit` for `receiverId` when `storageDeposit` is set, then `ft_transfer`. Sent to the token contract.
    static func transfer(receiverId: String, amount: BigUInt, memo: String?, storageDeposit: BigUInt?) throws -> [Action] {
        try AccountId.validate(receiverId)
        var actions = [Action]()

        if let storageDeposit {
            let args = JsonObjectWriter()
                .add("account_id", string: receiverId)
                .add("registration_only", bool: true)
                .text
            actions.append(.functionCall(methodName: "storage_deposit", args: Data(args.utf8), gas: gas, deposit: storageDeposit))
        }

        var args = JsonObjectWriter()
            .add("receiver_id", string: receiverId)
            .add("amount", string: amount.description)
        if let memo {
            args = args.add("memo", string: memo)
        }
        // NEP-141 requires exactly one yoctoNEAR on ft_transfer, as proof of a full-access key
        actions.append(.functionCall(methodName: "ft_transfer", args: Data(args.text.utf8), gas: gas, deposit: 1))
        return actions
    }

    static func accountIdArgs(_ accountId: String) throws -> String {
        try AccountId.validate(accountId)
        return JsonObjectWriter().add("account_id", string: accountId).text
    }
}

/// Builds a flat JSON object in insertion order, escaping strings as Gson does, so the call
/// arguments match the Android kit byte for byte. `JSONEncoder` neither keeps key order nor
/// leaves `/` unescaped.
struct JsonObjectWriter {
    private var members = [String]()

    var text: String {
        "{" + members.joined(separator: ",") + "}"
    }

    func add(_ key: String, string value: String) -> JsonObjectWriter {
        appending(key, Self.quote(value))
    }

    func add(_ key: String, bool value: Bool) -> JsonObjectWriter {
        appending(key, value ? "true" : "false")
    }

    private func appending(_ key: String, _ value: String) -> JsonObjectWriter {
        var writer = self
        writer.members.append(Self.quote(key) + ":" + value)
        return writer
    }

    static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\t": result += "\\t"
            case "\u{8}": result += "\\b"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\u{C}": result += "\\f"
            case "\u{2028}", "\u{2029}": result += String(format: "\\u%04x", scalar.value)
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
