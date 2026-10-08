import BigInt
import Foundation

/// Turns an executed transaction into a `Transaction` record from the point of view of one account.
///
/// Accepts both shapes the kit receives: FastNEAR `/v0/transactions` items (`execution_outcome`,
/// `receipts[].receipt` + `receipts[].execution_outcome`) and RPC `EXPERIMENTAL_tx_status` results
/// (`transaction_outcome`, `receipts_outcome[]`, `receipts[]`). Everything read here is untrusted
/// indexer or node output: malformed parts are skipped, never guessed.
enum TransactionConverter {
    private static let systemAccount = "system"
    private static let eventPrefix = "EVENT_JSON:"
    private static let maxArgsLength = 2048
    private static let legacyMemoPrefix = "Memo: "
    private static let account = "([a-z0-9._-]{2,64})"
    // `[0-9]`, not `\d`, which in ICU matches every Unicode digit; Kotlin's `\d` is ASCII only
    private static let legacyTransfer = regex(#"\A(Transfer|Refund) ([0-9]{1,40}) from "# + account + " to " + account + #"\z"#)
    private static let legacyDeposit = regex(#"\ADeposit ([0-9]{1,40}) NEAR to "# + account + #"\z"#)
    private static let legacyWithdraw = regex(#"\AWithdraw ([0-9]{1,40}) NEAR from "# + account + #"\z"#)

    private struct Receipt {
        let id: String
        let predecessorId: String?
        let receiverId: String?
        /// Actions of an action receipt; nil for data receipts or when the shape is unknown.
        let actions: [Any]?
        let outcome: RpcJson?
    }

    static func convert(item: RpcJson, accountId: String, fallbackTimestamp: Int) throws -> (Transaction, Set<String>) {
        guard let tx = item.object("transaction") else {
            throw InvalidResponse("missing transaction")
        }
        let txOutcomeWrapper = item.object("execution_outcome") ?? item.object("transaction_outcome")
        let receipts = Self.receipts(item: item)
        var receiptsById = [String: Receipt]()
        for receipt in receipts {
            receiptsById[receipt.id] = receipt
        }

        let txOutcome = txOutcomeWrapper?.object("outcome")
        let (status, failure): (Transaction.Status, String?) = item["execution_outcome"] != nil && hasUnexecutedReceipts(txOutcome: txOutcome, receipts: receipts)
            ? (.pending, nil)
            : finalStatus(txOutcome: txOutcome, receipts: receiptsById)

        let outcomes = [txOutcome].compactMap { $0 } + receipts.compactMap(\.outcome)
        let burnt = outcomes.compactMap { $0.lenientBigUInt("tokens_burnt") }.reduce(BigUInt(0), +)

        let nearTransfers = receipts.flatMap { Self.nearTransfers(receipt: $0, accountId: accountId) }
        let ftTransfers = outcomes.filter(isSuccess).flatMap { Self.ftEvents(outcome: $0, accountId: accountId) }

        let timestamp = txOutcomeWrapper?.lenientUInt64("block_timestamp").map { Int($0 / 1_000_000_000) } ?? fallbackTimestamp
        let transaction = try Transaction(
            hash: tx.requireString("hash"),
            blockHeight: txOutcomeWrapper?.lenientInt("block_height"),
            timestamp: timestamp,
            signerId: tx.requireString("signer_id"),
            receiverId: tx.requireString("receiver_id"),
            actions: tx.array("actions")?.compactMap(txAction(element:)) ?? [],
            nearTransfers: nearTransfers,
            ftTransfers: ftTransfers,
            fee: status == .pending ? nil : burnt,
            status: status,
            failure: failure,
            expiresAfterHeight: nil
        )
        return (transaction, tags(transaction: transaction, accountId: accountId))
    }

    /// The record shown right after the kit submits `transaction`, before any node reports its outcome.
    static func pending(transaction tx: NearTransaction, hash: String, expiresAfterHeight: Int, timestamp: Int) -> (Transaction, Set<String>) {
        var nearTransfers = [NearTransfer]()
        var ftTransfers = [FtTransfer]()

        for action in tx.actions {
            switch action {
            case let .transfer(deposit):
                nearTransfers.append(NearTransfer(from: tx.signerId, to: tx.receiverId, amount: deposit, kind: .transfer, success: true))
            case let .functionCall(methodName, args, _, deposit):
                if deposit > 0 {
                    nearTransfers.append(NearTransfer(from: tx.signerId, to: tx.receiverId, amount: deposit, kind: .functionCallDeposit, success: true, methodName: methodName))
                }
                if methodName == "ft_transfer" || methodName == "ft_transfer_call", let args = RpcJson.object(text: String(decoding: args, as: UTF8.self)),
                   let to = args.lenientString("receiver_id"), let amount = args.lenientBigUInt("amount")
                {
                    ftTransfers.append(FtTransfer(contractId: tx.receiverId, from: tx.signerId, to: to, amount: amount, memo: args.lenientString("memo")))
                }
            default:
                break
            }
        }

        let transaction = Transaction(
            hash: hash,
            blockHeight: nil,
            timestamp: timestamp,
            signerId: tx.signerId,
            receiverId: tx.receiverId,
            actions: tx.actions.map(txAction(action:)),
            nearTransfers: nearTransfers,
            ftTransfers: ftTransfers,
            fee: nil,
            status: .pending,
            failure: nil,
            expiresAfterHeight: expiresAfterHeight
        )
        return (transaction, tags(transaction: transaction, accountId: tx.signerId))
    }

    /// The histories `transaction` appears in, as other chains do it: a token's history holds its
    /// transfers, and NEAR's history holds transactions that move NEAR (`Transaction.nearMoved`).
    /// Gas alone does not count, or every token send would show in NEAR's history too, and neither
    /// does NEAR that failed to move or came back. A signed transaction that touches no token, such
    /// as adding a key, stays in NEAR's history.
    static func tags(transaction: Transaction, accountId: String) -> Set<String> {
        var tags = Set<String>()
        let signed = transaction.signerId == accountId
        let callsToken = signed && transaction.actions.contains { Transaction.isFtMethod($0.methodName) }
        let movesNear = transaction.nearMoved(accountId: accountId) != 0
        if movesNear || (signed && !callsToken && transaction.ftTransfers.isEmpty) {
            tags.insert(TransactionTag.tokenNative)
        }
        for transfer in transaction.ftTransfers {
            tags.insert(transfer.contractId)
        }
        // a failed token send emits no event; keep it in that token's history anyway
        if callsToken {
            tags.insert(transaction.receiverId)
        }
        return tags
    }

    private static func receipts(item: RpcJson) -> [Receipt] {
        // FastNEAR: receipts[] = { receipt: {receipt_id, predecessor_id, receiver_id, receipt}, execution_outcome }
        if let array = item.array("receipts"), array.contains(where: { ($0 as? RpcJson)?["execution_outcome"] != nil }) {
            return array.compactMap { element in
                guard let entry = element as? RpcJson, let receipt = entry.object("receipt") else {
                    return nil
                }
                let outcomeWrapper = entry.object("execution_outcome")
                guard let id = receipt.lenientString("receipt_id") ?? outcomeWrapper?.lenientString("id") else {
                    return nil
                }
                return Receipt(
                    id: id,
                    predecessorId: receipt.lenientString("predecessor_id"),
                    receiverId: receipt.lenientString("receiver_id"),
                    actions: actions(receipt: receipt),
                    outcome: outcomeWrapper?.object("outcome")
                )
            }
        }

        // RPC: receipts_outcome[] = { id, outcome }, receipts[] = { receipt_id, predecessor_id, receiver_id, receipt }
        var receiptsById = [String: RpcJson]()
        for case let receipt as RpcJson in item.array("receipts") ?? [] {
            if let id = receipt.lenientString("receipt_id") {
                receiptsById[id] = receipt
            }
        }
        let outcomes = (item.array("receipts_outcome") ?? []).compactMap { $0 as? RpcJson }
        return outcomes.compactMap { wrapper in
            guard let id = wrapper.lenientString("id") else {
                return nil
            }
            let receipt = receiptsById[id]
            let outcome = wrapper.object("outcome")
            return Receipt(
                id: id,
                predecessorId: receipt?.lenientString("predecessor_id"),
                receiverId: receipt?.lenientString("receiver_id") ?? outcome?.lenientString("executor_id"),
                actions: receipt.flatMap(actions(receipt:)),
                outcome: outcome
            )
        }
    }

    private static func actions(receipt: RpcJson) -> [Any]? {
        receipt.object("receipt")?.object("Action")?.array("actions")
    }

    /// nearcore's final status: follow SuccessReceiptId from the transaction outcome until a receipt
    /// ends in SuccessValue or Failure. A missing link means execution is still in progress.
    private static func finalStatus(txOutcome: RpcJson?, receipts: [String: Receipt]) -> (Transaction.Status, String?) {
        guard var outcome = txOutcome else {
            return (.pending, nil)
        }
        for _ in 0 ... receipts.count {
            guard let status = outcome.object("status") else {
                return (.pending, nil)
            }
            if let failure = status["Failure"] {
                return (.failed, RpcJson.text(failure))
            }
            if status["SuccessValue"] != nil {
                return (.success, nil)
            }
            if status["SuccessReceiptId"] != nil {
                guard let id = status.lenientString("SuccessReceiptId"), let next = receipts[id]?.outcome else {
                    return (.pending, nil)
                }
                outcome = next
                continue
            }
            return (.pending, nil)
        }
        return (.pending, nil)
    }

    /// FastNEAR serves a transaction from its first block on, while receipts are still executing,
    /// and its final status can already be settled then: a receipt that returns a value may have
    /// spawned others (a swap output, wrap.near's NEAR payout) that run in later blocks. Until every
    /// receipt an outcome created is present, the transfers are incomplete.
    ///
    /// Only for FastNEAR items: RPC results at EXECUTED_OPTIMISTIC may leave out gas refund receipts
    /// that never matter here, and would never look complete.
    private static func hasUnexecutedReceipts(txOutcome: RpcJson?, receipts: [Receipt]) -> Bool {
        let present = Set(receipts.map(\.id))
        let outcomes = [txOutcome].compactMap { $0 } + receipts.compactMap(\.outcome)
        return outcomes
            .flatMap { ($0.array("receipt_ids") ?? []).compactMap { $0 as? String } }
            .contains { !present.contains($0) }
    }

    private static func isSuccess(_ outcome: RpcJson) -> Bool {
        guard let status = outcome.object("status") else {
            return false
        }
        return status["SuccessValue"] != nil || status["SuccessReceiptId"] != nil
    }

    private static func nearTransfers(receipt: Receipt, accountId: String) -> [NearTransfer] {
        guard let from = receipt.predecessorId, let to = receipt.receiverId else {
            return []
        }
        // `system` receipts are gas and deposit refunds, already reflected in fee and success
        guard from != systemAccount, from == accountId || to == accountId else {
            return []
        }
        let success = receipt.outcome.map(isSuccess) ?? true

        return (receipt.actions ?? []).compactMap { element in
            guard let action = element as? RpcJson else {
                return nil
            }
            if let deposit = action.object("Transfer")?.lenientBigUInt("deposit") {
                return NearTransfer(from: from, to: to, amount: deposit, kind: .transfer, success: success)
            }
            if let call = action.object("FunctionCall"), let deposit = call.lenientBigUInt("deposit"), deposit > 0 {
                return NearTransfer(from: from, to: to, amount: deposit, kind: .functionCallDeposit, success: success, methodName: call.lenientString("method_name"))
            }
            return nil
        }
    }

    /// Token movements of one outcome that involve `accountId`: NEP-141 events (NEP-297
    /// `EVENT_JSON:` logs), or, for contracts built before events existed, their plain-text logs.
    /// wrap.near is one of those.
    private static func ftEvents(outcome: RpcJson, accountId: String) -> [FtTransfer] {
        guard let contractId = outcome.lenientString("executor_id"), let rawLogs = outcome.array("logs") else {
            return []
        }
        let logs = rawLogs.compactMap { RpcJson.lenientString($0) }

        let events = logs.filter { $0.hasPrefix(eventPrefix) }.compactMap { RpcJson.object(text: String($0.dropFirst(eventPrefix.count))) }
        let transfers: [FtTransfer]
        if !events.isEmpty {
            transfers = events.filter { $0.lenientString("standard") == "nep141" }.flatMap { eventTransfers(contractId: contractId, event: $0) }
        } else {
            transfers = legacyTransfers(contractId: contractId, logs: logs)
        }
        return transfers.filter { $0.from == accountId || $0.to == accountId }
    }

    private static func eventTransfers(contractId: String, event: RpcJson) -> [FtTransfer] {
        guard let data = event.array("data") else {
            return []
        }
        let name = event.lenientString("event")
        return data.compactMap { element in
            guard let entry = element as? RpcJson, let amount = entry.lenientBigUInt("amount") else {
                return nil
            }
            let memo = entry.lenientString("memo")
            switch name {
            case "ft_transfer": return FtTransfer(contractId: contractId, from: entry.lenientString("old_owner_id"), to: entry.lenientString("new_owner_id"), amount: amount, memo: memo)
            case "ft_mint": return FtTransfer(contractId: contractId, from: nil, to: entry.lenientString("owner_id"), amount: amount, memo: memo)
            case "ft_burn": return FtTransfer(contractId: contractId, from: entry.lenientString("owner_id"), to: nil, amount: amount, memo: memo)
            default: return nil
            }
        }
    }

    /// Logs of the pre-event near-contract-standards (`Transfer 5 from a to b`, `Refund 5 from b to
    /// a`, then optionally `Memo: …`) and of wrap.near (`Deposit 5 NEAR to a`, `Withdraw 5 NEAR from a`).
    private static func legacyTransfers(contractId: String, logs: [String]) -> [FtTransfer] {
        var transfers = [FtTransfer]()
        for log in logs {
            if let groups = match(legacyTransfer, log), let amount = BigUInt(groups[2]) {
                transfers.append(FtTransfer(contractId: contractId, from: groups[3], to: groups[4], amount: amount, memo: nil))
            } else if let groups = match(legacyDeposit, log), let amount = BigUInt(groups[1]) {
                transfers.append(FtTransfer(contractId: contractId, from: nil, to: groups[2], amount: amount, memo: nil))
            } else if let groups = match(legacyWithdraw, log), let amount = BigUInt(groups[1]) {
                transfers.append(FtTransfer(contractId: contractId, from: groups[2], to: nil, amount: amount, memo: nil))
            } else if log.hasPrefix(legacyMemoPrefix), let last = transfers.popLast() {
                transfers.append(last.copy(memo: String(log.dropFirst(legacyMemoPrefix.count))))
            }
        }
        return transfers
    }

    private static func txAction(element: Any) -> TxAction? {
        // "CreateAccount" arrives as a bare string; every other action is a one-key object
        if let type = RpcJson.lenientString(element) {
            return TxAction(type: type)
        }
        guard let object = element as? RpcJson, let (type, body) = object.first else {
            return nil
        }
        guard let fields = body as? RpcJson else {
            return TxAction(type: type)
        }
        return TxAction(
            type: type,
            deposit: fields.lenientBigUInt("deposit"),
            methodName: fields.lenientString("method_name"),
            args: fields.string("args").flatMap { Data(base64Encoded: $0) }.flatMap(decodeArgs),
            gas: fields.lenientBigUInt("gas"),
            publicKey: fields.lenientString("public_key"),
            beneficiaryId: fields.lenientString("beneficiary_id"),
            stake: fields.lenientBigUInt("stake")
        )
    }

    private static func txAction(action: Action) -> TxAction {
        switch action {
        case .createAccount: return TxAction(type: "CreateAccount")
        case .deployContract: return TxAction(type: "DeployContract")
        case let .functionCall(methodName, args, gas, deposit): return TxAction(type: "FunctionCall", deposit: deposit, methodName: methodName, args: decodeArgs(args), gas: BigUInt(gas))
        case let .transfer(deposit): return TxAction(type: "Transfer", deposit: deposit)
        case let .stake(stake, publicKey): return TxAction(type: "Stake", publicKey: publicKey.description, stake: stake)
        case let .addKey(publicKey, _): return TxAction(type: "AddKey", publicKey: publicKey.description)
        case let .deleteKey(publicKey): return TxAction(type: "DeleteKey", publicKey: publicKey.description)
        case let .deleteAccount(beneficiaryId): return TxAction(type: "DeleteAccount", beneficiaryId: beneficiaryId)
        }
    }

    /// Strict UTF-8, truncated: arguments are shown, and only when they are text.
    private static func decodeArgs(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.count > maxArgsLength ? String(text.prefix(maxArgsLength)) : text
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// Capture groups of a whole-string match, group 0 first.
    private static func match(_ regex: NSRegularExpression, _ string: String) -> [String]? {
        guard let result = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else {
            return nil
        }
        return (0 ..< result.numberOfRanges).map { index in
            Range(result.range(at: index), in: string).map { String(string[$0]) } ?? ""
        }
    }
}
