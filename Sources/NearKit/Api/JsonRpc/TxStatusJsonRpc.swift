import Foundation

/// `EXPERIMENTAL_tx_status` without waiting: the outcome so far, with receipts.
class TxStatusJsonRpc: JsonRpc<TxStatus> {
    init(hash: String, senderAccountId: String) {
        super.init(method: "EXPERIMENTAL_tx_status", params: ["tx_hash": hash, "sender_account_id": senderAccountId, "wait_until": "NONE"])
    }

    override func parse(result: RpcJson) throws -> TxStatus {
        TxStatus(finalExecutionStatus: result.string("final_execution_status") ?? "NONE", raw: result["transaction"] != nil ? result : nil)
    }
}
