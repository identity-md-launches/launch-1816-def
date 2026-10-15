// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DEF} from "../src/DEF.sol";
import {ReflectionHook} from "../src/ReflectionHook.sol";
import {HookAddress} from "../src/HookAddress.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline salt calculation only: no environment, RPC, wallet or broadcast is used.
contract MineReflectionHook {
    function run(
        address create2Deployer,
        IPoolManager manager,
        DEF token,
        address owner,
        address factory,
        uint256 start,
        uint256 count
    ) external pure returns (bytes32 salt, address predicted) {
        bytes32 hash = keccak256(
            abi.encodePacked(type(ReflectionHook).creationCode, abi.encode(manager, token, owner, factory))
        );
        return HookAddress.find(create2Deployer, hash, start, count);
    }
}
