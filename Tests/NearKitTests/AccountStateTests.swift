import BigInt
@testable import NearKit
import XCTest

final class AccountStateTests: XCTestCase {
    private func state(_ amount: String, storage: UInt64, locked: String = "0") -> AccountState {
        AccountState(exists: true, amount: BigUInt(amount)!, locked: BigUInt(locked)!, storageUsage: storage, hasContract: false)
    }

    func testZeroBalanceAccountHasEverythingAvailable() {
        let s = state("1000", storage: 182)
        XCTAssertEqual(s.storageStaked, 0)
        XCTAssertEqual(s.available, 1000)
        XCTAssertEqual(state("1000", storage: 770).available, 1000)
    }

    func testAboveTheLimitTheWholeUsageIsStaked() {
        // 771 bytes × 10^19 = 0.00771 NEAR
        let s = state("10000000000000000000000", storage: 771)
        XCTAssertEqual(s.storageStaked, BigUInt("7710000000000000000000"))
        XCTAssertEqual(s.available, BigUInt("2290000000000000000000"))
    }

    func testLockedStakeCoversStorage() {
        let s = state("5", storage: 1000, locked: "20000000000000000000000")
        XCTAssertEqual(s.available, 5)
    }

    func testAvailableNeverNegative() {
        XCTAssertEqual(state("1", storage: 5000).available, 0)
    }

    func testNearAmountConversions() {
        XCTAssertEqual(NearAmount.toNear(yocto: BigUInt("1500000000000000000000000")), Decimal(string: "1.5"))
        XCTAssertEqual(NearAmount.toYocto(near: Decimal(string: "0.000000000000000000000001")!), 1)
        XCTAssertEqual(NearAmount.toNear(yocto: 0), 0)
        // more than 24 decimal places, or negative
        XCTAssertNil(NearAmount.toYocto(near: Decimal(string: "0.0000000000000000000000001")!))
        XCTAssertNil(NearAmount.toYocto(near: -1))
        XCTAssertEqual(NearAmount.toYocto(near: Decimal(string: "1.5")!), BigUInt("1500000000000000000000000"))
    }
}
