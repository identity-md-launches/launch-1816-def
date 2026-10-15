# Local security review

Scope: `DEF`, `ReflectionHook`, the internal permission/address helpers, and the offline mining script. The supplied Ethereum and v4 security references were read as checklists; the explicit task defines the economics and administrative powers.

## Findings addressed by construction and tests

| Area | Implementation / evidence |
| --- | --- |
| Callback authentication | All ten IHooks callbacks and unlockCallback check the immutable manager first. Tests invoke every callback from an unauthorized caller. |
| Pool identity | Exact native ETH/DEF key, static LP fee zero, spacing 60 and this hook. Initialization and enabled trading/liquidity callbacks verify its hash. |
| Launch authority | Explicit immutable factory; one initialization and one initial addition. Reverts roll back state. The owner has no launch bypass. |
| Owner isolation | Explicit immutable owner argument, tested independently of deployer and factory; only setSink is privileged. |
| Address permissions | Constructor checks all 14 bits with upstream Hooks.validateHookPermissions. Tests deploy with actual CREATE2 and test incorrect flags. |
| Specified delta / NoOp risk | Sell delta is only floor(input × 225 / 10,000), always less than positive specified input. No arbitrary delta, router data, fee override or owner-selected rate exists. |
| Output delta | Buy fee is based only on actual positive DEF output. afterSwap returns zero on sells; beforeSwap returns zero on buys. |
| Arithmetic | FullMath.mulDiv avoids fee multiplication overflow. Checked SafeCast rejects fee deltas outside int128. The most negative int256 is handled without signed-negation overflow, then safely rejected if its fee is too large. |
| Rounding | Flooring occurs once per fee. Dust tests cover the 44/45-unit sell fee boundary; fuzz tests verify actual pool and recipient deltas. |
| Claim settlement | Mint debit is canceled by returned swap delta. Redemption burns first, then takes the same currency and amount to sink. Invariants check outstanding manager deltas are zero. |
| Redemption authorization | Anyone may trigger flush but cannot select recipient. Only sink may claim, only to itself, and only DEF. Old sink authority is revoked immediately on reassignment. |
| Reentrancy | The only production external calls are to the trusted immutable PoolManager. DEF is the supplied standard ERC-20 and has no transfer callback. unlockCallback requires both the manager and a pending redemption, consumes that pending flag before burn/take, and uses no arbitrary decoded values. PoolManager's lock rejects nested unlock. |
| Atomic failure | Failed swaps, invalid liquidity additions and nested redemption leave balances and claims unchanged; tested. |
| Fresh pool funding | Minting claims needs no preexisting ETH. Tested with a manager seeded with DEF only, then buy and redeem. |
| Liquidity lifecycle | No remove or donate permission is enabled. Those entry points also return no-op selectors/zero deltas if called by the manager. Factory zero-change collection, removal and donation are tested. |
| No escape hatches | No proxy, delegatecall, selfdestruct, arbitrary call, token/claim approval, operator approval or withdrawal besides sink redemption. Tests inspect runtime opcodes and reject common admin selectors. |
| Supply | OpenZeppelin ERC20; one mint of 10^27 units in constructor. No additional exposed mint/burn/admin code; transfer/allowance/failure tests and conservation invariants. |

## Trust and integration assumptions

- Constructor inputs must be the genuine manager and the newly deployed `DEF`. The constructor deliberately does not call contracts or inspect their code, allowing the required empty-chain construction check. A malicious manager or substitute token is outside the contract's deployment assumptions.
- The factory is trusted to provide the intended initial price/range/funding, initialize and seed atomically, and retain or remove its position according to launch policy. Initialization and addition are single-use. The hook never manages liquidity.
- The owner controls the recipient of all accrued and future fees by changing sink, including selecting themselves. The owner cannot change the fee or the pool. There is no ownership recovery or transfer.
- PoolManager's sender is a router/participant address, not a verified end-user. No permission decision depends on trading identity or untrusted hookData. A router allowlist is unnecessary and would violate the requested open trading behavior.
- Routers enforce minimum received output and refund unused input. Partial sells charge 225 bps of specified input even on an empty or partially executable range; this follows the requested beforeSwap rule. The hook does not promise every valid exact-input request produces output.
- Native ETH cannot be accepted by a normal call to the hook. Forced ETH and third-party claim transfers are outside the zero-balance guarantee of the hook's own operations. Direct token transfers cannot be rescued.
- Fee-source redemption opens a fresh manager unlock. A sink must call it outside another manager unlock. A failed transaction preserves its full pending balance.
- Solidity 0.8.26 and a Cancun-capable chain are required by the vendored PoolManager's transient storage implementation.

## Verification scope

The Foundry suite uses the task's fixed fuzz seed, 256 runs for each fuzz test, and 128 stateful runs of depth 32. Stateful actions buy, sell, redeem through either fee-source method, and move the sink. Invariants check fee claims against independently tracked accrual/redemption, actual sink receipts, total DEF conservation, ETH conservation, zero hook ETH/ETH claims, unchanged owner/rate and fully settled manager deltas.

Local review and real-PoolManager tests are included. The supplied protected files are admission harness inputs and depend on the verifier's separate probe/environment setup; they are not substituted with local mocks or claimed as executed here. A chain-specific launch rehearsal, explorer verification and an independent external review belong to the later launch process. Slither, Mythril, formal verification and a live-chain fork were not run in this assignment.
