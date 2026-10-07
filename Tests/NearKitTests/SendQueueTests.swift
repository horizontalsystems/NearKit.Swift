@testable import NearKit
import XCTest

/// Sends are serialized so two of them never read the same access key nonce (Android `sendMutex.withLock`).
final class SendQueueTests: XCTestCase {
    private struct Failure: Error {}

    /// Start and end of each operation, in the order they happened.
    private final class Log {
        private let lock = NSLock()
        private var _events = [String]()

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _events
        }

        func append(_ event: String) {
            lock.lock()
            _events.append(event)
            lock.unlock()
        }
    }

    private let queue = SendQueue()
    private let log = Log()

    private func operation(_ id: Int) -> () async throws -> Int {
        { [log] in
            log.append("start \(id)")
            try await Task.sleep(nanoseconds: 20_000_000)
            log.append("end \(id)")
            return id
        }
    }

    func testParallelOperationsRunOneAfterAnother() async throws {
        let ids = Array(0 ..< 5)

        let operations = ids.map { operation($0) }

        let results = try await withThrowingTaskGroup(of: Int.self) { [queue] group in
            for operation in operations {
                group.addTask { try await queue.run(operation) }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }

        XCTAssertEqual(results.sorted(), ids)
        let events = log.events
        XCTAssertEqual(events.count, ids.count * 2)
        // each operation ends before the next one starts
        for index in stride(from: 0, to: events.count, by: 2) {
            let id = events[index].dropFirst("start ".count)
            XCTAssertEqual(events[index], "start \(id)", "\(events)")
            XCTAssertEqual(events[index + 1], "end \(id)", "\(events)")
        }
    }

    func testFailedOperationDoesNotStallTheQueue() async throws {
        let started = expectation(description: "first started")
        let first = Task { [queue, log] in
            try await queue.run {
                log.append("start 1")
                started.fulfill()
                try await Task.sleep(nanoseconds: 50_000_000)
                log.append("end 1")
                throw Failure()
            }
        }
        await fulfillment(of: [started], timeout: 5)

        // enqueued while the first is still running
        let second = try await queue.run(operation(2))

        XCTAssertEqual(second, 2)
        do {
            try await first.value
            XCTFail("no error")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        XCTAssertEqual(log.events, ["start 1", "end 1", "start 2", "end 2"])
    }
}
