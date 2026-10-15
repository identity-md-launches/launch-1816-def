// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @notice Pure CREATE2 helpers. Use the actual deploying factory and final constructor arguments.
library HookAddress {
    error SaltNotFound();

    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        // A CREATE2 address is defined to be the low 160 bits of this hash.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function find(address deployer, bytes32 initCodeHash, uint256 start, uint256 count)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < count; ++i) {
            salt = bytes32(start + i);
            predicted = predict(deployer, salt, initCodeHash);
            if (HookFlags.matches(predicted, HookFlags.REFLECTION)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
