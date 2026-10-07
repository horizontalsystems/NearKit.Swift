import Foundation

public enum Network: String, CaseIterable {
    case mainNet
    case testNet

    public var id: Int {
        switch self {
        case .mainNet: return 0
        case .testNet: return 1
        }
    }

    public var isMainNet: Bool {
        self == .mainNet
    }

    /// `chain_id` as reported by `status`; `near:<networkId>` is the chain id WalletConnect uses.
    public var networkId: String {
        switch self {
        case .mainNet: return "mainnet"
        case .testNet: return "testnet"
        }
    }

    /// Default JSON-RPC endpoints in failover order, the same list as the Android kit.
    /// rpc.*.near.org are rate-limited legacy endpoints, kept last.
    public var rpcUrls: [URL] {
        switch self {
        case .mainNet:
            return [
                URL(string: "https://free.rpc.fastnear.com/")!,
                URL(string: "https://near.drpc.org/")!,
                URL(string: "https://rpc.shitzuapes.xyz/")!,
                URL(string: "https://rpc.mainnet.near.org/")!,
            ]
        case .testNet:
            return [
                URL(string: "https://rpc.testnet.fastnear.com/")!,
                URL(string: "https://rpc.testnet.near.org/")!,
            ]
        }
    }

    /// FastNEAR REST API: token balances and key-to-account lookup.
    public var apiUrl: URL {
        switch self {
        case .mainNet: return URL(string: "https://api.fastnear.com/")!
        case .testNet: return URL(string: "https://test.api.fastnear.com/")!
        }
    }

    /// FastNEAR Transactions API: indexed account history (the RPC has none).
    public var txApiUrl: URL {
        switch self {
        case .mainNet: return URL(string: "https://tx.main.fastnear.com/")!
        case .testNet: return URL(string: "https://tx.test.fastnear.com/")!
        }
    }

    public var explorerUrl: String {
        switch self {
        case .mainNet: return "https://nearblocks.io"
        case .testNet: return "https://testnet.nearblocks.io"
        }
    }

    public func transactionUrl(hash: String) -> String {
        "\(explorerUrl)/txns/\(hash)"
    }

    public func accountUrl(accountId: String) -> String {
        "\(explorerUrl)/address/\(accountId)"
    }
}
