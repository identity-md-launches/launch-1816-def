// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ReflectionHook} from "../../src/ReflectionHook.sol";

/// @dev Prefunded test-only pool participant. Never a production router or factory.
contract PoolActor is IUnlockCallback {
    IPoolManager public immutable manager;

    enum Action {
        Swap,
        Modify,
        Donate,
        FlushWhileUnlocked
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "CREATE2 failed");
    }

    function initialize(PoolKey memory key, uint160 price) external {
        manager.initialize(key, price);
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(Action.Swap, key, abi.encode(params))), (BalanceDelta));
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(Action.Modify, key, abi.encode(params))), (BalanceDelta));
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        manager.unlock(abi.encode(Action.Donate, key, abi.encode(amount0, amount1)));
    }

    function flushWhileUnlocked(PoolKey memory key) external {
        manager.unlock(abi.encode(Action.FlushWhileUnlocked, key, bytes("")));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (Action action, PoolKey memory key, bytes memory args) = abi.decode(data, (Action, PoolKey, bytes));
        BalanceDelta delta;
        if (action == Action.Swap) {
            delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        } else if (action == Action.Modify) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        } else if (action == Action.Donate) {
            (uint256 a0, uint256 a1) = abi.decode(args, (uint256, uint256));
            delta = manager.donate(key, a0, a1, "");
        } else {
            ReflectionHook(address(key.hooks)).flush();
        }
        settle(key.currency0, delta.amount0());
        settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount), "transfer failed");
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }

    receive() external payable {}
}
