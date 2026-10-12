import Foundation
@testable import NearKit
import XCTest

/// File layout of the kit's databases: one per account under a wallet, the legacy per-wallet file
/// dropped on open, and `clear` by wallet (Android `NearDatabaseManagerTest`).
final class KitDatabaseTests: XCTestCase {
    private let walletId = UUID().uuidString
    private let otherWalletId = UUID().uuidString
    private let implicit = String(repeating: "a", count: 64)
    private let named = "alice.near"

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try KitDatabase.directoryUrl()
    }

    override func tearDownWithError() throws {
        try KitDatabase.clear(exceptFor: [])
    }

    private func touch(_ baseName: String, suffixes: [String] = [".sqlite", ".sqlite-wal", ".sqlite-shm"]) {
        for suffix in suffixes {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(baseName + suffix).path, contents: Data())
        }
    }

    private func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
    }

    func testEachAccountOfAWalletGetsItsOwnFile() throws {
        _ = try KitDatabase.pool(network: .mainNet, walletId: walletId, accountId: implicit)
        _ = try KitDatabase.pool(network: .mainNet, walletId: walletId, accountId: named)

        XCTAssertTrue(exists("main-mainNet-\(walletId)-\(implicit).sqlite"))
        XCTAssertTrue(exists("main-mainNet-\(walletId)-\(named).sqlite"))
    }

    // the database named before the account id was added is dropped and rebuilt from the network
    func testOpeningDropsTheLegacyWalletFile() throws {
        touch("main-mainNet-\(walletId)")

        _ = try KitDatabase.pool(network: .mainNet, walletId: walletId, accountId: named)

        XCTAssertFalse(exists("main-mainNet-\(walletId).sqlite"))
        XCTAssertFalse(exists("main-mainNet-\(walletId).sqlite-wal"))
        XCTAssertFalse(exists("main-mainNet-\(walletId).sqlite-shm"))
    }

    // a named account has dots in it: its files belong to its wallet, not cut at the first dot
    func testClearKeepsEveryAccountOfAKeptWallet() throws {
        touch("main-mainNet-\(walletId)-\(implicit)")
        touch("main-mainNet-\(walletId)-\(named)")
        touch("main-testNet-\(walletId)-\(named)")

        try KitDatabase.clear(exceptFor: [walletId])

        XCTAssertTrue(exists("main-mainNet-\(walletId)-\(implicit).sqlite"))
        XCTAssertTrue(exists("main-mainNet-\(walletId)-\(named).sqlite"))
        XCTAssertTrue(exists("main-mainNet-\(walletId)-\(named).sqlite-wal"))
        XCTAssertTrue(exists("main-testNet-\(walletId)-\(named).sqlite-shm"))
    }

    func testClearRemovesEveryAccountOfARemovedWallet() throws {
        touch("main-mainNet-\(walletId)-\(named)")
        touch("main-mainNet-\(otherWalletId)-\(named)")
        touch("main-testNet-\(otherWalletId)-\(implicit)")
        touch("main-mainNet-\(otherWalletId)")

        try KitDatabase.clear(exceptFor: [walletId])

        XCTAssertTrue(exists("main-mainNet-\(walletId)-\(named).sqlite"))
        XCTAssertFalse(exists("main-mainNet-\(otherWalletId)-\(named).sqlite"))
        XCTAssertFalse(exists("main-mainNet-\(otherWalletId)-\(named).sqlite-wal"))
        XCTAssertFalse(exists("main-testNet-\(otherWalletId)-\(implicit).sqlite-shm"))
        XCTAssertFalse(exists("main-mainNet-\(otherWalletId).sqlite"))
    }
}
