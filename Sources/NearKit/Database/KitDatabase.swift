import Foundation
import GRDB

/// One SQLite file per (network, wallet, account): `Application Support/near-kit/main-<network>-<walletId>-<accountId>.sqlite`.
/// One walletId can open several accounts the same key controls (implicit and named), so the account
/// id is part of the name; otherwise their sync cursors and history would mix (Android `NearDatabaseManager`).
/// Both storages share the pool, as in XrpKit.
enum KitDatabase {
    private static let directoryName = "near-kit"
    private static let fileSuffixes = [".sqlite", ".sqlite-wal", ".sqlite-shm"]

    private static func prefix(network: Network, walletId: String) -> String {
        "main-\(network.rawValue)-\(walletId)"
    }

    static func fileName(network: Network, walletId: String, accountId: String) -> String {
        "\(prefix(network: network, walletId: walletId))-\(accountId)"
    }

    static func directoryUrl() throws -> URL {
        let fileManager = FileManager.default
        let url = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pool(network: Network, walletId: String, accountId: String) throws -> DatabasePool {
        let directory = try directoryUrl()
        // name used before the account id was added; its data is rebuilt from the network
        try remove(baseName: prefix(network: network, walletId: walletId), in: directory)

        let url = directory.appendingPathComponent("\(fileName(network: network, walletId: walletId, accountId: accountId)).sqlite")
        return try DatabasePool(path: url.path)
    }

    /// Removes the databases (`.sqlite`, `-wal`, `-shm`) of every account of every wallet not in `walletIds`, for both networks.
    static func clear(exceptFor walletIds: [String]) throws {
        let fileManager = FileManager.default
        let keptPrefixes = Network.allCases.flatMap { network in walletIds.map { prefix(network: network, walletId: $0) } }

        for fileUrl in try fileManager.contentsOfDirectory(at: try directoryUrl(), includingPropertiesForKeys: nil) {
            // an account id may contain dots, so the name is cut at the known suffix, not at the first dot
            guard let baseName = baseName(fileName: fileUrl.lastPathComponent), baseName.hasPrefix("main-") else {
                continue
            }
            let kept = keptPrefixes.contains { baseName == $0 || baseName.hasPrefix("\($0)-") }
            if !kept {
                try fileManager.removeItem(at: fileUrl)
            }
        }
    }

    private static func baseName(fileName: String) -> String? {
        fileSuffixes
            .first { fileName.hasSuffix($0) }
            .map { String(fileName.dropLast($0.count)) }
    }

    private static func remove(baseName: String, in directory: URL) throws {
        let fileManager = FileManager.default
        for suffix in fileSuffixes {
            let url = directory.appendingPathComponent(baseName + suffix)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }
}
