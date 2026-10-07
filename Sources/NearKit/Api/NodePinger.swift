import Foundation

public struct NodePingResult: Equatable {
    /// Latency thresholds for UI coloring, the same as XrpKit and the Monero kit.
    public static let pingGood: TimeInterval = 0.333
    public static let pingMedium: TimeInterval = 0.667

    public let url: URL
    /// Wall-clock time of one `status` round-trip; nil = unreachable.
    public let responseTime: TimeInterval?
    /// The node's latest block height. 0 when unreachable or unparseable.
    public let height: UInt64
    /// Reachable, answered `status` as a synced node of the expected network.
    public let isValid: Bool

    public var isReachable: Bool {
        responseTime != nil
    }
}

/// Measures response time and latest block of NEAR RPC nodes with a single `status` call per
/// node. Static and independent of any Kit instance (XrpKit `NodePinger`).
public enum NodePinger {
    public static func ping(urls: [URL], network: Network, timeout: TimeInterval = 5) async -> [NodePingResult] {
        await withTaskGroup(of: (Int, NodePingResult).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    await (index, ping(url: url, network: network, timeout: timeout))
                }
            }

            var results = [NodePingResult?](repeating: nil, count: urls.count)
            for await (index, result) in group {
                results[index] = result
            }

            return results.compactMap { $0 }
        }
    }

    public static func ping(url: URL, network: Network, timeout: TimeInterval = 5) async -> NodePingResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: StatusJsonRpc().body)
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        // Monotonic clock: wall-clock Date() would corrupt a sample if NTP steps the clock
        let start = DispatchTime.now()

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

            guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else {
                return NodePingResult(url: url, responseTime: elapsed, height: 0, isValid: false)
            }

            return result(url: url, responseTime: elapsed, jsonObject: json, network: network)
        } catch {
            return NodePingResult(url: url, responseTime: nil, height: 0, isValid: false)
        }
    }

    /// Pure classification of a `status` response, separated so it can be pinned by tests.
    static func result(url: URL, responseTime: TimeInterval, jsonObject: Any, network: Network) -> NodePingResult {
        let rpc = StatusJsonRpc()
        guard let status = try? rpc.parse(result: JsonRpcResponse.result(method: rpc.method, jsonObject: jsonObject)) else {
            return NodePingResult(url: url, responseTime: responseTime, height: 0, isValid: false)
        }

        let isValid = status.latestBlockHeight > 0 && !status.syncing && status.chainId == network.networkId
        return NodePingResult(url: url, responseTime: responseTime, height: status.latestBlockHeight, isValid: isValid)
    }
}
