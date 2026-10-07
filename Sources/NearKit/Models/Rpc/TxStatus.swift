import Foundation

/// Result of `EXPERIMENTAL_tx_status`, or of `send_tx` when it waited for execution.
struct TxStatus {
    private static let executedStates: Set<String> = ["EXECUTED_OPTIMISTIC", "EXECUTED", "FINAL"]

    /// NONE, INCLUDED, EXECUTED_OPTIMISTIC, INCLUDED_FINAL, EXECUTED or FINAL.
    let finalExecutionStatus: String
    /// Full response (`transaction`, `transaction_outcome`, `receipts_outcome`, `receipts`, `status`); absent before execution.
    let raw: RpcJson?

    var isExecuted: Bool {
        raw?["status"] != nil && Self.executedStates.contains(finalExecutionStatus)
    }
}
