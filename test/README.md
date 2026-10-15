# Reflection hook tests

The existing `ReflectionHook.t.sol`, `DEF.t.sol`, `Deployment.t.sol`, and
`ReflectionInvariant.t.sol` cover the launch specification and its required failure paths.

`ReflectionDifferential.t.sol` adds a second local Uniswap v4 PoolManager with an
identical pool (same 12500 LP fee tier) and no hook. For buys, the hooked pool must
match its ETH input and retain precisely the DEF output fee. For sells, it must match
a plain swap using the specified DEF input less the fee. Both pools must finish at the
same price, tick, liquidity and LP fee growth, so the hook demonstrably adds nothing
to the LP fee. Each differential property runs 1,000 cases, including price
limits that permit partial fills. Explicit cases cover fee rounding boundaries,
one wei, the trader's entire DEF balance, and rollback after failed settlement.

`ReflectionLifecycleInvariant.t.sol` drives the real PoolManager through 256 random
sequences of 64 actions. Three prefunded traders trade and donate while three sinks
are selected, claims are redeemed, and unauthorized operations are attempted. The
launch factory also adds to, removes from and fee-collects its full-range position
between trades, which must succeed without a reflection fee, while every other
actor's addition (full-range or concentrated) must revert `LiquidityLocked`.
Expected fees come from the manager's raw swap events. Ghost totals and individual
sink payouts are checked against claims, balances, conservation, liquidity equal to
the seed plus the factory's tracked additions, the unchanged LP fee and pool id,
and settled manager accounting. Collection must also succeed at the end of every
sequence. A deterministic replay ensures the partial-fill and sink migration paths
are exercised independently of random selection.

The handler bounds each trade to at most 1,000 DEF or ETH, mixes in dust amounts,
and bounds donations to one token per currency. Traders are funded once at setup;
actions never refill balances or mint supply. Expected reverts are checked for
their exact errors and unchanged pool state and participant balances.

Everything runs offline against the vendored v4 implementation; no RPC or new
dependency is required. Run:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x0966f9cefe6c08e2d6a61f30dfd807ed78a43914b40c2fe5498f63d9ce34b62f forge test
```
