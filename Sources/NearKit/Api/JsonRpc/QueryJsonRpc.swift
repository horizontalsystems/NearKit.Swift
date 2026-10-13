import Foundation

/// `query` at `finality: final`. Older nodes report some view failures inside a successful result
/// as an `error` string instead of an error response; those are turned into `RpcError` here.
class QueryJsonRpc<T>: JsonRpc<T> {
    init(params: RpcJson) {
        var params = params
        params["finality"] = "final"
        super.init(method: "query", params: params)
    }

    override func parse(result: RpcJson) throws -> T {
        if let message = result.string("error") {
            let name: String
            if message.contains("access key"), message.contains("does not exist") {
                name = RpcError.unknownAccessKey
            } else if message.contains("does not exist") {
                name = RpcError.unknownAccount
            } else {
                name = "QUERY_ERROR"
            }
            throw RpcError(name: name, data: nil, message: message)
        }
        return try parseQuery(result: result)
    }

    func parseQuery(result _: RpcJson) throws -> T {
        fatalError("This method should be overridden")
    }
}

class ViewAccountJsonRpc: QueryJsonRpc<AccountView> {
    init(accountId: String) {
        super.init(params: ["request_type": "view_account", "account_id": accountId])
    }

    override func parseQuery(result: RpcJson) throws -> AccountView {
        AccountView(
            amount: try result.requireBigUInt("amount"),
            locked: try result.requireBigUInt("locked"),
            storageUsage: try result.requireUInt64("storage_usage"),
            codeHash: try result.requireString("code_hash"),
            globalContractHash: result.string("global_contract_hash"),
            globalContractAccountId: result.string("global_contract_account_id"),
            blockHeight: try result.requireHeight("block_height")
        )
    }
}

class ViewAccessKeyListJsonRpc: QueryJsonRpc<[AccessKeyInfo]> {
    init(accountId: String) {
        super.init(params: ["request_type": "view_access_key_list", "account_id": accountId])
    }

    // A function-call key's permission is an object, a full-access key's the string "FullAccess".
    // Keys stay strings: an account may hold secp256k1 keys this kit cannot parse.
    override func parseQuery(result: RpcJson) throws -> [AccessKeyInfo] {
        guard let keys = result.array("keys") else {
            throw InvalidResponse("view_access_key_list: missing keys")
        }
        return try keys.map { item in
            guard let key = item as? RpcJson else {
                throw InvalidResponse("view_access_key_list: key is not an object")
            }
            return AccessKeyInfo(
                publicKey: try key.requireString("public_key"),
                isFullAccess: key.object("access_key")?.string("permission") == "FullAccess"
            )
        }
    }
}

class ViewAccessKeyJsonRpc: QueryJsonRpc<AccessKeyView> {
    init(accountId: String, publicKey: String) {
        super.init(params: ["request_type": "view_access_key", "account_id": accountId, "public_key": publicKey])
    }

    override func parseQuery(result: RpcJson) throws -> AccessKeyView {
        AccessKeyView(
            nonce: try result.requireUInt64("nonce"),
            isFullAccess: result.string("permission") == "FullAccess",
            blockHash: try result.requireString("block_hash"),
            blockHeight: try result.requireHeight("block_height")
        )
    }
}

/// A view method call. Returns the raw bytes the contract returned (usually JSON).
class CallFunctionJsonRpc: QueryJsonRpc<Data> {
    init(contractId: String, methodName: String, argsJson: String) {
        super.init(params: [
            "request_type": "call_function",
            "account_id": contractId,
            "method_name": methodName,
            "args_base64": Data(argsJson.utf8).base64EncodedString(),
        ])
    }

    override func parseQuery(result: RpcJson) throws -> Data {
        guard let array = result.array("result") else {
            throw InvalidResponse("call_function: missing result")
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(array.count)
        for element in array {
            guard let number = element as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let byte = UInt8(exactly: number) else {
                throw InvalidResponse("call_function: result is not bytes")
            }
            bytes.append(byte)
        }
        return Data(bytes)
    }
}
