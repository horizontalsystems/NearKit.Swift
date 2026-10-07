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

    // 8.349895375 Tgas at the 10^9 minimum purchase price plus the 0.007 NEAR charge = 0.015349895375 NEAR
    func testWorstCaseTransferRequired() {
        XCTAssertEqual(Kit.worstCaseTransferRequired, BigUInt("15349895375000000000000"))
        // a block gas price below the purchase minimum does not move it
        let atUsualPrice = FeeCalculator().estimate(actions: [.transfer(deposit: 1)], receiverIsImplicit: true, createsAccount: true, gasPrice: gasPrice)
        XCTAssertEqual(atUsualPrice.requiredBalance, Kit.worstCaseTransferRequired)
    }

    func testReadsProtocolConfig() throws {
        func cost(_ send: UInt64, _ execution: UInt64) -> [String: Any] {
            ["send_sir": 1, "send_not_sir": send, "execution": execution]
        }
        var runtime: [String: Any] = [
            "account_creation_charge": "7000000000000000000000",
            "min_gas_purchase_price": "1000000000",
            "transaction_costs": [
                "action_receipt_creation_config": cost(108_059_500_000, 108_059_500_000),
                "action_creation_config": [
                    "transfer_cost": cost(115_123_062_500, 115_123_062_500),
                    "create_account_cost": cost(500_000_000_000, 7_200_000_000_000),
                    "add_key_cost": ["full_access_cost": cost(101_765_125_000, 101_765_125_000)],
                    "function_call_cost": cost(200_000_000_000, 780_000_000_000),
                    "function_call_cost_per_byte": cost(47_683_715, 2_235_934),
                ],
            ],
        ]
        XCTAssertEqual(FeeCalculator.Config.from(protocolConfig: ["runtime_config": runtime]), FeeCalculator.Config.default)

        runtime["account_creation_charge"] = nil
        runtime["min_gas_purchase_price"] = nil
        let older = try XCTUnwrap(FeeCalculator.Config.from(protocolConfig: ["runtime_config": runtime]))
        XCTAssertEqual(older.accountCreationCharge, 0)
        XCTAssertEqual(older.minGasPurchasePrice, 0)

        runtime["transaction_costs"] = ["action_creation_config": [:]]
        XCTAssertNil(FeeCalculator.Config.from(protocolConfig: ["runtime_config": runtime]))
        XCTAssertNil(FeeCalculator.Config.from(protocolConfig: [:]))
    }

    func testHostileAttachedGasDoesNotOverflow() {
        let actions: [Action] = [.functionCall(methodName: "m", args: Data(), gas: .max, deposit: 0), .functionCall(methodName: "m", args: Data(), gas: .max, deposit: 0)]
        let e = FeeCalculator().estimate(actions: actions, receiverIsImplicit: false, createsAccount: false, gasPrice: gasPrice)
        XCTAssertEqual(e.gas, .max)
        XCTAssertGreaterThan(e.requiredBalance, BigUInt(UInt64.max) * 2 * 1_000_000_000)
    }
}
