import Foundation
@testable import NearKit

/// Scripted nearcore nodes (Android `FakeNear`, XrpKit `StubRpcTransport` form). Answers are queued
/// per key and consumed in order, whichever node is asked. The key is the JSON-RPC method, and for
/// `query` also the request type (`query.view_account`). A request nothing was queued for is
/// recorded in `unexpected` and fails like a malformed response, so the provider moves on.
final class StubRpcTransport: IRpcTransport {
    enum Answer {
        /// `{"result": …}`
        case result(Any)
        /// The whole response object, as is.
        case raw(Any)
        /// A transport failure.
        case failure(Error)

        /// A nearcore handler error, as `send_tx` and `EXPERIMENTAL_tx_status` return them.
        static func error(cause: String, data: Any? = nil) -> Answer {
            .raw(["error": ["name": "HANDLER_ERROR", "cause": ["name": cause], "code": -32000, "message": "Server error", "data": data ?? NSNull()]])
        }
    }

    struct Call {
        let url: URL
        let key: String
        let params: RpcJson
        let timeout: TimeInterval?
    }

    private let lock = NSLock()
    private var answers = [String: [Answer]]()
    private var _calls = [Call]()
    private var _unexpected = [String]()

    func answer(_ key: String, _ answers: Answer...) {
        answer(key, answers)
    }

    func answer(_ key: String, _ answers: [Answer]) {
        lock.lock()
        self.answers[key, default: []] += answers
        lock.unlock()
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func calls(_ key: String) -> [Call] {
        calls.filter { $0.key == key }
    }

    /// Requests nothing was queued for; a test should end with none.
    var unexpected: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _unexpected
    }

    func post(url: URL, body: RpcJson, timeout: TimeInterval?) async throws -> Any {
        let method = body["method"] as? String ?? ""
        let params = body["params"] as? RpcJson ?? [:]
        let key = method == "query" ? "query.\(params["request_type"] as? String ?? "")" : method

        switch next(call: Call(url: url, key: key, params: params, timeout: timeout)) {
        case let .result(result):
            return ["jsonrpc": "2.0", "id": "nearkit", "result": result]
        case let .raw(response):
            return response
        case let .failure(error):
            throw error
        case nil:
            return ["error": "unexpected"]
        }
    }

    private func next(call: Call) -> Answer? {
        lock.lock()
        defer { lock.unlock() }

        _calls.append(call)
        let answer = answers[call.key]?.isEmpty == false ? answers[call.key]?.removeFirst() : nil
        if answer == nil {
            _unexpected.append(call.key)
        }
        return answer
    }
}
