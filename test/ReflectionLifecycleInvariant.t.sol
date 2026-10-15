// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReflectionFixture} from "./helpers/ReflectionFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {ReflectionSequenceHandler} from "./helpers/ReflectionSequenceHandler.sol";
import {ReflectionHook} from "../src/ReflectionHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Covers the unset -> set -> moved sink lifecycle alongside swaps and adversarial
/// calls. All assets come from the real fixed supply and the initial ETH allocation.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ReflectionLifecycleInvariantTest is ReflectionFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    ReflectionSequenceHandler internal handler;
    PoolActor[3] internal actors;
    address[3] internal sinks;
    uint256 internal totalEth;

    function setUp() public override {
        super.setUp();
        actors[0] = trader;
        for (uint256 i = 1; i < 3; ++i) {
            actors[i] = new PoolActor(manager);
            token.transfer(address(actors[i]), 1_000_000 ether);
            vm.deal(address(actors[i]), 1_000_000 ether);
        }
        sinks = [sink, other, makeAddr("third-sink")];
        totalEth = address(factory).balance + address(manager).balance;
        for (uint256 i; i < 3; ++i) {
            totalEth += address(actors[i]).balance;
        }
        handler = new ReflectionSequenceHandler(hook, factory, actors, sinks);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = ReflectionSequenceHandler.trade.selector;
        selectors[1] = ReflectionSequenceHandler.moveSink.selector;
        selectors[2] = ReflectionSequenceHandler.redeem.selector;
        selectors[3] = ReflectionSequenceHandler.rejectAdministrationOrClaim.selector;
        selectors[4] = ReflectionSequenceHandler.rejectSwap.selector;
        selectors[5] = ReflectionSequenceHandler.rejectLiquidity.selector;
        selectors[6] = ReflectionSequenceHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_pendingFeesAndEachSinkPayoutMatchIndependentGhosts() public view {
        assertEq(hook.collected() + handler.paid(), handler.earned());
        assertEq(hook.collected(), manager.balanceOf(address(hook), uint256(uint160(address(token)))));
        assertEq(hook.sink(), handler.expectedSink());
        uint256 sumPaid;
        for (uint256 i; i < 3; ++i) {
            uint256 expectedPaid = handler.paidTo(sinks[i]);
            assertEq(token.balanceOf(sinks[i]), expectedPaid, "only the sink at redemption may receive DEF");
            sumPaid += expectedPaid;
            uint256 expectedClaim = sinks[i] == handler.expectedSink() ? handler.earned() - handler.paid() : 0;
            assertEq(hook.claimable(sinks[i], address(token)), expectedClaim);
            assertEq(hook.claimable(sinks[i], address(0)), 0);
            assertEq(hook.claimable(address(actors[i]), address(token)), 0);
        }
        assertEq(sumPaid, handler.paid());
        assertLe(hook.collected(), token.balanceOf(address(manager)), "claims must remain fully backed");
    }

    function invariant_allDefAndEthStayWithTrackedParticipants() public view {
        uint256 defSum = token.balanceOf(address(this)) + token.balanceOf(address(factory))
            + token.balanceOf(address(manager)) + token.balanceOf(address(hook));
        uint256 ethSum = address(factory).balance + address(manager).balance;
        for (uint256 i; i < 3; ++i) {
            defSum += token.balanceOf(address(actors[i])) + token.balanceOf(sinks[i]);
            ethSum += address(actors[i]).balance;
            assertEq(sinks[i].balance, 0, "sinks only receive DEF");
        }
        assertEq(defSum, token.INITIAL_SUPPLY());
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        assertEq(ethSum, totalEth);
        assertEq(token.balanceOf(owner), 0);
        assertNoEth();
    }

    function invariant_poolAndHookRemainLockedAndSettled() public view {
        IPoolManager pm = IPoolManager(address(manager));
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(pm.currencyDelta(address(actors[i]), key.currency0), 0);
            assertEq(pm.currencyDelta(address(actors[i]), key.currency1), 0);
        }
        assertEq(pm.getLiquidity(key.toId()), LIQUIDITY, "hook must never modify launch liquidity");
        (,, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(key.toId());
        assertEq(protocolFee, 0);
        assertEq(lpFee, 0);
        assertTrue(hook.initialized());
        assertTrue(hook.liquiditySeeded());
        assertEq(hook.owner(), owner);
        assertEq(hook.FEE_BPS(), 225);
    }

    /// @dev At the end of every sequence, all independently accrued fees must be redeemable.
    /// This is an executable liveness check, including sequences that never set a sink.
    function afterInvariant() public {
        if (handler.expectedSink() == address(0)) handler.moveSink(0);
        handler.redeem(false, 0);
        assertEq(hook.collected(), 0);
        assertEq(handler.earned(), handler.paid());
        vm.expectRevert(ReflectionHook.NothingToFlush.selector);
        hook.flush();
        invariant_pendingFeesAndEachSinkPayoutMatchIndependentGhosts();
        invariant_allDefAndEthStayWithTrackedParticipants();
        invariant_poolAndHookRemainLockedAndSettled();
    }

    /// @dev Pins a non-vacuous replay across all three traders and sinks beside random sequences.
    function test_lifecycleReplayIncludesUnsetMovedEmptyAndRefilledClaims() public {
        handler.trade(0, uint96(100 ether + 1), true, false, 0);
        handler.redeem(false, 0); // Pending fees, sink unset.
        handler.rejectAdministrationOrClaim(0, 1);
        handler.moveSink(0);
        handler.trade(1, uint96(999 ether + 1), false, true, 1);
        handler.rejectSwap(1, false, true, uint96(1 ether));
        handler.rejectSwap(2, true, false, uint96(1 ether));
        handler.rejectLiquidity(1, true);
        handler.moveSink(1);
        handler.rejectAdministrationOrClaim(3, 2);
        handler.rejectAdministrationOrClaim(4, 0);
        handler.redeem(true, 1);
        handler.redeem(false, 2); // Empty after pulling.
        handler.donate(2, uint96(1 ether), uint96(2 ether));
        handler.trade(2, uint96(999 ether + 1), true, true, 1);
        handler.moveSink(2);
        handler.redeem(false, 0);
        assertEq(handler.successfulSwaps(), 3);
        assertGt(handler.partialFills(), 0);
        assertGt(handler.earned(), 0);
        assertGt(token.balanceOf(sinks[1]), 0);
        assertGt(token.balanceOf(sinks[2]), 0);
        assertEq(token.balanceOf(sinks[0]), 0, "old sink lost entitlement before any redemption");
        afterInvariant();
    }
}
