import Alamofire
import Foundation
import HsToolKit

/// One HTTP call to a FastNEAR REST endpoint. Abstracted so parsing and the API key header are
/// testable without the network.
protocol IIndexerTransport {
    func get(url: URL, headers: [String: String]) async throws -> Any
    func post(url: URL, body: RpcJson, headers: [String: String]) async throws -> Any
}

final class NetworkManagerIndexerTransport: IIndexerTransport {
    private let networkManager: NetworkManager

    init(networkManager: NetworkManager) {
        self.networkManager = networkManager
    }

    func get(url: URL, headers: [String: String]) async throws -> Any {
        try await networkManager.fetchJson(url: url, method: .get, headers: HTTPHeaders(headers), responseCacherBehavior: .doNotCache)
    }

    func post(url: URL, body: RpcJson, headers: [String: String]) async throws -> Any {
        try await networkManager.fetchJson(url: url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: HTTPHeaders(headers), responseCacherBehavior: .doNotCache)
    }
}

/// FastNEAR indexer APIs. They fill the gaps of the NEAR RPC, which has no per-account history and
/// no token list: https://docs.fastnear.com. Results are indexer data, not consensus state, so the
/// kit uses them for discovery and history and reads balances that move money from the RPC.
///
/// The optional API key goes as `Authorization: Bearer` (`FastNearAuth`), and is dropped when FastNEAR rejects it.
/// Nothing here is logged: the URLs carry the account id or the public key.
final class FastNearProvider {
    static let pageLimit = 200
    static let maxHashesPerRequest = 20

    private let apiUrl: URL
    private let txApiUrl: URL
    private let transport: IIndexerTransport
    private let auth: FastNearAuth

    init(apiUrl: URL, txApiUrl: URL, auth: FastNearAuth, transport: IIndexerTransport) {
        self.apiUrl = apiUrl
        self.txApiUrl = txApiUrl
        self.auth = auth
        self.transport = transport
    }

    convenience init(apiUrl: URL, txApiUrl: URL, apiKey: String?, transport: IIndexerTransport) {
        self.init(apiUrl: apiUrl, txApiUrl: txApiUrl, auth: FastNearAuth(apiKey: apiKey), transport: transport)
    }

    convenience init(network: Network, auth: FastNearAuth, networkManager: NetworkManager) {
        self.init(apiUrl: network.apiUrl, txApiUrl: network.txApiUrl, auth: auth, transport: NetworkManagerIndexerTransport(networkManager: networkManager))
    }

    convenience init(network: Network, apiKey: String?, networkManager: NetworkManager) {
        self.init(network: network, auth: FastNearAuth(apiKey: apiKey), networkManager: networkManager)
    }

    // every index URL is a FastNEAR service, so the key goes with each request
    private func get(url: URL) async throws -> Any {
        try await auth.perform(headers: auth.headers) { [transport] headers in try await transport.get(url: url, headers: headers) }
    }

    private func post(url: URL, body: RpcJson) async throws -> Any {
        try await auth.perform(headers: auth.headers) { [transport] headers in try await transport.post(url: url, body: body, headers: headers) }
    }
}

extension FastNearProvider: IIndexerProvider {
    func ftBalances(accountId: String) async throws -> [FtBalanceInfo] {
        let json = try await get(url: apiUrl.appendingPathComponent("v1/account/\(accountId)/ft"))
        guard let tokens = (json as? RpcJson)?.array("tokens") else {
            throw InvalidResponse("ft: missing tokens")
        }
        return tokens.compactMap { element in
            guard let token = element as? RpcJson, let contractId = token.lenientString("contract_id"),
                  // the indexer reports an empty balance for contracts it could not read
                  let balance = token.lenientBigUInt("balance")
            else {
                return nil
            }
            return FtBalanceInfo(contractId: contractId, balance: balance)
        }
    }

    func accountIds(publicKey: String) async throws -> [String] {
        let json = try await get(url: apiUrl.appendingPathComponent("v0/public_key/\(publicKey)"))
        guard let ids = (json as? RpcJson)?.array("account_ids") else {
            throw InvalidResponse("public_key: missing account_ids")
        }
        return ids.compactMap { RpcJson.lenientString($0) }
    }

    func accountTransactions(accountId: String, fromBlockHeight: Int?, newestFirst: Bool, resumeToken: String?, limit: Int) async throws -> AccountTxPage {
        var body: RpcJson = ["account_id": accountId, "desc": newestFirst, "limit": limit]
        if let fromBlockHeight {
            body["from_tx_block_height"] = fromBlockHeight
        }
        if let resumeToken {
            body["resume_token"] = resumeToken
        }

        let json = try await post(url: txApiUrl.appendingPathComponent("v0/account"), body: body)
        guard let result = json as? RpcJson, let rows = result.array("account_txs") else {
            throw InvalidResponse("account: missing account_txs")
        }

        return AccountTxPage(
            rows: rows.compactMap { element in
                guard let row = element as? RpcJson, let hash = row.lenientString("transaction_hash"), let height = row.lenientInt("tx_block_height") else {
                    return nil
                }
                return AccountTxRow(hash: hash, blockHeight: height, blockTimestampNanos: row.lenientUInt64("tx_block_timestamp") ?? 0)
            },
            // the API returns a token even on the last page; an empty page ends the walk
            resumeToken: rows.isEmpty ? nil : result.lenientString("resume_token"),
            totalCount: result.lenientInt("txs_count")
        )
    }

    func transactions(hashes: [String]) async throws -> [RpcJson] {
        precondition(hashes.count <= Self.maxHashesPerRequest, "At most \(Self.maxHashesPerRequest) hashes per request")
        guard !hashes.isEmpty else {
            return []
        }
        let json = try await post(url: txApiUrl.appendingPathComponent("v0/transactions"), body: ["tx_hashes": hashes])
        guard let list = (json as? RpcJson)?.array("transactions") else {
            throw InvalidResponse("transactions: missing transactions")
        }
        return list.compactMap { $0 as? RpcJson }
    }
}
