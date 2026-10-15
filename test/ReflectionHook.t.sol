// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReflectionFixture} from "./helpers/ReflectionFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {DEF} from "../src/DEF.sol";
import {ReflectionHook} from "../src/ReflectionHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

contract ReflectionHookTest is ReflectionFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_launchConfigurationAndExactPermissions() public view {
        assertEq(token.name(), "DEF");
        assertEq(token.symbol(), "DEF");
        assertEq(address(hook.def()), address(token));
        assertEq(hook.owner(), owner);
        assertNotEq(hook.owner(), address(factory));
        assertEq(hook.factory(), address(factory));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.FEE_BPS(), 225);
        assertEq(hook.sink(), address(0));
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(key.fee, 0);
        assertEq(key.tickSpacing, 60);
        assertEq(address(key.hooks), address(hook));
        assertEq(hook.poolId(), PoolId.unwrap(key.toId()));
        assertTrue(hook.initialized());
        assertTrue(hook.liquiditySeeded());
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertFalse(
            p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(HookFlags.flagsOf(address(hook)), 0x28cc);
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
    }

    function test_buyChargesActualDefOutput() public {
        checkBuy(10 ether);
    }

    function testFuzz_buyChargesActualDefOutput(uint96 input) public {
        checkBuy(bound(input, 1, 100_000 ether));
    }

    function checkBuy(uint256 input) internal {
        uint256 traderDef = token.balanceOf(address(trader));
        uint256 traderEth = address(trader).balance;
        uint256 managerDef = token.balanceOf(address(manager));
        uint256 waiting = hook.collected();
        vm.recordLogs();
        BalanceDelta result = buy(input);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int128 rawEth, int128 rawDef) = readSwap(logs);
        uint256 produced = uint256(int256(rawDef));
        uint256 fee = produced * 225 / 10_000;
        assertEq(result.amount0(), rawEth);
        assertEq(-int256(result.amount0()), int256(input));
        assertEq(uint256(int256(result.amount1())), produced - fee);
        assertEq(token.balanceOf(address(trader)) - traderDef, produced - fee);
        assertEq(traderEth - address(trader).balance, input);
        assertEq(managerDef - token.balanceOf(address(manager)), produced - fee);
        assertEq(hook.collected() - waiting, fee);
        assertApproxEqAbs(produced - fee, produced * 9775 / 10_000, 1);
        assertFeeEvent(logs, true, fee);
        assertNoEth();
        assertSettled();
    }

    function test_sellChargesSpecifiedDefBeforeTheSwap() public {
        checkSell(10 ether);
    }

    function testFuzz_sellChargesSpecifiedDefBeforeTheSwap(uint96 input) public {
        checkSell(bound(input, 1, 100_000 ether));
    }

    function checkSell(uint256 input) internal {
        uint256 traderDef = token.balanceOf(address(trader));
        uint256 traderEth = address(trader).balance;
        uint256 managerDef = token.balanceOf(address(manager));
        uint256 waiting = hook.collected();
        vm.recordLogs();
        BalanceDelta result = sell(input);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int128 rawEth, int128 rawDef) = readSwap(logs);
        uint256 fee = input * 225 / 10_000;
        assertEq(-int256(rawDef), int256(input - fee), "pool only trades 97.75 percent");
        assertEq(-int256(result.amount1()), int256(input), "trader settles gross input");
        assertEq(result.amount0(), rawEth, "no ETH fee");
        assertEq(traderDef - token.balanceOf(address(trader)), input);
        assertEq(address(trader).balance - traderEth, uint256(int256(rawEth)));
        assertEq(token.balanceOf(address(manager)) - managerDef, input);
        assertEq(hook.collected() - waiting, fee);
        assertFeeEvent(logs, false, fee);
        assertNoEth();
        assertSettled();
    }

    function test_exactOutputBuyRevertsWithExactErrorAndNoFees() public {
        vm.expectRevert(hookError(IHooks.beforeSwap.selector, ReflectionHook.ExactOutputUnsupported.selector));
        trader.swap(key, params(true, 1 ether));
        assertEq(hook.collected(), 0);
    }

    function test_exactOutputSellRevertsWithExactErrorAndNoFees() public {
        vm.expectRevert(hookError(IHooks.beforeSwap.selector, ReflectionHook.ExactOutputUnsupported.selector));
        trader.swap(key, params(false, 1 ether));
        assertEq(hook.collected(), 0);
    }

    function test_flushRequiresSinkEvenWhenThereAreNoFees() public {
        vm.expectRevert(ReflectionHook.SinkNotSet.selector);
        hook.flush();
        buy(1 ether);
        uint256 waiting = hook.collected();
        vm.expectRevert(ReflectionHook.SinkNotSet.selector);
        hook.flush();
        assertEq(hook.collected(), waiting);
        assertNoEth();
    }

    function test_anyoneCanFlushAllDefClaimsOnlyToSink() public {
        buy(2 ether);
        sell(3 ether);
        setSink(sink);
        uint256 waiting = hook.collected();
        uint256 managerDef = token.balanceOf(address(manager));
        uint256 managerEth = address(manager).balance;
        vm.expectEmit(true, false, false, true, address(hook));
        emit ReflectionHook.Flushed(sink, waiting);
        vm.prank(other);
        uint256 paid = hook.flush();
        assertEq(paid, waiting);
        assertEq(token.balanceOf(sink), waiting);
        assertEq(token.balanceOf(other), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(managerDef - token.balanceOf(address(manager)), waiting);
        assertEq(address(manager).balance, managerEth);
        assertEq(hook.collected(), 0);
        vm.expectRevert(ReflectionHook.NothingToFlush.selector);
        hook.flush();
        assertNoEth();
        assertSettled();
    }

    function test_sinkCanPullDirectlyAndOnlyItsDefIsClaimable() public {
        setSink(sink);
        buy(2 ether);
        uint256 waiting = hook.collected();
        assertEq(hook.claimable(sink, address(token)), waiting);
        assertEq(hook.claimable(other, address(token)), 0);
        assertEq(hook.claimable(sink, address(0)), 0);
        assertEq(hook.claimable(sink, other), 0);
        vm.expectEmit(true, false, false, true, address(hook));
        emit ReflectionHook.Flushed(sink, waiting);
        vm.prank(sink);
        assertEq(hook.claim(address(token), sink), waiting);
        assertEq(token.balanceOf(sink), waiting);
        assertEq(hook.collected(), 0);
        assertEq(hook.claimable(sink, address(token)), 0);
        vm.prank(sink);
        vm.expectRevert(ReflectionHook.NothingToFlush.selector);
        hook.claim(address(token), sink);
        assertNoEth();
    }

    function test_claimRefusesNonSinkWrongRecipientAndWrongCurrency() public {
        setSink(sink);
        sell(1 ether);
        uint256 waiting = hook.collected();
        vm.prank(other);
        vm.expectRevert(ReflectionHook.NotSink.selector);
        hook.claim(address(token), sink);
        vm.prank(owner);
        vm.expectRevert(ReflectionHook.NotSink.selector);
        hook.claim(address(token), owner);
        vm.prank(sink);
        vm.expectRevert(ReflectionHook.NotSink.selector);
        hook.claim(address(token), other);
        vm.prank(sink);
        vm.expectRevert(ReflectionHook.NotSink.selector);
        hook.claim(address(token), address(0));
        vm.prank(sink);
        vm.expectRevert(ReflectionHook.WrongCurrency.selector);
        hook.claim(address(0), sink);
        vm.prank(sink);
        vm.expectRevert(ReflectionHook.WrongCurrency.selector);
        hook.claim(other, sink);
        assertEq(hook.collected(), waiting);
    }

    function test_unsetClaimCannotBeCalledAndClaimableFollowsExactAccountRule() public {
        buy(1 ether);
        assertEq(hook.claimable(sink, address(token)), 0);
        assertEq(hook.claimable(address(0), address(token)), hook.collected());
        vm.expectRevert(ReflectionHook.NotSink.selector);
        hook.claim(address(token), address(this));
    }

    function test_onlyOwnerSetsNonzeroSinkAndEmits() public {
        vm.prank(other);
        vm.expectRevert(ReflectionHook.NotOwner.selector);
        hook.setSink(sink);
        vm.prank(address(factory));
        vm.expectRevert(ReflectionHook.NotOwner.selector);
        hook.setSink(sink);
        vm.prank(owner);
        vm.expectRevert(ReflectionHook.ZeroAddress.selector);
        hook.setSink(address(0));
        vm.expectEmit(true, false, false, true, address(hook));
        emit ReflectionHook.SinkSet(sink);
        setSink(sink);
        assertEq(hook.sink(), sink);
    }

    function test_movingSinkMovesAllPendingClaimsAndRevokesOldSink() public {
        setSink(sink);
        buy(1 ether);
        uint256 waiting = hook.collected();
        setSink(other);
        assertEq(hook.claimable(sink, address(token)), 0);
        assertEq(hook.claimable(other, address(token)), waiting);
        vm.prank(sink);
        vm.expectRevert(ReflectionHook.NotSink.selector);
        hook.claim(address(token), sink);
        vm.prank(other);
        hook.claim(address(token), other);
        assertEq(token.balanceOf(other), waiting);
        assertEq(token.balanceOf(sink), 0);
        sell(1 ether);
        hook.flush();
        assertGt(token.balanceOf(other), waiting);
    }

    function test_allFurtherLiquidityAddsRevertIncludingFactoryAndOwner() public {
        ModifyLiquidityParams memory add = ModifyLiquidityParams(LOWER, UPPER, 1 ether, bytes32(0));
        bytes memory reason = hookError(IHooks.beforeAddLiquidity.selector, ReflectionHook.LiquidityLocked.selector);
        vm.expectRevert(reason);
        factory.modify(key, add);
        vm.expectRevert(reason);
        trader.modify(key, add);
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.LiquidityLocked.selector);
        hook.beforeAddLiquidity(owner, key, add, "");
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.LiquidityLocked.selector);
        hook.beforeAddLiquidity(address(hook), key, add, "");
    }

    function test_removalZeroLiquidityCollectAndDonationHaveNoHookFee() public {
        buy(1 ether);
        uint256 waiting = hook.collected();
        BalanceDelta collect = factory.modify(key, ModifyLiquidityParams(LOWER, UPPER, 0, bytes32(0)));
        assertEq(BalanceDelta.unwrap(collect), 0, "LP fee is zero");
        trader.donate(key, 1 ether, 2 ether);
        collect = factory.modify(key, ModifyLiquidityParams(LOWER, UPPER, 0, bytes32(0)));
        assertApproxEqAbs(uint256(int256(collect.amount0())), 1 ether, 1);
        assertApproxEqAbs(uint256(int256(collect.amount1())), 2 ether, 1);
        BalanceDelta removed = factory.modify(key, ModifyLiquidityParams(LOWER, UPPER, -1 ether, bytes32(0)));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(hook.collected(), waiting);
        assertNoEth();
    }

    function test_initializationCannotBeRepeatedOrUseAnotherPool() public {
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(factory), key, Q96);
        PoolKey memory wrong = key;
        wrong.fee = 12500;
        vm.expectRevert(hookError(IHooks.beforeInitialize.selector, ReflectionHook.WrongPool.selector));
        factory.initialize(wrong, Q96);
        wrong = key;
        wrong.tickSpacing = 120;
        vm.expectRevert(hookError(IHooks.beforeInitialize.selector, ReflectionHook.WrongPool.selector));
        factory.initialize(wrong, Q96);
    }

    function test_launchAuthorizationAndFailedSeedRollBack() public {
        ReflectionHook fresh = deployHook(manager, token, trader);
        PoolKey memory freshKey = fresh.poolKey();
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.NotLaunch.selector);
        fresh.beforeInitialize(other, freshKey, Q96);
        assertFalse(fresh.initialized());
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.LiquidityLocked.selector);
        fresh.beforeAddLiquidity(address(trader), freshKey, ModifyLiquidityParams(LOWER, UPPER, 1, bytes32(0)), "");
        trader.initialize(freshKey, Q96);
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.LiquidityLocked.selector);
        fresh.beforeAddLiquidity(other, freshKey, ModifyLiquidityParams(LOWER, UPPER, 1, bytes32(0)), "");
        assertFalse(fresh.liquiditySeeded());
        // Invalid ticks fail after beforeAddLiquidity; its one-use flag must revert too.
        vm.expectRevert();
        trader.modify(freshKey, ModifyLiquidityParams(1, 2, 1 ether, bytes32(0)));
        assertFalse(fresh.liquiditySeeded());
        trader.modify(freshKey, ModifyLiquidityParams(LOWER, UPPER, 1 ether, bytes32(0)));
        assertTrue(fresh.liquiditySeeded());
    }

    function test_allCallbacksRejectNonManager() public {
        ModifyLiquidityParams memory liq = ModifyLiquidityParams(LOWER, UPPER, 1, bytes32(0));
        SwapParams memory swap = params(true, -1 ether);
        BalanceDelta zero = BalanceDeltaLibrary.ZERO_DELTA;
        bytes[] memory calls = new bytes[](11);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (other, key, Q96));
        calls[1] = abi.encodeCall(IHooks.afterInitialize, (other, key, Q96, 0));
        calls[2] = abi.encodeCall(IHooks.beforeAddLiquidity, (other, key, liq, ""));
        calls[3] = abi.encodeCall(IHooks.afterAddLiquidity, (other, key, liq, zero, zero, ""));
        calls[4] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (other, key, liq, ""));
        calls[5] = abi.encodeCall(IHooks.afterRemoveLiquidity, (other, key, liq, zero, zero, ""));
        calls[6] = abi.encodeCall(IHooks.beforeSwap, (other, key, swap, ""));
        calls[7] = abi.encodeCall(IHooks.afterSwap, (other, key, swap, zero, ""));
        calls[8] = abi.encodeCall(IHooks.beforeDonate, (other, key, 1, 1, ""));
        calls[9] = abi.encodeCall(IHooks.afterDonate, (other, key, 1, 1, ""));
        calls[10] = abi.encodeCall(ReflectionHook.unlockCallback, (abi.encode(other, 1 ether)));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(ReflectionHook.NotPoolManager.selector));
        }
    }

    function test_unlockCallbackRequiresAPendingFlush() public {
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.NoPendingFlush.selector);
        hook.unlockCallback(abi.encode(other, 1 ether));
    }

    function test_feeCallbacksRejectWrongCurrencyKey() public {
        PoolKey memory wrong = key;
        wrong.currency1 = Currency.wrap(other);
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.WrongPool.selector);
        hook.beforeSwap(address(trader), wrong, params(false, -1 ether), "");
        vm.prank(address(manager));
        vm.expectRevert(ReflectionHook.WrongPool.selector);
        hook.afterSwap(address(trader), wrong, params(true, -1 ether), BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function test_failedSwapDoesNotLeaveMintedClaims() public {
        uint256 waiting = hook.collected();
        uint256 balance = token.balanceOf(address(trader));
        SwapParams memory invalid = SwapParams(false, -1 ether, Q96 - 1);
        vm.expectRevert();
        trader.swap(key, invalid);
        assertEq(hook.collected(), waiting);
        assertEq(token.balanceOf(address(trader)), balance);
        assertSettled();
    }

    function test_flushInsideExistingUnlockRevertsWithoutLosingClaims() public {
        setSink(sink);
        buy(1 ether);
        uint256 waiting = hook.collected();
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        trader.flushWhileUnlocked(key);
        assertEq(hook.collected(), waiting);
        assertEq(token.balanceOf(sink), 0);
        assertEq(hook.flush(), waiting);
    }

    function test_partialSellChargesTheSpecifiedAmountAndRefundsUnusedInput() public {
        uint256 specified = 100_000 ether;
        uint256 fee = specified * 225 / 10_000;
        uint256 beforeDef = token.balanceOf(address(trader));
        uint160 limit = TickMath.getSqrtPriceAtTick(60);
        vm.recordLogs();
        BalanceDelta result = trader.swap(key, SwapParams(false, -int256(specified), limit));
        (int128 rawEth, int128 rawDef) = readSwap(vm.getRecordedLogs());
        uint256 usedByPool = uint256(-int256(rawDef));
        assertLt(usedByPool, specified - fee);
        assertEq(uint256(-int256(result.amount1())), usedByPool + fee);
        assertEq(beforeDef - token.balanceOf(address(trader)), usedByPool + fee);
        assertEq(hook.collected(), fee);
        assertEq(result.amount0(), rawEth);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, limit);
        assertNoEth();
    }

    function test_partialBuyChargesOnlyActualOutput() public {
        uint256 beforeEth = address(trader).balance;
        vm.recordLogs();
        BalanceDelta result = trader.swap(key, SwapParams(true, -100_000 ether, TickMath.getSqrtPriceAtTick(-60)));
        (, int128 rawDef) = readSwap(vm.getRecordedLogs());
        uint256 produced = uint256(int256(rawDef));
        uint256 fee = produced * 225 / 10_000;
        assertLt(beforeEth - address(trader).balance, 100_000 ether);
        assertEq(uint256(int256(result.amount1())), produced - fee);
        assertEq(hook.collected(), fee);
        assertNoEth();
    }

    function test_buyOnFreshManagerSeededOnlyWithDef() public {
        PoolManager freshManager = new PoolManager(address(this));
        PoolActor freshFactory = new PoolActor(freshManager);
        PoolActor buyer = new PoolActor(freshManager);
        ReflectionHook freshHook = deployHook(freshManager, token, freshFactory);
        PoolKey memory freshKey = freshHook.poolKey();
        token.transfer(address(freshFactory), 1_000_000 ether);
        vm.deal(address(buyer), 10 ether);
        // At the upper tick, the initial position is entirely currency1 (DEF).
        freshFactory.initialize(freshKey, TickMath.getSqrtPriceAtTick(60));
        freshFactory.modify(freshKey, ModifyLiquidityParams(-60, 60, int256(uint256(LIQUIDITY)), bytes32(0)));
        assertEq(address(freshManager).balance, 0);
        assertGt(token.balanceOf(address(freshManager)), 0);
        BalanceDelta received = buyer.swap(freshKey, params(true, -1 ether));
        assertGt(received.amount1(), 0);
        assertGt(freshHook.collected(), 0);
        vm.prank(owner);
        freshHook.setSink(sink);
        uint256 waiting = freshHook.collected();
        assertEq(freshHook.flush(), waiting);
        assertEq(token.balanceOf(sink), waiting);
        assertEq(freshManager.balanceOf(address(freshHook), 0), 0);
        assertEq(address(freshHook).balance, 0);
    }

    function test_dustRoundingDoesNotOvercharge() public {
        checkSell(44);
        assertEq(hook.collected(), 0);
        checkSell(45);
        assertEq(hook.collected(), 1);
    }

    function test_hugeSellCannotTruncateFeeDelta() public {
        vm.prank(address(manager));
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        hook.beforeSwap(address(trader), key, params(false, type(int256).min), "");
        assertEq(hook.collected(), 0);
    }

    function test_directDefTransfersAreNotFeesAndCannotBeSwept() public {
        token.transfer(address(hook), 10 ether);
        setSink(sink);
        assertEq(hook.collected(), 0);
        vm.expectRevert(ReflectionHook.NothingToFlush.selector);
        hook.flush();
        buy(1 ether);
        uint256 waiting = hook.collected();
        hook.flush();
        assertEq(token.balanceOf(sink), waiting);
        assertEq(token.balanceOf(address(hook)), 10 ether);
    }

    function test_noAdminOrEtherEntryPoint() public {
        string[8] memory signatures = [
            "withdraw(address,uint256)",
            "sweep(address,address,uint256)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "setFee(uint256)",
            "upgradeTo(address)",
            "execute(address,bytes)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], owner, 1 ether));
            assertFalse(ok, signatures[i]);
        }
        vm.deal(address(this), 1 ether);
        (bool accepted,) = address(hook).call{value: 1}("");
        assertFalse(accepted);
        assertNoEth();
    }

    function test_runtimeIsSmallAndHasNoEscapeOpcodes() public view {
        bytes memory code = address(hook).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function assertSettled() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0);
        assertEq(pm.currencyDelta(address(trader), key.currency0), 0);
        assertEq(pm.currencyDelta(address(trader), key.currency1), 0);
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertFalse(pm.isUnlocked());
    }
}
