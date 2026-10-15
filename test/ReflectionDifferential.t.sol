// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReflectionFixture} from "./helpers/ReflectionFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {ReflectionHook} from "../src/ReflectionHook.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev The oracle is another real v4 pool with the same price and liquidity, but no hook.
/// Buys must execute identically before the output fee; sells must execute identically
/// to a plain swap of the input less the fee. Neither oracle uses collected() or fee logs.
contract ReflectionDifferentialTest is ReflectionFixture {
    using StateLibrary for IPoolManager;

    PoolManager internal plainManager;
    PoolActor internal plainFactory;
    PoolActor internal plainTrader;
    PoolKey internal plainKey;

    function setUp() public override {
        super.setUp();
        plainManager = new PoolManager(address(this));
        plainFactory = new PoolActor(plainManager);
        plainTrader = new PoolActor(plainManager);
        plainKey = key;
        plainKey.hooks = IHooks(address(0));
        token.transfer(address(plainFactory), 10_000_000 ether);
        token.transfer(address(plainTrader), 10_000_000 ether);
        vm.deal(address(plainFactory), 10_000_000 ether);
        vm.deal(address(plainTrader), 10_000_000 ether);
        plainFactory.initialize(plainKey, Q96);
        plainFactory.modify(plainKey, ModifyLiquidityParams(LOWER, UPPER, int256(uint256(LIQUIDITY)), bytes32(0)));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_buyMatchesPlainPoolBeforeDefFee(uint96 input, bool limited, uint8 distance) public {
        checkBuyAgainstPlainPool(bound(input, 1, 1_000_000 ether), limited, distance);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_sellMatchesPlainPoolWithNetInput(uint96 input, bool limited, uint8 distance) public {
        checkSellAgainstPlainPool(bound(input, 1, 10_000_000 ether), limited, distance);
    }

    function test_buyOneWeiAndSellEntireTraderBalance() public {
        checkBuyAgainstPlainPool(1, false, 0);
        // The one wei buy produces no DEF in either pool; the full balance is unchanged.
        checkSellAgainstPlainPool(token.balanceOf(address(trader)), false, 0);
        assertEq(token.balanceOf(address(trader)), 0);
    }

    function test_sellFeeRoundingBoundariesMatchPlainPool() public {
        uint256[9] memory amounts = [uint256(1), 44, 45, 88, 89, 399, 400, 401, 10_000];
        for (uint256 i; i < amounts.length; ++i) {
            checkSellAgainstPlainPool(amounts[i], false, 0);
        }
    }

    function checkBuyAgainstPlainPool(uint256 amount, bool limited, uint8 distance) internal {
        uint160 limit = limited
            ? TickMath.getSqrtPriceAtTick(-int24(int256(bound(distance, 1, 120))))
            : TickMath.MIN_SQRT_PRICE + 1;
        SwapParams memory swap = SwapParams(true, -int256(amount), limit);
        BalanceDelta plain = plainTrader.swap(plainKey, swap);
        uint256 waiting = hook.collected();
        uint256 tokensBefore = token.balanceOf(address(trader));
        uint256 ethBefore = address(trader).balance;
        BalanceDelta taxed = trader.swap(key, swap);
        uint256 gross = uint256(int256(plain.amount1()));
        uint256 fee = gross * 225 / 10_000;
        assertEq(taxed.amount0(), plain.amount0(), "buy must not charge ETH");
        assertEq(uint256(int256(taxed.amount1())) + fee, gross, "net DEF plus fee equals plain output");
        assertEq(token.balanceOf(address(trader)) - tokensBefore, gross - fee);
        assertEq(ethBefore - address(trader).balance, uint256(-int256(plain.amount0())));
        assertEq(hook.collected() - waiting, fee);
        assertApproxEqAbs(uint256(int256(taxed.amount1())), gross * 9775 / 10_000, 1);
        assertSamePoolState();
        assertNoEth();
    }

    function checkSellAgainstPlainPool(uint256 amount, bool limited, uint8 distance) internal {
        uint256 fee = amount * 225 / 10_000;
        uint160 limit =
            limited ? TickMath.getSqrtPriceAtTick(int24(int256(bound(distance, 1, 120)))) : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta plain = plainTrader.swap(plainKey, SwapParams(false, -int256(amount - fee), limit));
        uint256 waiting = hook.collected();
        uint256 tokensBefore = token.balanceOf(address(trader));
        uint256 ethBefore = address(trader).balance;
        BalanceDelta taxed = trader.swap(key, SwapParams(false, -int256(amount), limit));
        assertEq(taxed.amount0(), plain.amount0(), "only net DEF enters the swap");
        assertEq(int256(taxed.amount1()) + int256(fee), int256(plain.amount1()));
        assertEq(tokensBefore - token.balanceOf(address(trader)), uint256(-int256(plain.amount1())) + fee);
        assertEq(address(trader).balance - ethBefore, uint256(int256(plain.amount0())), "all ETH goes to seller");
        assertEq(hook.collected() - waiting, fee);
        assertSamePoolState();
        assertNoEth();
    }

    function assertSamePoolState() internal view {
        IPoolManager taxed = IPoolManager(address(manager));
        IPoolManager plain = IPoolManager(address(plainManager));
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = taxed.getSlot0(key.toId());
        (uint160 plainPrice, int24 plainTick, uint24 plainProtocolFee, uint24 plainLpFee) =
            plain.getSlot0(plainKey.toId());
        assertEq(price, plainPrice, "hook cannot alter pool price beyond the stated fee");
        assertEq(tick, plainTick);
        assertEq(protocolFee, plainProtocolFee);
        assertEq(lpFee, plainLpFee);
        assertEq(taxed.getLiquidity(key.toId()), plain.getLiquidity(plainKey.toId()));
        (uint256 f0, uint256 f1) = taxed.getFeeGrowthGlobals(key.toId());
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function test_insufficientDefSettlementRollsBackSellFeeAndPoolState() public {
        sell(1 ether);
        uint256 waiting = hook.collected();
        uint256 balance = token.balanceOf(address(trader));
        uint256 managerDef = token.balanceOf(address(manager));
        (uint160 price, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(trader), balance, balance + 1
            )
        );
        sell(balance + 1);
        (uint160 afterPrice, int24 afterTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(afterPrice, price);
        assertEq(afterTick, tick);
        assertEq(hook.collected(), waiting, "fee mint must roll back when the router cannot pay");
        assertEq(token.balanceOf(address(trader)), balance);
        assertEq(token.balanceOf(address(manager)), managerDef);
        setSink(sink);
        assertEq(hook.flush(), waiting, "failed settlement must not poison later collection");
        assertNoEth();
    }
}
