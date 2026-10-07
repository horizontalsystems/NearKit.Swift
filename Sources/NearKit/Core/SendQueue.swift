import Foundation

/// Runs async operations one at a time, in the order they were enqueued (Android `Mutex.withLock`).
///
/// Not an actor on purpose: an actor is reentrant at every `await`, so two sends could both read
/// the access key nonce before either submits. Here each operation waits for the previous one to
/// finish completely. A failed or cancelled operation does not break the queue, and cancelling
/// the caller cancels its own operation.
final class SendQueue {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let task = enqueue(operation)

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func enqueue<T>(_ operation: @escaping () async throws -> T) -> Task<T, Error> {
        lock.lock()
        defer { lock.unlock() }

        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task {
            _ = await task.result
        }
        return task
    }
}
