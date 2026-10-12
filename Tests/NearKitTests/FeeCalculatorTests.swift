import BigInt
@testable import NearKit
import XCTest

final class FeeCalculatorTests: XCTestCase {
    private let gasPrice: BigUInt = 100_000_000

    func testTransferToNamedAccount() {
        // 0.446 Tgas: burnt at the 10^8 gas price, bought at the 10^9 minimum purchase price
        let e = FeeCalculator().estimate(actions: [.transfer(deposit: 1)], receiverIsImplicit: false, createsAccount: false, gasPrice: gasPrice)
        XCTAssertEqual(e.gas, 446_365_125_000)
        XCTAssertEqual(e.fee, BigUInt("44636512500000000000"))
        XCTAssertEqual(e.requiredBalance, BigUInt("446365125000000000000"))
    }

    func testTransferToImplicitAccountPaysCreationGasEvenWhenItExists() {
        // mainnet tx BiuXnScW…: 0.8249 Tgas to convert + 7.5249 Tgas to execute
        let e = FeeCalculator().estimate(actions: [.transfer(deposit: 1)], receiverIsImplicit: true, createsAccount: false, gasPrice: gasPrice)
        XCTAssertEqual(e.gas, 824_947_687_500 + 7_524_947_687_500)
    }

    func testCreatingAnAccountAddsTheCharge() {
        let e = FeeCalculator().estimate(actions: [.transfer(deposit: 1)], receiverIsImplicit: true, createsAccount: true, gasPrice: gasPrice)
        XCTAssertEqual(e.fee, BigUInt("7000000000000000000000") + BigUInt(8_349_895_375_000) * gasPrice)
        // the charge is counted in the required balance as well, as on Android
        XCTAssertEqual(e.requiredBalance, BigUInt("7000000000000000000000") + BigUInt(8_349_895_375_000) * 1_000_000_000)
    }

    // iOS additions

    // a live mainnet answer (protocol version 86): what the node reports is what the kit has built in
    func testReadsLiveProtocolConfig() throws {
        let live = try Fixtures.json("protocol-config-mainnet-p86")

        XCTAssertEqual(FeeCalculator.Config.from(protocolConfig: live), FeeCalculator.Config.default)
    }

    func testOlderProtocolConfigHasNoChargeAndNoPurchaseMinimum() throws {
        var config = try Fixtures.json("protocol-config-mainnet-p86")
        var runtime = try XCTUnwrap(config["runtime_config"] as? [String: Any])
        runtime["account_creation_charge"] = nil
        runtime["min_gas_purchase_price"] = nil
        config["runtime_config"] = runtime

        let older = try XCTUnwrap(FeeCalculator.Config.from(protocolConfig: config))

        XCTAssertEqual(older.accountCreationCharge, 0)
        XCTAssertEqual(older.minGasPurchasePrice, 0)
    }

    func testUnexpectedProtocolConfigShapeIsRefused() throws {
        var config = try Fixtures.json("protocol-config-mainnet-p86")
        var runtime = try XCTUnwrap(config["runtime_config"] as? [String: Any])
        runtime["transaction_costs"] = ["action_creation_config": [String: Any]()]
        config["runtime_config"] = runtime

        XCTAssertNil(FeeCalculator.Config.from(protocolConfig: config))
        XCTAssertNil(FeeCalculator.Config.from(protocolConfig: [:]))
    }

    func testHostileAttachedGasDoesNotOverflow() {
        let actions: [Action] = [.functionCall(methodName: "m", args: Data(), gas: .max, deposit: 0), .functionCall(methodName: "m", args: Data(), gas: .max, deposit: 0)]
        let e = FeeCalculator().estimate(actions: actions, receiverIsImplicit: false, createsAccount: false, gasPrice: gasPrice)
        XCTAssertEqual(e.gas, .max)
        XCTAssertGreaterThan(e.requiredBalance, BigUInt(UInt64.max) * 2 * 1_000_000_000)
    }
}
