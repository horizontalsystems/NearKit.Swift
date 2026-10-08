import Alamofire
import Foundation
import HsToolKit

/// One HTTP POST of a JSON-RPC body to one endpoint. Abstracted so the provider's failover policy
/// is testable without the network. A nil `timeout` keeps the session's request timeout.
protocol IRpcTransport {
    func post(url: URL, body: RpcJson, timeout: TimeInterval?) async throws -> Any
}

final class NetworkManagerRpcTransport: IRpcTransport {
    private let networkManager: NetworkManager
    private let auth: FastNearAuth?

    init(networkManager: NetworkManager, auth: FastNearAuth? = nil) {
        self.networkManager = networkManager
        self.auth = auth
    }

    // FastNEAR's own RPC nodes take the API key; other providers in the list never see it
    func post(url: URL, body: RpcJson, timeout: TimeInterval?) async throws -> Any {
        guard let auth else {
            return try await post(url: url, body: body, timeout: timeout, headers: [:])
        }
        return try await auth.perform(headers: auth.headers(url: url)) { headers in
            try await post(url: url, body: body, timeout: timeout, headers: headers)
        }
    }

    private func post(url: URL, body: RpcJson, timeout: TimeInterval?, headers: [String: String]) async throws -> Any {
        try await networkManager.fetchJson(
            url: url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers.isEmpty ? nil : HTTPHeaders(headers),
            responseCacherBehavior: .doNotCache, timeout: timeout
        )
    }
}

/// nearcore JSON-RPC client with endpoint failover. An error about the request itself (unknown
/// account, invalid transaction: `RpcError.isDeterministic`) is thrown to the caller without
/// failover, because every node would answer the same. Anything else - an unnamed or node-side
/// error, a lagging node, an HTTP or transport failure, a malformed response - moves to the next
/// URL. The node that answered stays preferred for later calls, as in the Android kit.
final class RpcApiProvider {
    private static let passes = 2
    private static let dnsRetryDelay: TimeInterval = 1.5

    private let transport: IRpcTransport
    private let logger: Logger?

    private let lock = NSLock()
    private var _urls: [URL]
    private var _preferredIndex = 0
    /// Bumped by `set(urls:)`, so a call that started on the old list does not move the index of the new one.
    private var generation = 0

    init(urls: [URL], transport: IRpcTransport, logger: Logger? = nil) {
        precondition(!urls.isEmpty, "At least one RPC URL is required")
        _urls = urls
        self.transport = transport
        self.logger = logger
    }

    convenience init(urls: [URL], networkManager: NetworkManager, auth: FastNearAuth? = nil, logger: Logger? = nil) {
        self.init(urls: urls, transport: NetworkManagerRpcTransport(networkManager: networkManager, auth: auth), logger: logger)
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _urls
    }

    var preferredIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return _preferredIndex
    }

    /// Host of the node calls start from: the one that answered last, after a failover.
    var source: String {
        let (urls, start, _) = snapshot()
        return urls[start].host ?? "unknown"
    }

    /// Replaces the endpoint list and starts again from its first URL. Calls already running finish
    /// on the list they started with.
    func set(urls: [URL]) throws {
        guard !urls.isEmpty else {
            throw NoEndpointAvailable(underlying: nil)
        }
        lock.lock()
        _urls = urls
        _preferredIndex = 0
        generation += 1
        lock.unlock()
    }

    private func snapshot() -> (urls: [URL], start: Int, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_urls, _preferredIndex, generation)
    }

    private func prefer(index: Int, generation: Int) {
        lock.lock()
        if generation == self.generation {
            _preferredIndex = index
        }
        lock.unlock()
    }

    func fetch<T>(rpc: JsonRpc<T>) async throws -> T {
        var lastError: Error?

        for pass in 0 ..< Self.passes {
            if pass > 0 {
                // Every host failed to resolve: the device's network is not up yet (typical right
                // after the app resumes). Give it a moment instead of failing the whole sync.
                guard let lastError, NetworkErrors.isDnsFailure(lastError) else {
                    break
                }
                try await Task.sleep(nanoseconds: UInt64(Self.dnsRetryDelay * 1_000_000_000))
            }

            let (urls, start, generation) = snapshot()
            for attempt in urls.indices {
                try Task.checkCancellation()
                let index = (start + attempt) % urls.count
                do {
                    let json = try await transport.post(url: urls[index], body: rpc.body, timeout: rpc.timeout)
                    let result = try rpc.parse(result: JsonRpcResponse.result(method: rpc.method, jsonObject: json))
                    prefer(index: index, generation: generation)
                    return result
                } catch let error as RpcError where error.isDeterministic {
                    throw error
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    // method and host only: parameters may carry a signed transaction or an account
                    logger?.error("\(rpc.method) failed on \(urls[index].host ?? "?"): \(error)")
                    lastError = error
                }
            }
        }

        throw NoEndpointAvailable(underlying: lastError)
    }
}

// MARK: - nearcore methods

extension RpcApiProvider {
    /// Nil when the account does not exist (never funded, or deleted).
    func viewAccount(accountId: String) async throws -> AccountView? {
        do {
            return try await fetch(rpc: ViewAccountJsonRpc(accountId: accountId))
        } catch let error as RpcError where error.name == RpcError.unknownAccount {
            return nil
        }
    }

    /// Nil when the key is not on the account, or the account does not exist.
    func viewAccessKey(accountId: String, publicKey: String) async throws -> AccessKeyView? {
        do {
            return try await fetch(rpc: ViewAccessKeyJsonRpc(accountId: accountId, publicKey: publicKey))
        } catch let error as RpcError where error.name == RpcError.unknownAccessKey || error.name == RpcError.unknownAccount {
            return nil
        }
    }

    func callFunction(contractId: String, methodName: String, argsJson: String = "{}") async throws -> Data {
        try await fetch(rpc: CallFunctionJsonRpc(contractId: contractId, methodName: methodName, argsJson: argsJson))
    }

    /// The view method's return value parsed as JSON: an object, an array, a string, a number or `NSNull`.
    func callFunctionJson(contractId: String, methodName: String, argsJson: String = "{}") async throws -> Any {
        let bytes = try await callFunction(contractId: contractId, methodName: methodName, argsJson: argsJson)
        guard let json = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed) else {
            throw InvalidResponse("\(contractId).\(methodName) returned non-JSON")
        }
        return json
    }

    func latestBlock() async throws -> BlockHeader {
        try await fetch(rpc: BlockJsonRpc())
    }

    func protocolConfig() async throws -> RpcJson {
        try await fetch(rpc: ProtocolConfigJsonRpc())
    }

    func sendTransaction(signedTxBase64: String, waitUntil: String = "INCLUDED") async throws -> TxStatus {
        try await fetch(rpc: SendTxJsonRpc(signedTxBase64: signedTxBase64, waitUntil: waitUntil))
    }

    /// Nil when no node knows the transaction (not yet seen, or dropped).
    func transactionStatus(hash: String, senderAccountId: String) async throws -> TxStatus? {
        do {
            return try await fetch(rpc: TxStatusJsonRpc(hash: hash, senderAccountId: senderAccountId))
        } catch let error as RpcError where error.name == RpcError.unknownTransaction {
            return nil
        }
    }
}
