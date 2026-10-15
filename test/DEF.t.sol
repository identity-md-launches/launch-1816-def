// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DEF} from "../src/DEF.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DEFTest is Test {
    DEF internal token;
    address internal recipient;
    address internal spender;

    function setUp() public {
        token = new DEF();
        recipient = makeAddr("recipient");
        spender = makeAddr("spender");
    }

    function test_nameSupplyAndEntireAllocationToDeployer() public view {
        assertEq(token.name(), "DEF");
        assertEq(token.symbol(), "DEF");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.balanceOf(recipient), 0);
    }

    function testFuzz_transferConservesSupplyAndTakesNoFee(uint96 amount) public {
        amount = uint96(bound(amount, 0, token.totalSupply()));
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function test_allowanceAndTransferFrom() public {
        assertTrue(token.approve(spender, 5 ether));
        assertEq(token.allowance(address(this), spender), 5 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 3 ether));
        assertEq(token.balanceOf(recipient), 3 ether);
        assertEq(token.allowance(address(this), spender), 2 ether);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 2 ether, 3 ether)
        );
        token.transferFrom(address(this), recipient, 3 ether);
    }

    function test_invalidTransfersRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, recipient, 0, 1));
        token.transfer(spender, 1);
    }

    function test_noMintAdminUpgradeOrBurnEntryPoints() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], recipient, 1 ether);
            (bool deployerSucceeded,) = address(token).call(data);
            vm.prank(recipient);
            (bool otherSucceeded,) = address(token).call(data);
            assertFalse(deployerSucceeded);
            assertFalse(otherSucceeded);
        }
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        assertEq(token.balanceOf(recipient), 0);
    }
}
