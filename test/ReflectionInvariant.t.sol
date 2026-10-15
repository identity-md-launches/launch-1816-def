// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReflectionFixture} from "./helpers/ReflectionFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {ReflectionHook} from "../src/ReflectionHook.sol";
import {DEF} from "../src/DEF.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract ReflectionHandler is Test {
    ReflectionHook public immutable hook;
    PoolActor public immutable trader;
    address public immutable firstSink;
    address public immutable secondSink;
    uint256 public feesEarned;
    uint256 public feesPaid;
    uint256 public buys;
    uint256 public sells;
    uint256 public redemptions;

    constructor(ReflectionHook hook_, PoolActor trader_, address sinkA, address sinkB) {
        hook = hook_;
        trader = trader_;
        firstSink = sinkA;
        secondSink = sinkB;
    }

    function buy(uint96 input) external {
        uint256 amount = bound(input, 1, 100 ether);
        uint256 beforeClaims = hook.collected();
        BalanceDelta received =
            trader.swap(hook.poolKey(), SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1));
        uint256 claimed = hook.collected() - beforeClaims;
        uint256 gross = uint256(int256(received.amount1())) + claimed;
        feesEarned += gross * 225 / 10_000;
        ++buys;
    }

    function sell(uint96 input) external {
        uint256 amount = bound(input, 1, 100 ether);
        trader.swap(hook.poolKey(), SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1));
        feesEarned += amount * 225 / 10_000;
        ++sells;
    }

    function redeem(bool pull) external {
        uint256 expected = feesEarned - feesPaid;
        if (expected == 0) return;
        uint256 paid;
        if (pull) {
            address recipient = hook.sink();
            address def = address(hook.def());
            vm.prank(recipient);
            paid = hook.claim(def, recipient);
        } else {
            paid = hook.flush();
        }
        assertEq(paid, expected);
        feesPaid += paid;
        ++redemptions;
    }

    function moveSink(bool useFirst) external {
        address hookOwner = hook.owner();
        vm.prank(hookOwner);
        hook.setSink(useFirst ? firstSink : secondSink);
    }
}

contract ReflectionInvariantTest is ReflectionFixture {
    using TransientStateLibrary for IPoolManager;

    ReflectionHandler internal handler;
    uint256 internal initialEth;

    function setUp() public override {
        super.setUp();
        setSink(sink);
        handler = new ReflectionHandler(hook, trader, sink, other);
        initialEth = address(factory).balance + address(trader).balance + address(manager).balance;
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ReflectionHandler.buy.selector;
        selectors[1] = ReflectionHandler.sell.selector;
        selectors[2] = ReflectionHandler.redeem.selector;
        selectors[3] = ReflectionHandler.moveSink.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_claimsEqualFeesEarnedMinusRedeemed() public view {
        assertEq(hook.collected(), handler.feesEarned() - handler.feesPaid());
        assertEq(hook.collected(), manager.balanceOf(address(hook), uint256(uint160(address(token)))));
        assertEq(hook.claimable(hook.sink(), address(token)), hook.collected());
        assertEq(hook.claimable(owner, address(token)), 0);
        assertEq(hook.claimable(hook.sink(), address(0)), 0);
        assertEq(token.balanceOf(sink) + token.balanceOf(other), handler.feesPaid());
        assertLe(hook.collected(), token.balanceOf(address(manager)));
    }

    function invariant_defAndEthAreConserved() public view {
        uint256 total = token.balanceOf(address(this)) + token.balanceOf(address(factory))
            + token.balanceOf(address(trader)) + token.balanceOf(address(manager)) + token.balanceOf(sink)
            + token.balanceOf(other) + token.balanceOf(address(hook));
        assertEq(total, token.INITIAL_SUPPLY());
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        assertEq(address(factory).balance + address(trader).balance + address(manager).balance, initialEth);
        assertEq(sink.balance, 0);
        assertEq(other.balance, 0);
        assertNoEth();
    }

    function invariant_everyUnlockSettlesAllDeltas() public view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertFalse(pm.isUnlocked());
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0);
        assertEq(pm.currencyDelta(address(trader), key.currency0), 0);
        assertEq(pm.currencyDelta(address(trader), key.currency1), 0);
        assertTrue(hook.initialized());
        assertEq(hook.lpFee(), LP_FEE);
        assertEq(hook.owner(), owner);
        assertEq(hook.FEE_BPS(), 225);
    }
}
