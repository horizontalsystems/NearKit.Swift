import Foundation

/// `status`: the node's chain id and how far it has synced.
class StatusJsonRpc: JsonRpc<NodeStatus> {
    init() {
        super.init(method: "status", params: [Any]())
    }

    override func parse(result: RpcJson) throws -> NodeStatus {
        let syncInfo = try result.requireObject("sync_info")
        guard let syncing = syncInfo["syncing"] as? NSNumber, CFGetTypeID(syncing) == CFBooleanGetTypeID() else {
            throw InvalidResponse("status: missing syncing")
        }
        return NodeStatus(
            chainId: try result.requireString("chain_id"),
            latestBlockHeight: try syncInfo.requireUInt64("latest_block_height"),
            syncing: syncing.boolValue
        )
    }
}

struct NodeStatus {
    let chainId: String
    let latestBlockHeight: UInt64
    let syncing: Bool
}
