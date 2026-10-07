import Foundation
import GRDB

/// One SQLite file per (network, wallet): `Application Support/near-kit/main-<network>-<walletId>.sqlite`.
/// Both storages share the pool, as in XrpKit.
enum KitDatabase {
    private static let directoryName = "near-kit"

    static func fileName(network: Network, walletId: String) -> String {
        "main-\(network.rawValue)-\(walletId)"
    }

    static func directoryUrl() throws -> URL {
        let fileManager = FileManager.default
        let url = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pool(network: Network, walletId: String) throws -> DatabasePool {
        let url = try directoryUrl().appendingPathComponent("\(fileName(network: network, walletId: walletId)).sqlite")
        return try DatabasePool(path: url.path)
    }

    /// Removes the databases (`.sqlite`, `-wal`, `-shm`) of every wallet not in `walletIds`, for both networks.
    static func clear(exceptFor walletIds: [String]) throws {
        let fileManager = FileManager.default
        let directory = try directoryUrl()
        let keep = Set(Network.allCases.flatMap { network in walletIds.map { fileName(network: network, walletId: $0) } })

        for fileUrl in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let baseName = fileUrl.lastPathComponent.components(separatedBy: ".").first ?? ""
            guard baseName.hasPrefix("main-"), !keep.contains(baseName) else {
                continue
            }
            try fileManager.removeItem(at: fileUrl)
        }
    }
}
