import BigInt
@testable import NearKit
import XCTest

/// Fee and max through the kit, with the runtime config a mainnet node returns (protocol version 86)
/// and the block gas price below the purchase minimum, as it usually is: gas is bought at 10^9.
final class KitFeeTests: XCTestCase {
    private static let gasPrice: BigUInt = 100_000_000
    private static let oneNear = BigUInt(10).power(24)
    private static let implicit = String(repeating: "a", count: 64)

    // receipt 216.119 + transfer 230.246125 Ggas
    private static let namedGas: BigUInt = 446_365_125_000
    // plus creating the implicit account (7.7 Tgas) and its full-access key (203.53025 Ggas)
    private static let implicitGas: BigUInt = 8_349_895_375_000
    private static let creationCharge = BigUInt(7) * BigUInt(10).power(21)

    private var near: FakeNear!
    private var kit: Kit!

    override func setUpWithError() throws {
        near = try FakeNear()
        // 1 NEAR, storage under the zero-balance limit: all of it available
        try near.mainStorage.save(accountState: AccountState(exists: true, amount: Self.oneNear, locked: 0, storageUsage: 182, hasContract: false))
        try near.mainStorage.save(chainState: ChainState(blockHeight: 1000, gasPrice: Self.gasPrice))
        kit = try near.kit(accountId: "alice.near")
    }

    override func tearDown() {
        near.assertNoUnexpectedRequests()
        super.tearDown()
    }

    private func answerProtocolConfig() throws {
        try near.rpc.answer("EXPERIMENTAL_protocol_config", .result(Fixtures.json("protocol-config-mainnet-p86")))
    }

    func testNamedReceiver() async throws {
        try answerProtocolConfig()

        let estimate = try await kit.estimateNearTransfer(receiverId: "bob.near")
        let max = try await kit.maxSendableNear(receiverId: "bob.near")

        XCTAssertEqual(estimate.fee, Self.namedGas * Self.gasPrice)
        XCTAssertEqual(estimate.requiredBalance, Self.namedGas * 1_000_000_000)
        XCTAssertEqual(max, Self.oneNear - Self.namedGas * 1_000_000_000)
        // a named account is never created by a transfer: nothing to look up
        XCTAssertTrue(near.rpc.calls("query.view_account").isEmpty)
    }

    func testExistingImplicitReceiverPaysCreationGasButNoCharge() async throws {
        try answerProtocolConfig()
        near.rpc.answer("query.view_account", .result(FakeNear.account()), .result(FakeNear.account()))

        let estimate = try await kit.estimateNearTransfer(receiverId: Self.implicit)
        let max = try await kit.maxSendableNear(receiverId: Self.implicit)

        XCTAssertEqual(estimate.fee, Self.implicitGas * Self.gasPrice)
        XCTAssertEqual(estimate.requiredBalance, Self.implicitGas * 1_000_000_000)
        XCTAssertEqual(max, Self.oneNear - Self.implicitGas * 1_000_000_000)
    }

    // 0.015349895375 NEAR: creation gas at the purchase minimum plus the 0.007 NEAR charge
    func testNewImplicitReceiverAlsoPaysTheCreationCharge() async throws {
        try answerProtocolConfig()
        near.rpc.answer("query.view_account", .error(cause: "UNKNOWN_ACCOUNT"), .error(cause: "UNKNOWN_ACCOUNT"))

        let estimate = try await kit.estimateNearTransfer(receiverId: Self.implicit)
        let max = try await kit.maxSendableNear(receiverId: Self.implicit)

        XCTAssertEqual(estimate.fee, Self.implicitGas * Self.gasPrice + Self.creationCharge)
        XCTAssertEqual(estimate.requiredBalance, BigUInt("15349895375000000000000"))
        XCTAssertEqual(max, Self.oneNear - BigUInt("15349895375000000000000"))
    }

    func testMaxIsZeroWhenTheFeeTakesEverything() async throws {
        try near.mainStorage.save(accountState: AccountState(exists: true, amount: 1000, locked: 0, storageUsage: 182, hasContract: false))
        kit = try near.kit(accountId: "alice.near")
        try answerProtocolConfig()

        let max = try await kit.maxSendableNear(receiverId: "bob.near")

        XCTAssertEqual(max, 0)
    }

    // read once; while no node answers, the built-in values are used and the next estimate asks again
    func testProtocolConfigIsRetriedUntilLoadedThenKept() async throws {
        near.rpc.answer("EXPERIMENTAL_protocol_config", .failure(URLError(.timedOut)), .failure(URLError(.timedOut)))

        let offline = try await kit.estimateNearTransfer(receiverId: "bob.near")
        XCTAssertEqual(offline.requiredBalance, Self.namedGas * 1_000_000_000)

        try answerProtocolConfig()
        _ = try await kit.estimateNearTransfer(receiverId: "bob.near")
        _ = try await kit.estimateNearTransfer(receiverId: "bob.near")

        // two nodes tried on the first estimate, one answer on the second, none on the third
        XCTAssertEqual(near.rpc.calls("EXPERIMENTAL_protocol_config").count, 3)
    }
}
