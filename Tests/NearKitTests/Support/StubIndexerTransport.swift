import Foundation
@testable import NearKit

/// Scripted FastNEAR hosts under the real `FastNearProvider`. Answers are queued per URL path
/// (`/v0/account`, `/v0/transactions`, `/v1/account/<id>/ft`) and consumed in order; a request
/// nothing was queued for is recorded in `unexpected` and answered with an unusable body.
final class StubIndexerTransport: IIndexerTransport {
    enum Answer {
        case json(Any)
        case failure(Error)
    }

    struct Request {
        let url: URL
        let body: RpcJson?
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var answers = [String: [Answer]]()
    private var _requests = [Request]()
    private var _unexpected = [String]()

    func answer(_ path: String, _ answers: Answer...) {
        lock.lock()
        self.answers[path, default: []] += answers
        lock.unlock()
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func requests(_ path: String) -> [Request] {
        requests.filter { $0.url.path == path }
    }

    var unexpected: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _unexpected
    }

    func get(url: URL, headers: [String: String]) async throws -> Any {
        try respond(Request(url: url, body: nil, headers: headers))
    }

    func post(url: URL, body: RpcJson, headers: [String: String]) async throws -> Any {
        try respond(Request(url: url, body: body, headers: headers))
    }

    private func respond(_ request: Request) throws -> Any {
        let path = request.url.path

        lock.lock()
        _requests.append(request)
        let answer = answers[path]?.isEmpty == false ? answers[path]?.removeFirst() : nil
        if answer == nil {
            _unexpected.append(path)
        }
        lock.unlock()

        switch answer {
        case let .json(json):
            return json
        case let .failure(error):
            throw error
        case nil:
            return ["error": "unexpected"]
        }
    }
}

extension FastNearProvider {
    static func stub(_ transport: StubIndexerTransport, apiKey: String? = nil) -> FastNearProvider {
        FastNearProvider(apiUrl: URL(string: "https://api.fastnear.test/")!, txApiUrl: URL(string: "https://tx.fastnear.test/")!, apiKey: apiKey, transport: transport)
    }
}
