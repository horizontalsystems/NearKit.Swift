# NearKit.Swift

NEAR Protocol kit for iOS, in the style of the other Horizontal Systems `*Kit.Swift` libraries.
Parity target: [`near-android-kit`](https://github.com/horizontalsystems/near-android-kit).

Status: complete locally and untagged. It waits for the HsToolKit release with request timeouts (`NetworkManager(timeout:)`); until then `Package.swift` points at a local HsToolKit checkout. Design of record: Unstoppable Wallet iOS spec `docs/specs/2026-10-06-near-ios-kit-design.md`.

Test fixtures in `Tests/NearKitTests/Fixtures/`: signing and encoding vectors from [near-seed-phrase](https://github.com/near/near-seed-phrase) and [near-api-js](https://github.com/near/near-api-js) (`@near-js/transactions`, `@near-js/signers`), real mainnet and testnet responses shared with the Android kit, and a mainnet `EXPERIMENTAL_protocol_config` answer.

## Scope

- Keys: Ed25519 at SLIP-10 `m/44'/397'/0'` from a BIP39 seed, the derivation near-seed-phrase (MyNearWallet, near-cli) uses; `ed25519:…` secret keys import too. Implicit (64 hex), ETH-implicit (`0x…`) and named (`alice.near`) accounts.
- Sync: latest block and gas price, `view_account` and NEP-141 balances over JSON-RPC with endpoint failover; history and the account's tokens from the [FastNEAR](https://docs.fastnear.com) indexer. An optional FastNEAR API key is sent to FastNEAR hosts only.
- Balance: `availableBalance` is the balance minus storage staking (none up to 770 bytes, NEP-448).
- Sending: Borsh-encoded transactions signed with Ed25519, submitted with `send_tx` and tracked from pending to final. Token transfers include the receiver's NEP-145 storage deposit when it is not registered yet. NEP-413 message signing.
- Fees: from the runtime config. `fee` is what a send finally costs; `requiredBalance` is what the account must hold up front, gas bought at no less than `min_gas_purchase_price`, plus the 0.007 NEAR charge when a transfer creates an implicit account.
- Storage: GRDB, one database per wallet id and account. State published with Combine.

## Usage

```swift
let signer = try Signer.instance(seed: seed)
let kit = try Kit.instance(
    accountId: signer.publicKey.implicitAccountId,
    network: .mainNet,
    rpcUrls: Network.mainNet.rpcUrls,
    walletId: "wallet-1"
)
kit.watchTokens(contractIds: ["usdt.tether-token.near"])
kit.start()

kit.availableBalancePublisher.sink { yocto in /* spendable NEAR */ }
kit.ftBalancesPublisher.sink { balances in /* contractId, balance in the token's smallest unit */ }
kit.transactionsPublisher(token: Kit.tokenNative).sink { changed in /* new or updated records */ }

let estimate = try await kit.estimateNearTransfer(receiverId: to)   // fee, requiredBalance
let max = try await kit.maxSendableNear(receiverId: to)
let tx = try await kit.sendNear(receiverId: to, amount: NearAmount.toYocto(near: 1.5)!, signer: signer)

let ftEstimate = try await kit.estimateFtTransfer(contractId: "usdt.tether-token.near", receiverId: to, amount: 1_000_000)
// show ftEstimate.storageDeposit to the user, then pass the confirmed estimate
let ftTx = try await kit.sendFt(contractId: "usdt.tether-token.near", receiverId: to, amount: 1_000_000, estimate: ftEstimate, signer: signer)
```

A watch-only wallet opens the kit with any account id and no signer.

Picking the account a restored phrase opens (the implicit one is always first):

```swift
let publicKey = try Signer.publicKey(seed: seed)
let accounts = try await Kit.findAccounts(publicKey: publicKey, network: .mainNet)
for accountId in accounts {
    let state = try await Kit.accountState(accountId: accountId, network: .mainNet)   // available, hasContract
    let keys = try await Kit.accessKeys(accountId: accountId, network: .mainNet)      // other keys on the account
}
let usable = try await Kit.hasFullAccess(accountId: "alice.near", publicKey: publicKey, network: .mainNet)
```

## License

MIT, see [LICENSE](LICENSE).
