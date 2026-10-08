import BigInt
import Combine
import Foundation
import GRDB
import HsToolKit

/// Public facade. Instantiate via `Kit.instance(accountId:network:rpcUrls:fastNearApiKey:walletId:)`;
/// the kit never holds a key - a `Signer` is passed into each call that signs.
public class Kit {
    public static let syncInterval: TimeInterval = 15
    /// Session request timeout of every NEAR RPC and FastNEAR call (Android `connectTimeout`): a node
    /// that does not answer is left for the next one after 10 s, not URLSession's 60 s. `send_tx`
    /// sets its own, longer timeout per request.
    static let requestTimeout: TimeInterval = 10
    public static let tokenNative = TransactionTag.tokenNative

    private static let maxTokenDecimals = 64
    private static let maxTokenText = 64

    /// The account the kit syncs and signs for: implicit (64 hex) or named.
    public let accountId: String
    public let network: Network

    private let syncManager: SyncManager
    private let transactionSyncer: TransactionSyncer
    private let transactionSender: TransactionSender
    private let rpcApiProvider: RpcApiProvider
    private let mainStorage: IMainStorage
    private let transactionStorage: ITransactionStorage

    private var started = false

    private let feeLock = NSLock()
    private var feeCalculator = FeeCalculator()
    private var feeConfigLoaded = false

    init(accountId: String, network: Network, syncManager: SyncManager, transactionSyncer: TransactionSyncer, transactionSender: TransactionSender, rpcApiProvider: RpcApiProvider, mainStorage: IMainStorage, transactionStorage: ITransactionStorage) {
        self.accountId = accountId
        self.network = network
        self.syncManager = syncManager
        self.transactionSyncer = transactionSyncer
        self.transactionSender = transactionSender
        self.rpcApiProvider = rpcApiProvider
        self.mainStorage = mainStorage
        self.transactionStorage = transactionStorage
    }

    public var receiveAddress: String {
        accountId
    }

    // MARK: - State

    public var syncState: SyncState {
        syncManager.syncState
    }

    public var syncStatePublisher: AnyPublisher<SyncState, Never> {
        syncManager.$syncState
    }

    public var transactionsSyncState: SyncState {
        transactionSyncer.syncState
    }

    public var transactionsSyncStatePublisher: AnyPublisher<SyncState, Never> {
        transactionSyncer.$syncState
    }

    public var accountState: AccountState {
        syncManager.accountState
    }

    public var accountStatePublisher: AnyPublisher<AccountState, Never> {
        syncManager.$accountState
    }

    /// False until the account first receives NEAR (implicit accounts) or is created (named).
    public var isAccountActive: Bool {
        accountState.exists
    }

    /// Liquid balance in yoctoNEAR, including what storage staking holds.
    public var balance: BigUInt {
        accountState.amount
    }

    public var balancePublisher: AnyPublisher<BigUInt, Never> {
        syncManager.$accountState.map(\.amount).removeDuplicates().eraseToAnyPublisher()
    }

    /// Spendable yoctoNEAR: `balance` minus the storage stake. See `AccountState.available`.
    public var availableBalance: BigUInt {
        accountState.available
    }

    public var availableBalancePublisher: AnyPublisher<BigUInt, Never> {
        syncManager.$accountState.map(\.available).removeDuplicates().eraseToAnyPublisher()
    }

    /// The latest final block seen; 0 before the first sync.
    public var lastBlockHeight: Int {
        syncManager.chainState?.blockHeight ?? 0
    }

    public var lastBlockHeightPublisher: AnyPublisher<Int, Never> {
        syncManager.$chainState.map { $0?.blockHeight ?? 0 }.removeDuplicates().eraseToAnyPublisher()
    }

    public var ftBalances: [FtBalance] {
        syncManager.ftBalances
    }

    public var ftBalancesPublisher: AnyPublisher<[FtBalance], Never> {
        syncManager.$ftBalances
    }

    public func ftBalance(contractId: String) -> BigUInt? {
        ftBalances.first { $0.contractId == contractId }?.balance
    }

    public func ftBalancePublisher(contractId: String) -> AnyPublisher<BigUInt?, Never> {
        syncManager.$ftBalances
            .map { balances in balances.first { $0.contractId == contractId }?.balance }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Tokens the wallet shows. Their balances are read from the contracts every sync, in addition
    /// to the index's token list, so a new token shows up without index lag. Invalid ids are dropped.
    /// The set belongs to this kit instance; a new instance starts with none.
    public func watchTokens(contractIds: Set<String>) {
        syncManager.watchedTokens = contractIds.filter { AccountId.isValid($0) }
    }

    var watchedTokens: Set<String> {
        syncManager.watchedTokens
    }

    // MARK: - History

    /// Emits every batch of new or updated transactions found by a sync or created by a send.
    public var transactionsPublisher: AnyPublisher<[Transaction], Never> {
        transactionSyncer.transactionsPublisher
    }

    /// Changed transactions in the history of `token` (nil for all, `tokenNative`, or a token
    /// contract id); empty batches are suppressed.
    public func transactionsPublisher(token: String?) -> AnyPublisher<[Transaction], Never> {
        guard let token else {
            return transactionsPublisher
        }
        let accountId = accountId
        return transactionSyncer.transactionsPublisher
            .map { transactions in transactions.filter { TransactionConverter.tags(transaction: $0, accountId: accountId).contains(token) } }
            .filter { !$0.isEmpty }
            .eraseToAnyPublisher()
    }

    /// Newest first. `token` is nil for all transactions, `tokenNative` for those that move NEAR
    /// (including every transaction the account signed, for the fee) or a token contract id. Page
    /// with the timestamp and hash of the last item of the previous page.
    public func transactions(token: String? = nil, beforeTimestamp: Int? = nil, beforeHash: String? = nil, limit: Int = 50) throws -> [Transaction] {
        try transactionStorage.transactions(token: token, beforeTimestamp: beforeTimestamp, beforeHash: beforeHash, limit: limit)
    }

    public func transaction(hash: String) throws -> Transaction? {
        try transactionStorage.transaction(hash: hash)
    }

    public func pendingTransactions() throws -> [Transaction] {
        try transactionStorage.pendingTransactions()
    }

    public func statusInfo() -> [(String, Any)] {
        // the debug dump must survive a broken database: it is where someone looks to find out what is wrong with it
        let pending: Any = (try? pendingTransactions().count) ?? "unreadable"

        return [
            ("Started", started),
            ("Account", accountId),
            ("Network", network.rawValue),
            ("RPC", rpcApiProvider.source),
            ("Last Block", lastBlockHeight),
            ("Sync State", syncState.description),
            ("Transactions Sync State", transactionsSyncState.description),
            ("Account Active", isAccountActive),
            ("Balance", balance.description),
            ("Storage Usage", accountState.storageUsage),
            ("Tokens", ftBalances.count),
            ("Pending Transactions", pending),
        ]
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        syncManager.start()
    }

    public func stop() {
        started = false
        syncManager.stop()
    }

    public func pause() {
        syncManager.pause()
    }

    public func resume() {
        syncManager.resume()
    }

    public func refresh() {
        syncManager.refresh()
    }

    /// Replaces the RPC endpoints in place, without recreating the kit or syncing again. The next
    /// call starts from the first URL. Throws `NoEndpointAvailable` for an empty list.
    public func set(rpcUrls: [URL]) throws {
        try rpcApiProvider.set(urls: rpcUrls)
    }

    // MARK: - Network queries

    public func doesAccountExist(accountId: String) async throws -> Bool {
        try await Self.doesAccountExist(accountId: accountId, rpcApiProvider: rpcApiProvider)
    }

    /// Token name, symbol and decimals from `ft_metadata`, cached after the first read.
    public func ftMetadata(contractId: String) async throws -> FtMetadata {
        if let metadata = try mainStorage.ftMetadata(contractId: contractId) {
            return metadata
        }
        let metadata = try await Self.ftMetadata(contractId: contractId, rpcApiProvider: rpcApiProvider)
        try mainStorage.save(ftMetadata: metadata)
        return metadata
    }

    /// yoctoNEAR `accountId` still has to deposit with the token contract to hold it, or nil when registered.
    public func ftStorageDepositRequired(contractId: String, accountId: String) async throws -> BigUInt? {
        try await FtActions.storageDepositRequired(rpcApiProvider: rpcApiProvider, contractId: contractId, accountId: accountId)
    }

    // MARK: - Fees

    /// Fee and required balance for sending `actions` to `receiverId`. A transfer to an implicit
    /// account that does not exist yet also pays the account creation charge (0.007 NEAR).
    public func estimateFee(receiverId: String, actions: [Action]) async throws -> FeeEstimate {
        try await estimateFee(receiverId: receiverId, actions: actions, expectedCallGas: nil)
    }

    public func estimateNearTransfer(receiverId: String) async throws -> FeeEstimate {
        try await estimateFee(receiverId: receiverId, actions: [.transfer(deposit: 1)])
    }

    /// The most NEAR a transfer to `receiverId` can send: what is available minus the balance the fee needs.
    public func maxSendableNear(receiverId: String) async throws -> BigUInt {
        let required = try await estimateNearTransfer(receiverId: receiverId).requiredBalance
        let available = availableBalance
        return available > required ? available - required : 0
    }

    /// Fee for a token transfer, plus the storage deposit the receiver still needs, if any.
    public func estimateFtTransfer(contractId: String, receiverId: String, amount: BigUInt, memo: String? = nil) async throws -> FtTransferEstimate {
        let storageDeposit = try await ftStorageDepositRequired(contractId: contractId, accountId: receiverId)
        let actions = try FtActions.transfer(receiverId: receiverId, amount: amount, memo: memo, storageDeposit: storageDeposit)
        return await FtTransferEstimate(
            fee: try estimateFee(receiverId: contractId, actions: actions, expectedCallGas: FtActions.expectedGas),
            storageDeposit: storageDeposit
        )
    }

    private func estimateFee(receiverId: String, actions: [Action], expectedCallGas: UInt64?) async throws -> FeeEstimate {
        let calculator = await loadFeeCalculator()
        let gasPrice: BigUInt
        if let chainState = syncManager.chainState {
            gasPrice = chainState.gasPrice
        } else {
            gasPrice = try await rpcApiProvider.latestBlock().gasPrice
        }
        let implicit = AccountId.isImplicit(receiverId)
        let hasTransfer = actions.contains { if case .transfer = $0 { return true } else { return false } }
        var createsAccount = false
        if implicit, hasTransfer {
            createsAccount = try await !doesAccountExist(accountId: receiverId)
        }
        return calculator.estimate(actions: actions, receiverIsImplicit: implicit, createsAccount: createsAccount, gasPrice: gasPrice, expectedCallGas: expectedCallGas)
    }

    /// The runtime fee config, read once; until it loads the built-in mainnet values are used and
    /// the next estimate tries again.
    private func loadFeeCalculator() async -> FeeCalculator {
        let (current, loaded) = feeState()

        guard !loaded, let config = try? await rpcApiProvider.protocolConfig() else {
            return current
        }

        let calculator = FeeCalculator.Config.from(protocolConfig: config).map { FeeCalculator(config: $0) } ?? current
        setLoaded(feeCalculator: calculator)
        return calculator
    }

    private func feeState() -> (FeeCalculator, Bool) {
        feeLock.lock()
        defer { feeLock.unlock() }
        return (feeCalculator, feeConfigLoaded)
    }

    private func setLoaded(feeCalculator: FeeCalculator) {
        feeLock.lock()
        self.feeCalculator = feeCalculator
        feeConfigLoaded = true
        feeLock.unlock()
    }

    // MARK: - Sending

    /// Sends NEAR. A named receiver must exist; implicit receivers are created by the transfer.
    public func sendNear(receiverId: String, amount: BigUInt, signer: Signer) async throws -> Transaction {
        try AccountId.validate(receiverId)
        if !AccountId.isImplicit(receiverId), try await !doesAccountExist(accountId: receiverId) {
            throw SendError.receiverNotFound(receiverId)
        }
        guard amount > 0 else {
            throw SendError.invalidAmount
        }
        return try await send(signer: signer, receiverId: receiverId, actions: [.transfer(deposit: amount)])
    }

    /// Sends a NEP-141 token. When the receiver is not registered with the token contract, the same
    /// transaction first pays its storage deposit (usually 0.00125 NEAR, at most
    /// `FtActions.maxStorageDeposit`) from this account.
    ///
    /// Pass the `estimate` the user confirmed: the send then fails with
    /// `SendError.storageDepositChanged` if the contract now asks for a different deposit.
    public func sendFt(contractId: String, receiverId: String, amount: BigUInt, memo: String? = nil, estimate: FtTransferEstimate? = nil, signer: Signer) async throws -> Transaction {
        try AccountId.validate(contractId)
        try AccountId.validate(receiverId)
        guard amount > 0 else {
            throw SendError.invalidAmount
        }
        let storageDeposit = try await ftStorageDepositRequired(contractId: contractId, accountId: receiverId)
        if let estimate, estimate.storageDeposit != storageDeposit {
            throw SendError.storageDepositChanged(confirmed: estimate.storageDeposit, required: storageDeposit)
        }
        let actions = try FtActions.transfer(receiverId: receiverId, amount: amount, memo: memo, storageDeposit: storageDeposit)
        return try await send(signer: signer, receiverId: contractId, actions: actions)
    }

    /// Signs and submits arbitrary actions, e.g. a swap deposit.
    public func sendTransaction(receiverId: String, actions: [Action], signer: Signer) async throws -> Transaction {
        try AccountId.validate(receiverId)
        guard !actions.isEmpty else {
            throw SendError.noActions
        }
        return try await send(signer: signer, receiverId: receiverId, actions: actions)
    }

    /// Signs without submitting, with a fresh nonce and block hash.
    public func signTransaction(receiverId: String, actions: [Action], signer: Signer) async throws -> SignedTransaction {
        try AccountId.validate(receiverId)
        return try await transactionSender.sign(signer: signer, receiverId: receiverId, actions: actions)
    }

    /// Signs a transaction someone else built (WalletConnect `near_signTransaction`). The signer id
    /// must be this kit's account and the public key the signer's; the nonce and block hash are
    /// taken as given.
    public func signTransaction(_ transaction: NearTransaction, signer: Signer) throws -> SignedTransaction {
        guard transaction.signerId == accountId else {
            throw SendError.signerMismatch
        }
        return try signer.sign(transaction)
    }

    /// Signs a NEP-413 message (WalletConnect `near_signMessage`). Only a full-access key of the
    /// account signs: a dApp verifies the signature against the account's keys.
    public func signMessage(_ payload: MessagePayload, signer: Signer) async throws -> SignedMessage {
        _ = try await transactionSender.requireFullAccess(signer: signer)
        return try SignedMessage(accountId: accountId, publicKey: signer.publicKey, signature: signer.sign(payload))
    }

    /// Submits a transaction signed elsewhere and records it as pending. It must be signed by this
    /// account: anything else would show up in the account's history as its own send. The node
    /// checks the signature and the key.
    public func submit(_ signed: SignedTransaction) async throws -> Transaction {
        guard signed.transaction.signerId == accountId else {
            throw SendError.signerMismatch
        }
        let transaction = try await transactionSender.submit(signed: signed, referenceHeight: nil)
        await syncAfterSend()
        return transaction
    }

    private func send(signer: Signer, receiverId: String, actions: [Action]) async throws -> Transaction {
        let transaction = try await transactionSender.send(signer: signer, receiverId: receiverId, actions: actions)
        await syncAfterSend()
        return transaction
    }

    private func syncAfterSend() async {
        // the send already succeeded; if this cycle fails the next timer tick picks the state up
        await syncManager.syncNow()
    }
}

// MARK: - Account ids

public extension Kit {
    /// Throws `AccountIdError.invalid` for anything that is not a NEAR account id.
    static func validate(accountId: String) throws {
        try AccountId.validate(accountId)
    }

    static func isValid(accountId: String) -> Bool {
        AccountId.isValid(accountId)
    }

    static func accountIdKind(_ accountId: String) -> AccountId.Kind? {
        AccountId.kind(accountId)
    }

    static func isImplicit(accountId: String) -> Bool {
        AccountId.isImplicit(accountId)
    }
}

// MARK: - Fees without a receiver

public extension Kit {
    /// yoctoNEAR a NEAR transfer needs in the worst case, when the receiver is an implicit account
    /// the transfer creates: gas bought at the minimum purchase price plus the account creation
    /// charge. Independent of the block gas price while that stays below the minimum, so it bounds
    /// "send max" before the receiver is known (Android `BaseNearAdapter.WORST_CASE_TRANSFER_REQUIRED`).
    static let worstCaseTransferRequired: BigUInt = FeeCalculator().estimate(
        actions: [.transfer(deposit: 1)],
        receiverIsImplicit: true,
        createsAccount: true,
        gasPrice: 0
    ).requiredBalance
}

// MARK: - Wallet-free queries

/// Lookups for an account no kit is open for, e.g. adding a token or restoring a key. Static and
/// independent of any Kit instance, like `NodePinger`.
public extension Kit {
    /// Accounts `publicKey` controls with full access: its implicit account plus named accounts the
    /// index knows about, each confirmed on chain. The implicit account is always first, even before
    /// it exists, because that is where funds sent to the key arrive.
    static func findAccounts(publicKey: PublicKey, network: Network, rpcUrls: [URL]? = nil, fastNearApiKey: String? = nil) async throws -> [String] {
        let networkManager = NetworkManager(timeout: requestTimeout)
        let auth = FastNearAuth(apiKey: fastNearApiKey)
        let rpcApiProvider = try rpcApiProvider(urls: rpcUrls ?? network.rpcUrls, networkManager: networkManager, auth: auth)
        let indexerProvider = FastNearProvider(network: network, auth: auth, networkManager: networkManager)
        return try await findAccounts(publicKey: publicKey, rpcApiProvider: rpcApiProvider, indexerProvider: indexerProvider)
    }

    /// Token metadata without a kit (adding a token by its contract id). Not cached.
    static func ftMetadata(contractId: String, rpcUrls: [URL]) async throws -> FtMetadata {
        try await ftMetadata(contractId: contractId, rpcApiProvider: rpcApiProvider(urls: rpcUrls, networkManager: NetworkManager(timeout: requestTimeout)))
    }

    static func doesAccountExist(accountId: String, rpcUrls: [URL]) async throws -> Bool {
        try await doesAccountExist(accountId: accountId, rpcApiProvider: rpcApiProvider(urls: rpcUrls, networkManager: NetworkManager(timeout: requestTimeout)))
    }
}

extension Kit {
    static func findAccounts(publicKey: PublicKey, rpcApiProvider: RpcApiProvider, indexerProvider: IIndexerProvider) async throws -> [String] {
        let implicit = publicKey.implicitAccountId
        var accounts = [implicit]
        for accountId in try await indexerProvider.accountIds(publicKey: publicKey.description) where accountId != implicit && AccountId.isValid(accountId) && !accounts.contains(accountId) {
            if try await rpcApiProvider.viewAccessKey(accountId: accountId, publicKey: publicKey.description)?.isFullAccess == true {
                accounts.append(accountId)
            }
        }
        return accounts
    }

    static func doesAccountExist(accountId: String, rpcApiProvider: RpcApiProvider) async throws -> Bool {
        try await rpcApiProvider.viewAccount(accountId: accountId) != nil
    }

    static func ftMetadata(contractId: String, rpcApiProvider: RpcApiProvider) async throws -> FtMetadata {
        guard let json = try await rpcApiProvider.callFunctionJson(contractId: contractId, methodName: "ft_metadata") as? RpcJson else {
            throw InvalidResponse("ft_metadata: not an object")
        }
        guard let decimals = json.lenientInt("decimals"), (0 ... maxTokenDecimals).contains(decimals) else {
            throw InvalidResponse("ft_metadata: invalid decimals")
        }
        guard let symbol = json.lenientString("symbol") else {
            throw InvalidResponse("ft_metadata: missing symbol")
        }
        return FtMetadata(
            contractId: contractId,
            name: String((json.lenientString("name") ?? "").prefix(maxTokenText)),
            symbol: String(symbol.prefix(maxTokenText)),
            decimals: decimals,
            spec: json.lenientString("spec")
        )
    }

    private static func rpcApiProvider(urls: [URL], networkManager: NetworkManager, auth: FastNearAuth? = nil) throws -> RpcApiProvider {
        // the provider traps on an empty list; here it is the caller's input, so it is an error instead
        guard !urls.isEmpty else {
            throw NoEndpointAvailable(underlying: nil)
        }
        return RpcApiProvider(urls: urls, networkManager: networkManager, auth: auth, logger: Logger(minLogLevel: .error))
    }
}

// MARK: - Instances

public extension Kit {
    /// A kit for `accountId`, implicit or named. `rpcUrls` are tried in order (the selected node first),
    /// `fastNearApiKey` goes to FastNEAR hosts only: the index and FastNEAR's own RPC nodes.
    static func instance(accountId: String, network: Network, rpcUrls: [URL], fastNearApiKey: String? = nil, walletId: String, minLogLevel: Logger.Level = .error) throws -> Kit {
        try AccountId.validate(accountId)
        let logger = Logger(minLogLevel: minLogLevel)

        // deliberately unlogged, as in XrpKit: `NetworkManager` prints the whole request body when a
        // call fails, and for `send_tx` that body is the signed transaction. The providers log
        // failures themselves, with the method and the host but no parameters.
        let networkManager = NetworkManager(timeout: requestTimeout)
        let auth = FastNearAuth(apiKey: fastNearApiKey, logger: logger)
        let rpcApiProvider = try rpcApiProvider(urls: rpcUrls, networkManager: networkManager, auth: auth)
        let indexerProvider = FastNearProvider(network: network, auth: auth, networkManager: networkManager)
        let dbPool = try KitDatabase.pool(network: network, walletId: walletId)

        return try instance(
            accountId: accountId, network: network, rpcApiProvider: rpcApiProvider, indexerProvider: indexerProvider,
            dbPool: dbPool, connectionManager: ReachabilityManager(), logger: logger
        )
    }

    /// Removes the databases of every wallet not listed, for both networks.
    static func clear(exceptFor walletIds: [String]) throws {
        try KitDatabase.clear(exceptFor: walletIds)
    }
}

extension Kit {
    static func instance(accountId: String, network: Network, rpcApiProvider: RpcApiProvider, indexerProvider: IIndexerProvider, dbPool: DatabasePool, connectionManager: IConnectionManager, logger: Logger?) throws -> Kit {
        let mainStorage = try MainStorage(dbPool: dbPool)
        let transactionStorage = try TransactionStorage(dbPool: dbPool)

        let transactionSyncer = TransactionSyncer(accountId: accountId, rpcApiProvider: rpcApiProvider, indexerProvider: indexerProvider, mainStorage: mainStorage, transactionStorage: transactionStorage, logger: logger)
        let apiSyncer = ApiSyncer(connectionManager: connectionManager, syncInterval: syncInterval)
        let syncManager = try SyncManager(accountId: accountId, apiSyncer: apiSyncer, rpcApiProvider: rpcApiProvider, indexerProvider: indexerProvider, transactionSyncer: transactionSyncer, storage: mainStorage, logger: logger)
        let transactionSender = TransactionSender(accountId: accountId, rpcApiProvider: rpcApiProvider, mainStorage: mainStorage, transactionStorage: transactionStorage) { [weak transactionSyncer] transaction in
            transactionSyncer?.publish(transactions: [transaction])
        }

        return Kit(
            accountId: accountId, network: network, syncManager: syncManager, transactionSyncer: transactionSyncer, transactionSender: transactionSender,
            rpcApiProvider: rpcApiProvider, mainStorage: mainStorage, transactionStorage: transactionStorage
        )
    }
}
