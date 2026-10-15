// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DEF} from "../../src/DEF.sol";
import {ReflectionHook} from "../../src/ReflectionHook.sol";
import {HookAddress} from "../../src/HookAddress.sol";
import {PoolActor} from "./PoolActor.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

abstract contract ReflectionFixture is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint128 internal constant LIQUIDITY = 1_000_000 ether;
    int24 internal constant LOWER = -887220;
    int24 internal constant UPPER = 887220;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant FEE_EVENT = keccak256("ReflectionFee(address,bool,uint256)");

    PoolManager internal manager;
    DEF internal token;
    ReflectionHook internal hook;
    PoolActor internal factory;
    PoolActor internal trader;
    PoolKey internal key;
    address internal owner;
    address internal sink;
    address internal other;

    function setUp() public virtual {
        owner = makeAddr("owner");
        sink = makeAddr("sink");
        other = makeAddr("other");
        manager = new PoolManager(address(this));
        token = new DEF();
        factory = new PoolActor(manager);
        trader = new PoolActor(manager);
        hook = deployHook(manager, token, factory);
        key = hook.poolKey();
        token.transfer(address(factory), 10_000_000 ether);
        token.transfer(address(trader), 10_000_000 ether);
        vm.deal(address(factory), 10_000_000 ether);
        vm.deal(address(trader), 10_000_000 ether);
        factory.initialize(key, Q96);
        factory.modify(key, ModifyLiquidityParams(LOWER, UPPER, int256(uint256(LIQUIDITY)), bytes32(0)));
    }

    function deployHook(IPoolManager pm, DEF def, PoolActor deployer) internal returns (ReflectionHook deployed) {
        bytes memory code =
            abi.encodePacked(type(ReflectionHook).creationCode, abi.encode(pm, def, owner, address(deployer)));
        (bytes32 salt, address predicted) = HookAddress.find(address(deployer), keccak256(code), 0, 200_000);
        deployed = ReflectionHook(deployer.deploy(code, salt));
        assertEq(address(deployed), predicted);
    }

    function params(bool isBuy, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(isBuy, amount, isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function buy(uint256 amount) internal returns (BalanceDelta) {
        return trader.swap(key, params(true, -int256(amount)));
    }

    function sell(uint256 amount) internal returns (BalanceDelta) {
        return trader.swap(key, params(false, -int256(amount)));
    }

    function setSink(address recipient) internal {
        vm.prank(owner);
        hook.setSink(recipient);
    }

    function assertNoEth() internal view {
        assertEq(address(hook).balance, 0, "hook holds native ETH");
        assertEq(manager.balanceOf(address(hook), 0), 0, "hook holds ETH claims");
        assertEq(token.balanceOf(address(hook)), 0, "fees should remain claims");
    }

    function hookError(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function readSwap(Vm.Log[] memory logs) internal view returns (int128 a0, int128 a1) {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                assertEq(logs[i].topics[1], hook.poolId());
                (a0, a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++found;
            }
        }
        assertEq(found, 1, "must observe a real pool swap");
    }

    function assertFeeEvent(Vm.Log[] memory logs, bool isBuy, uint256 expected) internal view {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEE_EVENT) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(trader)))));
                (bool wasBuy, uint256 fee) = abi.decode(logs[i].data, (bool, uint256));
                assertEq(wasBuy, isBuy);
                assertEq(fee, expected);
                ++found;
            }
        }
        assertEq(found, 1, "exactly one reflection fee per swap");
    }
}
