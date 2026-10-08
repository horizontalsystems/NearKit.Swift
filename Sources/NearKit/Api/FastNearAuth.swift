import Foundation
import HsToolKit

/// The FastNEAR API key, shared by the index and the RPC transport (Android `FastNearAuth`). The
/// RPC, API and transactions services accept the same key; it goes to FastNEAR hosts only, so it
/// never reaches a third-party RPC in the failover list.
///
/// FastNEAR answers 401/403 to a revoked or expired key even where the keyless tier would serve the
/// request. A rejected key is dropped for the rest of the process and the request repeated without
/// it, so a lapsed subscription degrades to keyless rate limits instead of stopping sync.
final class FastNearAuth {
    private let apiKey: String?
    private let logger: Logger?
    private let lock = NSLock()
    private var rejected = false

    init(apiKey: String?, logger: Logger? = nil) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = trimmed?.isEmpty == false ? trimmed : nil
        self.logger = logger
    }

    /// The key header for a FastNEAR service, or none once the key was rejected.
    var headers: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let apiKey, !rejected else {
            return [:]
        }
        return ["Authorization": "Bearer \(apiKey)"]
    }

    /// The key header for `url` when it is a FastNEAR host; for RPC endpoints of any provider.
    func headers(url: URL) -> [String: String] {
        Self.isFastNearHost(url.host) ? headers : [:]
    }

    /// Runs `request` with `headers`; when they carried the key and FastNEAR refused it, drops the
    /// key and runs `request` once more without it.
    func perform<T>(headers: [String: String], _ request: ([String: String]) async throws -> T) async throws -> T {
        guard !headers.isEmpty else {
            return try await request(headers)
        }
        do {
            return try await request(headers)
        } catch let error as NetworkManager.ResponseError where error.statusCode == 401 || error.statusCode == 403 {
            reject(statusCode: error.statusCode)
            return try await request([:])
        }
    }

    private func reject(statusCode: Int?) {
        lock.lock()
        let first = !rejected
        rejected = true
        lock.unlock()

        if first {
            logger?.warning("FastNEAR rejected the API key (HTTP \(statusCode.map { "\($0)" } ?? "?")); continuing without it")
        }
    }

    static func isFastNearHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        return host == "fastnear.com" || host.hasSuffix(".fastnear.com")
    }
}
