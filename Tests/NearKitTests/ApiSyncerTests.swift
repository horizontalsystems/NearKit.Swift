import Foundation
@testable import NearKit
import XCTest

/// The timer is installed on main a queue hop after it is asked for; a stop, a pause or a lost
/// connection in between must not leave it running (Android `SyncTimer` starts its job at once).
final class ApiSyncerTests: XCTestCase {
    private final class Delegate: IApiSyncerDelegate {
        var syncs = 0

        func didUpdateSyncerState(_: SyncerState) {}

        func sync() {
            syncs += 1
        }
    }

    private var connectionManager: StubConnectionManager!
    private var syncer: ApiSyncer!
    private var delegate: Delegate!

    override func setUp() {
        connectionManager = StubConnectionManager(connected: true)
        // long enough that no tick fires during a test: only the sync a started timer runs at once counts
        syncer = ApiSyncer(connectionManager: connectionManager, syncInterval: 1000)
        delegate = Delegate()
        syncer.delegate = delegate
    }

    override func tearDown() {
        syncer.stop()
        super.tearDown()
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testStartRunsASyncAtOnce() {
        syncer.start()
        drainMainQueue()

        XCTAssertEqual(delegate.syncs, 1)
    }

    func testPauseBeforeTheTimerIsInstalledKeepsItOff() {
        syncer.start()
        syncer.pause()
        drainMainQueue()

        XCTAssertEqual(delegate.syncs, 0)
    }

    func testStopBeforeTheTimerIsInstalledKeepsItOff() {
        syncer.start()
        syncer.stop()
        drainMainQueue()

        XCTAssertEqual(delegate.syncs, 0)
    }

    func testLostConnectionBeforeTheTimerIsInstalledKeepsItOff() {
        syncer.start()
        connectionManager.set(connected: false)
        drainMainQueue()

        XCTAssertEqual(delegate.syncs, 0)
    }

    func testResumeRestartsTheTimer() {
        syncer.start()
        syncer.pause()
        syncer.resume()
        drainMainQueue()

        // both queued starts run, each replacing the timer before it: one timer stays, it syncs at once
        XCTAssertGreaterThan(delegate.syncs, 0)
    }
}
