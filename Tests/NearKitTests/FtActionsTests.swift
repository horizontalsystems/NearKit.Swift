import BigInt
@testable import NearKit
import XCTest

final class FtActionsTests: XCTestCase {
    func testAcceptsUsualStorageDeposits() throws {
        let usual = BigInt("1250000000000000000000") // 0.00125 NEAR
        XCTAssertEqual(try FtActions.checkStorageDeposit(usual), usual.magnitude)
        XCTAssertEqual(try FtActions.checkStorageDeposit(0), 0)
        XCTAssertEqual(try FtActions.checkStorageDeposit(BigInt(FtActions.maxStorageDeposit)), FtActions.maxStorageDeposit)
    }

    func testRejectsStorageDepositAboveLimit() {
        XCTAssertThrowsError(try FtActions.checkStorageDeposit(BigInt(FtActions.maxStorageDeposit) + 1)) { error in
            XCTAssertEqual(error as? SendError, .storageDepositTooHigh(FtActions.maxStorageDeposit + 1))
        }

        // a scam token asking for 500 NEAR
        XCTAssertThrowsError(try FtActions.checkStorageDeposit(BigInt(10).power(24) * 500)) { error in
            XCTAssertEqual(error as? SendError, .storageDepositTooHigh(BigUInt(10).power(24) * 500))
        }
    }

    func testRejectsNegativeStorageDeposit() {
        XCTAssertThrowsError(try FtActions.checkStorageDeposit(-1)) { error in
            XCTAssertTrue(error is InvalidResponse)
        }
    }

    func testFeeCountsExpectedGasButBalanceCoversAttachedGas() throws {
        let gasPrice: BigUInt = 100_000_000
        let calculator = FeeCalculator()
        func estimate(_ storageDeposit: BigUInt?, _ expectedCallGas: UInt64?) throws -> FeeEstimate {
            try calculator.estimate(
                actions: FtActions.transfer(receiverId: "bob.near", amount: 10, memo: nil, storageDeposit: storageDeposit),
                receiverIsImplicit: false,
                createsAccount: false,
                gasPrice: gasPrice,
                expectedCallGas: expectedCallGas
            )
        }
        let near = BigUInt(10).power(24)

        // yoctoNEAR mainnet USDC actually charged, 2026-09-28
        for (storageDeposit, charged) in [
            (nil, BigUInt("270000000000000000000")),
            (BigUInt("1250000000000000000000"), BigUInt("477000000000000000000")),
        ] as [(BigUInt?, BigUInt)] {
            let full = try estimate(storageDeposit, nil)
            let expected = try estimate(storageDeposit, FtActions.expectedGas)

            XCTAssertEqual(full.requiredBalance, expected.requiredBalance)
            XCTAssertEqual(full.gas, expected.gas)
            // above what was charged, and within a few times of it instead of over ten
            XCTAssertGreaterThan(expected.fee, charged)
            XCTAssertLessThan(expected.fee, charged * 3)
            XCTAssertGreaterThan(full.fee, charged * 10)
            XCTAssertLessThan(expected.fee, near)
        }
    }

    // iOS additions

    func testBuildsArgumentsInAndroidKeyOrder() throws {
        let actions = try FtActions.transfer(receiverId: "bob.near", amount: 1_000_000, memo: "a/b", storageDeposit: 5)
        XCTAssertEqual(actions, [
            .functionCall(methodName: "storage_deposit", args: Data(#"{"account_id":"bob.near","registration_only":true}"#.utf8), gas: FtActions.gas, deposit: 5),
            .functionCall(methodName: "ft_transfer", args: Data(#"{"receiver_id":"bob.near","amount":"1000000","memo":"a/b"}"#.utf8), gas: FtActions.gas, deposit: 1),
        ])
        XCTAssertEqual(try FtActions.accountIdArgs("bob.near"), #"{"account_id":"bob.near"}"#)
        XCTAssertThrowsError(try FtActions.transfer(receiverId: "Bob", amount: 1, memo: nil, storageDeposit: nil))
    }

    func testEscapesMemoLikeGson() throws {
        let actions = try FtActions.transfer(receiverId: "bob.near", amount: 1, memo: "x\",\"receiver_id\":\"evil\\\u{0}\u{1F}\t\n\r\u{8}\u{C}\u{2028}\u{2029}é", storageDeposit: nil)
        guard case let .functionCall(_, args, _, _) = try XCTUnwrap(actions.first) else {
            return XCTFail("not a function call")
        }
        XCTAssertEqual(
            String(decoding: args, as: UTF8.self),
            #"{"receiver_id":"bob.near","amount":"1","memo":"x\",\"receiver_id\":\"evil\\\u0000\u001f\t\n\r\b\f"# + "\\u2028\\u2029" + #"é"}"#
        )
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: args) as? [String: String])
        XCTAssertEqual(parsed["receiver_id"], "bob.near")
    }
}
