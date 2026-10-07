import Foundation

/// One nearcore JSON-RPC 2.0 call. The response carries either `result` or `error`.
class JsonRpc<T> {
    let method: String
    let params: Any
    /// Overrides the session's request timeout for this call only; nil keeps the session's.
    let timeout: TimeInterval?

    init(method: String, params: Any, timeout: TimeInterval? = nil) {
        self.method = method
        self.params = params
        self.timeout = timeout
    }

    var body: RpcJson {
        ["jsonrpc": "2.0", "id": "nearkit", "method": method, "params": params]
    }

    func parse(result _: RpcJson) throws -> T {
        fatalError("This method should be overridden")
    }
}

enum JsonRpcResponse {
    /// The `result` object, or the node's `error` as `RpcError`.
    static func result(method: String, jsonObject: Any) throws -> RpcJson {
        guard let response = jsonObject as? RpcJson else {
            throw InvalidResponse("\(method): not an object")
        }
        if let error = response.object("error") {
            throw parseError(error)
        }
        guard let result = response.object("result") else {
            throw InvalidResponse("\(method): missing result")
        }
        return result
    }

    /// `error.cause.name`, else `error.name`, else UNKNOWN (Android `RpcProvider.parseError`).
    static func parseError(_ error: RpcJson) -> RpcError {
        let name = error.object("cause")?.lenientString("name") ?? error.lenientString("name") ?? "UNKNOWN"
        let data = error["data"].flatMap { $0 is NSNull ? nil : $0 }
        let message = data.flatMap { RpcJson.lenientString($0) } ?? error.lenientString("message")
        return RpcError(name: name, data: data.map { RpcJson.text($0) }, message: message)
    }
}
