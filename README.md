# DEF reflection hook

DEF is a standard ERC-20 named **DEF**, symbol **DEF**, with 18 decimals and a fixed supply of **1,000,000,000 DEF** (`10^27` units). Its constructor takes no arguments and mints the entire supply to its deployer, the launch factory. It has no owner, transfer tax, later minting, pause, blocklist or upgrade mechanism.

`ReflectionHook` charges **225 basis points (2.25%) in DEF only** on one Uniswap v4 native ETH/DEF pool. It stores fees as PoolManager ERC-6909 claims. It never calls swap or modifyLiquidity, accepts ETH, approves an operator, or transfers assets to its owner. The owner's sole administrative function is `setSink(address)`.

The explicit assignment controls the economics: the pool's **LP fee is 0**, its tick spacing is **60**, and the reflection fee is in **DEF**. The conflicting 1.25% LP fee / ETH collection defaults in the background reference are not implemented.

## Build and test

From this repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x0966f9cefe6c08e2d6a61f30dfd807ed78a43914b40c2fe5498f63d9ce34b62f forge test
forge fmt --check
```

Foundry pins Solidity **0.8.26**, EVM **Cancun**, optimizer 200 runs and `bytecode_hash = "none"`. The fuzz seed is also pinned in `foundry.toml`. All Solidity dependencies are vendored as ordinary source files under `lib/`; there are no submodules, npm installs or runtime network dependencies. With the compiler installed, `forge build --offline` and `forge test --offline` need no network. No FFI or filesystem permissions are enabled.

Tests deploy the real v4 `PoolManager` and CREATE2-mine the actual hook, without overriding permission checks or mocking settlement. They cover the requested eight behaviors, output/input accounting against the manager's `Swap` event, dust, price-limit partial fills, token-only pool seeding, rollback on failure, all callback caller checks, initialization restrictions, removals and donations, fixed supply, constructor checks, permission mining and the absence of administrative escape paths. Stateful invariants interleave buys, sells, flushes, claims and sink changes, checking conservation, redemption accounting and zero outstanding deltas.

## Swap accounting

The pool key is always `(native ETH, DEF, 0, 60, this hook)`. Native ETH is `currency0 = address(0)`; DEF is `currency1`. `poolId()` is the Uniswap v4 hash of that key, available before initialization.

| Trade | Fee basis | Claim and delta | Result |
| --- | --- | --- | --- |
| Buy, exact ETH input | Actual DEF output from the pool | `afterSwap`: mint a DEF claim and return positive `int128(fee)` | Buyer receives pool output minus fee; ETH input is unchanged |
| Sell, exact DEF input | Full specified DEF input | `beforeSwap`: mint a DEF claim and return `toBeforeSwapDelta(fee, 0)` | Pool trades specified input minus fee; trader settles pool input plus fee |

Every fee is `floor(defAmount * 225 / 10_000)`. Rounding favors the trader by less than one DEF base unit. A `ReflectionFee(swapper, buy, fee)` event is emitted once per supported swap, including swaps whose rounded fee is zero. `swapper` is the immediate caller of PoolManager (usually a router). The hook ignores `hookData` and does not claim to authenticate an end-user address.

Exact-output swaps in either direction revert with `ExactOutputUnsupported()`. When reached through PoolManager, v4 wraps the hook error in `WrappedError(..., HookCallFailed())`; tests check the complete wrapped error. Direct callback calls from anyone except PoolManager revert `NotPoolManager()`.

**Partial fills:** buys pay only on actual DEF output. Sells pay on the full specified input, as required, even if a price limit or exhausted liquidity prevents all remaining input from trading. The unused pool input is not owed, but the upfront fee is not refunded. A sell with no executable liquidity can consequently still owe its specified-input fee. Routers must enforce a minimum output, settle the returned deltas, and refund unused input. This project supplies a hook, not a production swap router.

The manager's mint creates a negative transient DEF delta for the hook. The positive returned hook delta cancels it. On redemption, burning claims creates a positive DEF delta and `take` cancels it. The hook never creates an ETH delta or ETH claim. Its ordinary ETH and DEF token balances remain zero throughout swaps and redemption to an external sink.

## Deployment parameters and launch sequence

Only `DEF` and `ReflectionHook` are application contracts to deploy. `HookFlags` and `HookAddress` contain internal, inlined library functions. `MineReflectionHook` is an offline calculation script, and everything in `test/` is test scaffolding.

`ReflectionHook(IPoolManager manager_, DEF def_, address owner_, address factory_)` takes four immutable arguments:

| Argument | Launch input | Responsibility |
| --- | --- | --- |
| `manager_` | `$poolManager` | Deployer supplies the chain's canonical Uniswap v4 PoolManager |
| `def_` | `$token` | Address of the newly deployed DEF token |
| `owner_` | `$owner` | Explicit launch owner, never inferred from `msg.sender` or `tx.origin` |
| `factory_` | `$factory` | Factory that calls PoolManager.initialize and owns the initial position |

The launch context identifies Sepolia (11155111) and owner `0x66636a1a49df6480750905ee42a9c30993c05968`. These are deployment inputs, not hardcoded contract addresses. The constructor checks all four arguments for zero, makes no external calls and does not require code at argument addresses. The deployer must verify the actual manager and token before initialization. No signer, oracle, backend, external service account or key is required by the contracts.

1. The launch factory deploys `DEF` and handles the launch allocations. This code gives no initial allocation to the hook or sink. The reference allocation policy (87% pool, 10% distributor, 3% payer/treasury) remains the factory's responsibility.
2. With the final token address and constructor arguments, mine a CREATE2 salt using the **actual CREATE2 deployer's address** and final compiled initcode. The low 14 address bits must equal **`0x28cc` (10444)**. Enabled flags are exactly beforeInitialize, beforeAddLiquidity, beforeSwap, afterSwap, beforeSwapReturnDelta and afterSwapReturnDelta.
3. `MineReflectionHook.run(create2Deployer, manager, token, owner, factory, start, count)` returns a salt and predicted address without reading the environment, contacting a network or broadcasting. Search in bounded batches (for example, 200,000 salts). Continue from a new `start` if it raises `SaltNotFound()`. Salt mining is an off-chain operation; do not pay to run the search on-chain. Deployment tests invoke this exact function and then CREATE2-deploy the result.
4. Deploy the hook with that salt. The constructor rejects mismatching permission bits. A different compiler setting, argument, token address or deployer changes the address and requires mining again.
5. The configured factory calls `PoolManager.initialize(hook.poolKey(), openingSqrtPriceX96)`, then seeds **one positive liquidity addition** through its own unlock callback. It should deploy, initialize and seed atomically. The opening price, tick range, liquidity amount and settlement funding are launch-factory inputs; the hook does not choose them. The supplied launch context assigns the opening valuation to the deployer. The 1:1 price in local tests is a test fixture, not a production price instruction.
6. Initialization accepts only the configured factory (or the hook itself), only the exact key, and only once. The first positive liquidity addition is similarly restricted and consumes the one-use allowance. Every later positive addition reverts `LiquidityLocked()`, including factory additions. There is no owner override or reopen function. Failed initialization or liquidity settlement rolls back these flags.

The factory must add through its own address, not an unrelated position-manager router. Multiple seed positions are not supported. Removals, zero-liquidity fee collection and donations are unrestricted by the hook and carry no reflection charge. The initial LP position belongs to the factory; **the hook does not lock its withdrawal**. A full withdrawal cannot be followed by a new addition.

The launch's separate manifest step supplies deployment values; no `launch.json` is authored here. This repository performs no deployment or broadcast.

## After launch

The owner calls **`setSink(actualRecipient)`** with the address of the intended fee recipient or fee-consuming contract. This is the only post-launch configuration. The owner obtains and verifies that address from their intended recipient; no recipient is invented here. Zero is rejected with `ZeroAddress()` and every successful change emits `SinkSet(sink)`. Ownership is immutable and cannot be transferred or renounced.

Fees accrue before the sink is set. `flush()` then reverts `SinkNotSet()`. Once configured:

| Function | Caller | Behavior |
| --- | --- | --- |
| `collected()` | Anyone | Actual PoolManager DEF claim balance owned by the hook |
| `flush()` | Anyone | Unlock, burn the whole DEF claim balance, take exactly that much DEF to the current sink; emit `Flushed` and return the amount |
| `claimable(account, currency)` | Anyone | `collected()` if account equals sink and currency equals DEF, otherwise zero |
| `claim(currency, to)` | Current sink only | Same redemption; `to` must equal sink (`NotSink()` otherwise), currency must equal DEF (`WrongCurrency()` otherwise) |

With no fees waiting, redemption reverts `NothingToFlush()`. The sink can pull directly without a keeper. For an EOA sink, anyone may flush; a contract sink must call `claim(DEF, itself)` to pull. DEF is an ordinary ERC-20, so receiving fees needs no ETH receiver or token callback.

Changing sink redirects **all pending and future fees** immediately and revokes the previous sink's claim permission. The owner can select themselves as sink; consequently owner control over the fee recipient is a trust assumption. There is no other withdrawal, sweep, arbitrary-call, rate-change, pause, blocklist or upgrade path.

Call redemption while PoolManager is locked (outside another active `unlock`); nested unlocks revert atomically and leave claims intact. Redemption's callback accepts only PoolManager and only during a requested flush; caller-supplied callback bytes cannot select an amount or recipient.

The owner should select a recipient that can actually use DEF, rather than the hook or manager. Direct ERC-20 transfers to the hook are **not** fee claims and cannot be rescued. `claimable(address(0), DEF)` reports the claim balance before sink configuration under the exact address-equality rule, but no normal caller can redeem as the zero address. The no-ETH property covers this contract's execution paths: EVM-forced ETH or unsolicited ERC-6909 transfers cannot be prevented, and there is deliberately no recovery mechanism for unrelated assets.

## Dependencies and review

Exact commits and downloaded archive SHA-256 hashes are in [DEPENDENCIES.json](DEPENDENCIES.json). Vendored files are unmodified upstream source subsets with upstream licenses:

- [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/59d3ecf53afa9264a16bba0e38f4c5d2231f80bc), npm release 1.0.2: core source; MIT/BUSL-1.1 as identified per file.
- [OpenZeppelin Contracts 5.2.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527): ERC-20 and its import closure; MIT.
- [forge-std 1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505): test support; MIT/Apache-2.0.
- [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647): `Owned`, used by the real PoolManager in tests; AGPL-3.0-only as marked in its source.

[docs/SECURITY.md](docs/SECURITY.md) records the local review and operational assumptions. Local tests are not the independent review or chain-specific factory rehearsal performed by the launch pipeline.
