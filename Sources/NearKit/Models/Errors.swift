import BigInt
import Foundation

/// nearcore returned a structured error. `name` is the cause name (UNKNOWN_ACCOUNT,
/// INVALID_TRANSACTION, TIMEOUT_ERROR…) or, without a cause, the top-level error name.
/// `data` is the error payload as JSON text, e.g. `{"TxExecutionError":{"InvalidTxError":"Expired"}}`.
public struct RpcError: Error, Equatable {
    public let name: String
    public let data: String?
    public let message: String?

    public init(name: String, data: String?, message: String?) {
        self.name = name
        self.data = data
        self.message = message
    }
}

public extension RpcError {
    static let unknownAccount = "UNKNOWN_ACCOUNT"
    static let unknownAccessKey = "UNKNOWN_ACCESS_KEY"
    static let unknownTransaction = "UNKNOWN_TRANSACTION"
    static let invalidTransaction = "INVALID_TRANSACTION"

    /// Errors about the request itself, which every node would repeat. Anything else, including an
    /// unnamed error, a lagging node (UNKNOWN_BLOCK) or a node-side fault, is worth asking the next
    /// node: a wrong guess there costs one extra call, while the opposite wrong guess lets one bad
    /// node block every sync.
    private static let deterministicNames: Set<String> = [
        "UNKNOWN_ACCOUNT",
        "UNKNOWN_ACCESS_KEY",
        "INVALID_ACCOUNT",
        "INVALID_TRANSACTION",
        "UNKNOWN_TRANSACTION",
        "PARSE_ERROR",
        "REQUEST_VALIDATION_ERROR",
        "NO_CONTRACT_CODE",
        "CONTRACT_EXECUTION_ERROR",
    ]

    /// True when every node would answer this way, so failing over could only repeat it.
    var isDeterministic: Bool {
        Self.deterministicNames.contains(name)
    }
}

/// A response did not have the shape the kit expects. Treated as untrusted input.
public struct InvalidResponse: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Every endpoint failed, or the last one returned an unusable response.
public struct NoEndpointAvailable: Error {
    public let underlying: Error?

    public init(underlying: Error?) {
        self.underlying = underlying
    }
}

public enum AccountIdError: Error, Equatable {
    case invalid(String)
}

public enum SendError: Error, Equatable {
    /// The account does not exist yet, or the signer's key is not one of its access keys.
    case accessKeyNotFound
    /// Function-call keys cannot attach deposits or call arbitrary contracts.
    case notFullAccessKey
    /// Transfers to a named account that does not exist fail on chain and are refused up front.
    case receiverNotFound(String)
    /// The node refused the transaction; `details` is the error data, e.g.
    /// `{"TxExecutionError":{"InvalidTxError":{"NotEnoughBalance":…}}}`.
    case rejected(details: String)
    /// The token contract asks for more than `FtActions.maxStorageDeposit` to register the receiver.
    case storageDepositTooHigh(BigUInt)
    /// The storage deposit the token contract asks for is not the one the user confirmed.
    case storageDepositChanged(confirmed: BigUInt?, required: BigUInt?)
    /// The signer's key is not the one the transaction or the kit's account is for.
    case signerMismatch
    case invalidAmount
    case noActions
}

// User-facing descriptions, worded as the Android kit's exception messages.

extension RpcError: LocalizedError {
    public var errorDescription: String? {
        message.map { "\(name): \($0)" } ?? name
    }
}

extension InvalidResponse: LocalizedError {
    public var errorDescription: String? {
        message
    }
}

extension NoEndpointAvailable: LocalizedError {
    public var errorDescription: String? {
        "No NEAR endpoint responded"
    }
}

extension AccountIdError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalid(accountId): return "Invalid NEAR account id: \(accountId)"
        }
    }
}

extension SendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accessKeyNotFound: return "Access key not found on the account"
        case .notFullAccessKey: return "Access key is not a full-access key"
        case let .receiverNotFound(receiverId): return "Account \(receiverId) does not exist"
        case let .rejected(details): return details
        case let .storageDepositTooHigh(deposit): return "Token storage deposit \(deposit) yoctoNEAR exceeds the limit"
        case let .storageDepositChanged(confirmed, required): return "Token storage deposit changed from \(confirmed.map(\.description) ?? "null") to \(required.map(\.description) ?? "null") yoctoNEAR"
        case .signerMismatch: return "Signer does not match the kit account"
        case .invalidAmount: return "Amount must be positive"
        case .noActions: return "No actions"
        }
    }
}
