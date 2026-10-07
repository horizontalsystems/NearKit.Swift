import Foundation

class ProtocolConfigJsonRpc: JsonRpc<RpcJson> {
    init() {
        super.init(method: "EXPERIMENTAL_protocol_config", params: ["finality": "final"])
    }

    override func parse(result: RpcJson) throws -> RpcJson {
        result
    }
}
