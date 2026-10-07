import Foundation

/// `send_tx`. With `waitUntil` INCLUDED the node answers once the transaction is in a block;
/// invalid transactions (bad nonce, not enough balance, expired) are refused with INVALID_TRANSACTION.
class SendTxJsonRpc: JsonRpc<TxStatus> {
    /// The node holds the response until the transaction is in a block, so the answer can take
    /// longer than the kit's 10 s request timeout without the node being down.
    static let timeout: TimeInterval = 30

    private let waitUntil: String

    init(signedTxBase64: String, waitUntil: String) {
        self.waitUntil = waitUntil
        super.init(method: "send_tx", params: ["signed_tx_base64": signedTxBase64, "wait_until": waitUntil], timeout: Self.timeout)
    }

    override func parse(result: RpcJson) throws -> TxStatus {
        TxStatus(finalExecutionStatus: result.string("final_execution_status") ?? waitUntil, raw: result["transaction"] != nil ? result : nil)
    }
}
