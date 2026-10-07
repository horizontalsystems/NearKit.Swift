import Foundation

class BlockJsonRpc: JsonRpc<BlockHeader> {
    init() {
        super.init(method: "block", params: ["finality": "final"])
    }

    override func parse(result: RpcJson) throws -> BlockHeader {
        let header = try result.requireObject("header")
        guard let timestamp = UInt64(try header.requireString("timestamp_nanosec")) else {
            throw InvalidResponse("block: invalid timestamp_nanosec")
        }
        return BlockHeader(
            height: try header.requireHeight("height"),
            hash: try header.requireString("hash"),
            timestampNanos: timestamp,
            gasPrice: try header.requireBigUInt("gas_price")
        )
    }
}
