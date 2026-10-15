// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DEF} from "../src/DEF.sol";
import {ReflectionHook} from "../src/ReflectionHook.sol";
import {HookAddress} from "../src/HookAddress.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MineReflectionHook} from "../script/MineReflectionHook.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract DeploymentTest is Test {
    // Empty addresses are deliberate test fixtures proving the constructor makes no external call.
    IPoolManager internal manager;
    DEF internal token;
    address internal owner;
    address internal factory;

    function setUp() public {
        manager = IPoolManager(makeAddr("manager-constructor-probe"));
        token = DEF(makeAddr("token-constructor-probe"));
        owner = makeAddr("explicit-owner");
        factory = makeAddr("factory-constructor-probe");
    }

    function test_miningScriptAndConstructorWorkOnEmptyChainWithExplicitOwner() public {
        MineReflectionHook miner = new MineReflectionHook();
        (bytes32 salt, address predicted) = miner.run(address(this), manager, token, owner, factory, 0, 200_000);
        ReflectionHook deployed = new ReflectionHook{salt: salt}(manager, token, owner, factory);
        assertEq(address(deployed), predicted);
        assertEq(deployed.owner(), owner);
        assertNotEq(deployed.owner(), address(this));
        assertEq(deployed.factory(), factory);
        assertEq(HookFlags.flagsOf(predicted), HookFlags.REFLECTION);
        assertEq(address(manager).code.length, 0);
        assertEq(address(token).code.length, 0);
    }

    function test_eachZeroConstructorArgumentReverts() public {
        vm.expectRevert(ReflectionHook.ZeroAddress.selector);
        new ReflectionHook(IPoolManager(address(0)), token, owner, factory);
        vm.expectRevert(ReflectionHook.ZeroAddress.selector);
        new ReflectionHook(manager, DEF(address(0)), owner, factory);
        vm.expectRevert(ReflectionHook.ZeroAddress.selector);
        new ReflectionHook(manager, token, address(0), factory);
        vm.expectRevert(ReflectionHook.ZeroAddress.selector);
        new ReflectionHook(manager, token, owner, address(0));
    }

    function test_wrongAddressPermissionBitsCannotDeploy() public {
        bytes32 hash =
            keccak256(abi.encodePacked(type(ReflectionHook).creationCode, abi.encode(manager, token, owner, factory)));
        bytes32 salt;
        address predicted = HookAddress.predict(address(this), salt, hash);
        while (HookFlags.matches(predicted, HookFlags.REFLECTION)) {
            salt = bytes32(uint256(salt) + 1);
            predicted = HookAddress.predict(address(this), salt, hash);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new ReflectionHook{salt: salt}(manager, token, owner, factory);
    }

    function test_boundedMiningFailureIsExplicit() public {
        MineReflectionHook miner = new MineReflectionHook();
        vm.expectRevert(HookAddress.SaltNotFound.selector);
        miner.run(address(this), manager, token, owner, factory, 0, 0);
    }
}
