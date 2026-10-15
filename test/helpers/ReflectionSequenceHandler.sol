// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolActor} from "./PoolActor.sol";
import {DEF} from "../../src/DEF.sol";
import {ReflectionHook} from "../../src/ReflectionHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Bounded callers keep their original balances throughout the campaign: no deal/mint
/// inside an action. The fee oracle uses the manager's raw Swap event, never collected().
contract ReflectionSequenceHandler is Test {
    using StateLibrary for IPoolManager;

    bytes32 private constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant FEE = keccak256("ReflectionFee(address,bool,uint256)");
    IPoolManager public immutable manager;
    ReflectionHook public immutable hook;
    DEF public immutable token;
    PoolActor public immutable factory;
    PoolActor[3] public actors;
    address[3] public sinks;
    PoolKey private key;

    address public expectedSink;
    uint256 public earned;
    uint256 public paid;
    mapping(address => uint256) public paidTo;
    uint256 public successfulSwaps;
    uint256 public partialFills;
    uint256 public rejectedCalls;

    struct Observation {
        int128 eth;
        int128 def;
        uint256 swapIndex;
        uint256 feeIndex;
        uint256 emittedFee;
    }

    struct Balances {
        uint256 actorEth;
        uint256 actorDef;
        uint256 managerEth;
        uint256 managerDef;
        uint256 claims;
    }

    constructor(ReflectionHook hook_, PoolActor factory_, PoolActor[3] memory actors_, address[3] memory sinks_) {
        hook = hook_;
        token = hook_.def();
        manager = hook_.poolManager();
        factory = factory_;
        actors = actors_;
        sinks = sinks_;
        key = hook_.poolKey();
    }

    function trade(uint8 actorSeed, uint96 input, bool buy, bool limited, uint8 distance) external {
        PoolActor actor = actors[actorSeed % 3];
        // Mix sub-wei-fee inputs with meaningful amounts instead of discarding dust.
        uint256 amount = input % 4 == 0 ? bound(input, 1, 10_000) : bound(input, 1, 1_000 ether);
        uint160 limit = buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (limited) {
            (, int24 tick,,) = manager.getSlot0(key.toId());
            int24 steps = int24(int256(bound(distance, 1, 120)));
            limit = TickMath.getSqrtPriceAtTick(buy ? tick - steps : tick + steps + 1);
        }
        Balances memory before_ = Balances(
            address(actor).balance,
            token.balanceOf(address(actor)),
            address(manager).balance,
            token.balanceOf(address(manager)),
            hook.collected()
        );
        vm.recordLogs();
        BalanceDelta net = actor.swap(key, SwapParams(buy, -int256(amount), limit));
        Observation memory raw = observe(vm.getRecordedLogs(), address(actor), buy);
        uint256 basis = buy ? uint256(int256(raw.def)) : amount;
        uint256 fee = basis * 225 / 10_000;
        assertEq(raw.emittedFee, fee, "event must report the sole DEF fee");
        assertEq(net.amount0(), raw.eth, "no ETH fee in either direction");
        assertEq(int256(net.amount1()), int256(raw.def) - int256(fee));
        assertEq(hook.collected() - before_.claims, fee);
        assertEq(int256(address(actor).balance), int256(before_.actorEth) + int256(net.amount0()));
        assertEq(int256(token.balanceOf(address(actor))), int256(before_.actorDef) + int256(net.amount1()));
        assertEq(int256(address(manager).balance), int256(before_.managerEth) - int256(net.amount0()));
        assertEq(int256(token.balanceOf(address(manager))), int256(before_.managerDef) - int256(net.amount1()));
        uint256 used = uint256(-int256(buy ? net.amount0() : net.amount1()));
        assertLe(used, amount, "specified input is an upper bound, including sell fee");
        if (used < amount) ++partialFills;
        earned += fee;
        ++successfulSwaps;
    }

    function moveSink(uint8 seed) external {
        bytes32 beforePool = poolDigest();
        uint256 beforeClaims = hook.collected();
        expectedSink = sinks[seed % 3];
        address owner = hook.owner();
        vm.prank(owner);
        hook.setSink(expectedSink);
        assertEq(hook.sink(), expectedSink);
        assertEq(hook.collected(), beforeClaims, "moving the sink cannot redeem fees");
        assertEq(poolDigest(), beforePool, "setSink cannot touch the pool");
    }

    function redeem(bool pull, uint8 callerSeed) external {
        uint256 waiting = earned - paid;
        address caller = pull && expectedSink != address(0) ? expectedSink : address(actors[callerSeed % 3]);
        bytes memory callData = pull
            ? abi.encodeCall(ReflectionHook.claim, (address(token), expectedSink))
            : abi.encodeCall(ReflectionHook.flush, ());
        if (expectedSink == address(0) || waiting == 0) {
            bytes4 reason = expectedSink == address(0)
                ? (pull ? ReflectionHook.NotSink.selector : ReflectionHook.SinkNotSet.selector)
                : ReflectionHook.NothingToFlush.selector;
            rejectHookCall(caller, callData, reason);
            return;
        }
        bytes32 beforePool = poolDigest();
        uint256 balanceBefore = token.balanceOf(expectedSink);
        uint256 managerBefore = token.balanceOf(address(manager));
        vm.prank(caller);
        (bool ok, bytes memory result) = address(hook).call(callData);
        assertTrue(ok, "valid collection must remain live after any sequence");
        assertEq(abi.decode(result, (uint256)), waiting);
        assertEq(token.balanceOf(expectedSink) - balanceBefore, waiting);
        assertEq(managerBefore - token.balanceOf(address(manager)), waiting);
        assertEq(hook.collected(), 0);
        assertEq(poolDigest(), beforePool, "collection cannot swap or modify pool liquidity");
        paid += waiting;
        paidTo[expectedSink] += waiting;
    }

    function rejectAdministrationOrClaim(uint8 mode, uint8 actorSeed) external {
        address outsider = address(actors[actorSeed % 3]);
        mode %= 5;
        if (mode == 0) {
            rejectHookCall(
                outsider, abi.encodeCall(ReflectionHook.setSink, (sinks[0])), ReflectionHook.NotOwner.selector
            );
        } else if (mode == 1) {
            rejectHookCall(
                hook.owner(), abi.encodeCall(ReflectionHook.setSink, (address(0))), ReflectionHook.ZeroAddress.selector
            );
        } else if (mode == 2 || expectedSink == address(0)) {
            rejectHookCall(
                outsider,
                abi.encodeCall(ReflectionHook.claim, (address(token), expectedSink)),
                ReflectionHook.NotSink.selector
            );
        } else if (mode == 3) {
            rejectHookCall(
                expectedSink,
                abi.encodeCall(ReflectionHook.claim, (address(0), expectedSink)),
                ReflectionHook.WrongCurrency.selector
            );
        } else {
            rejectHookCall(
                expectedSink,
                abi.encodeCall(ReflectionHook.claim, (address(token), outsider)),
                ReflectionHook.NotSink.selector
            );
        }
    }

    function rejectSwap(uint8 actorSeed, bool buy, bool invalidLimit, uint96 input) external {
        PoolActor actor = actors[actorSeed % 3];
        uint256 amount = bound(input, 1, 1_000 ether);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        SwapParams memory swap = SwapParams(
            buy,
            invalidLimit ? -int256(amount) : int256(amount),
            invalidLimit ? price : (buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
        bytes memory expected = invalidLimit
            ? abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, price)
            : wrapped(IHooks.beforeSwap.selector, ReflectionHook.ExactOutputUnsupported.selector);
        bytes32 before_ = stateDigest();
        (bool ok, bytes memory reason) = address(actor).call(abi.encodeCall(PoolActor.swap, (key, swap)));
        assertFalse(ok);
        assertEq(reason, expected);
        assertEq(stateDigest(), before_, "failed swaps must roll back claims and all balances");
        ++rejectedCalls;
    }

    function rejectLiquidity(uint8 actorSeed, bool asFactory) external {
        PoolActor actor = asFactory ? factory : actors[actorSeed % 3];
        bytes32 before_ = stateDigest();
        ModifyLiquidityParams memory add = ModifyLiquidityParams(-887220, 887220, 1, bytes32(0));
        (bool ok, bytes memory reason) = address(actor).call(abi.encodeCall(PoolActor.modify, (key, add)));
        assertFalse(ok);
        assertEq(reason, wrapped(IHooks.beforeAddLiquidity.selector, ReflectionHook.LiquidityLocked.selector));
        assertEq(stateDigest(), before_, "liquidity lock must survive all sink and swap sequences");
        ++rejectedCalls;
    }

    function donate(uint8 actorSeed, uint96 input0, uint96 input1) external {
        uint256 beforeClaims = hook.collected();
        vm.recordLogs();
        actors[actorSeed % 3].donate(key, bound(input0, 0, 1 ether), bound(input1, 0, 1 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(hook) && logs[i].topics[0] == FEE, "donations have no hook fee");
        }
        assertEq(hook.collected(), beforeClaims);
    }

    function rejectHookCall(address caller, bytes memory callData, bytes4 expected) internal {
        bytes32 before_ = stateDigest();
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(hook).call(callData);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(expected));
        assertEq(stateDigest(), before_, "rejected calls must be side effect free");
        ++rejectedCalls;
    }

    function observe(Vm.Log[] memory logs, address actor, bool buy) internal view returns (Observation memory raw) {
        uint256 swaps;
        uint256 fees;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter == address(manager) && entry.topics[0] == SWAP) {
                assertEq(entry.topics[1], hook.poolId());
                assertEq(entry.topics[2], bytes32(uint256(uint160(actor))));
                (raw.eth, raw.def,,,,) = abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
                raw.swapIndex = i;
                ++swaps;
            } else if (entry.emitter == address(hook) && entry.topics[0] == FEE) {
                assertEq(entry.topics[1], bytes32(uint256(uint160(actor))), "fee attributed to actual router");
                bool direction;
                (direction, raw.emittedFee) = abi.decode(entry.data, (bool, uint256));
                assertEq(direction, buy);
                raw.feeIndex = i;
                ++fees;
            }
        }
        assertEq(swaps, 1, "hook must never execute another swap");
        assertEq(fees, 1, "one fee event, including dust rounding to zero");
        if (buy) assertGt(raw.feeIndex, raw.swapIndex, "buy fee comes after pool output");
        else assertLt(raw.feeIndex, raw.swapIndex, "sell fee comes before pool input");
    }

    function wrapped(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function poolDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 f0, uint256 f1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, f0, f1, manager.getLiquidity(key.toId())));
    }

    function stateDigest() internal view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                poolDigest(),
                hook.collected(),
                hook.sink(),
                hook.owner(),
                token.balanceOf(address(manager)),
                address(manager).balance,
                token.balanceOf(address(hook)),
                address(hook).balance,
                token.balanceOf(address(factory)),
                address(factory).balance
            )
        );
        for (uint256 i; i < 3; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    token.balanceOf(address(actors[i])),
                    address(actors[i]).balance,
                    token.balanceOf(sinks[i]),
                    sinks[i].balance
                )
            );
        }
    }
}
