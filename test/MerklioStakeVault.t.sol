// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MerklioStakeVault} from "../src/MerklioStakeVault.sol";
import {MerklioStateReceiver} from "../src/MerklioStateReceiver.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {MockCCIPRouter} from "./mocks/MockCCIPRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev V2 impl to exercise the UUPS upgrade path.
contract MerklioStakeVaultV2 is MerklioStakeVault {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MerklioStakeVaultTest is Test {
    MerklioStakeVault vault;
    MerklioStateReceiver receiver;
    MockCCIPRouter router;
    MockERC20 asset;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address rewarder = makeAddr("rewarder");

    uint64 constant DEST_SEL = 2;
    uint64 constant INTERVAL = 1 days;

    function setUp() public {
        asset = new MockERC20();
        router = new MockCCIPRouter();
        receiver = new MerklioStateReceiver(address(router), owner);

        MerklioStakeVault impl = new MerklioStakeVault();
        bytes memory init = abi.encodeCall(
            MerklioStakeVault.initialize,
            (IERC20(address(asset)), owner, IRouterClient(address(router)), DEST_SEL, address(receiver), INTERVAL)
        );
        vault = MerklioStakeVault(payable(address(new ERC1967Proxy(address(impl), init))));

        vm.startPrank(owner);
        vault.setRewarder(rewarder, true);
        // allow the vault (source selector 1 from mock) to update the receiver
        receiver.setAllowedSender(router.sourceChainSelector(), address(vault), true);
        vm.stopPrank();

        asset.mint(alice, 1_000 ether);
        asset.mint(bob, 1_000 ether);
        asset.mint(rewarder, 1_000 ether);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.startPrank(who);
        asset.approve(address(vault), amt);
        shares = vault.deposit(amt);
        vm.stopPrank();
    }

    // ───────────────── staking ─────────────────

    function test_FirstDepositMintsOneToOne() public {
        uint256 shares = _deposit(alice, 100 ether);
        assertEq(shares, 100 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.totalPooled(), 100 ether);
        assertEq(asset.balanceOf(address(vault)), 100 ether);
    }

    function test_WithdrawReturnsAssets() public {
        _deposit(alice, 100 ether);
        vm.prank(alice);
        uint256 got = vault.withdraw(40 ether);
        assertEq(got, 40 ether);
        assertEq(vault.balanceOf(alice), 60 ether);
        assertEq(vault.totalPooled(), 60 ether);
    }

    function test_RewardReleaseLiftsSharePrice() public {
        _deposit(alice, 100 ether); // 100 shares, price 1.0

        vm.startPrank(rewarder);
        asset.approve(address(vault), 50 ether);
        vault.fundRewards(50 ether);
        vm.stopPrank();

        // still buffered: price unchanged until released
        assertEq(vault.previewRedeem(100 ether), 100 ether);
        assertEq(vault.rewardBuffer(), 50 ether);

        vm.warp(block.timestamp + INTERVAL);
        vault.performUpkeep("");

        // 150 pooled / 100 shares -> alice's 100 shares now redeem 150
        assertEq(vault.rewardBuffer(), 0);
        assertEq(vault.totalPooled(), 150 ether);
        assertEq(vault.previewRedeem(100 ether), 150 ether);
    }

    function test_SecondDepositorPaysPostRewardPrice() public {
        _deposit(alice, 100 ether);
        vm.startPrank(rewarder);
        asset.approve(address(vault), 100 ether);
        vault.fundRewards(100 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + INTERVAL);
        vault.performUpkeep(""); // price now 2.0 (200 pooled / 100 shares)

        uint256 shares = _deposit(bob, 100 ether); // should get ~50 shares
        assertEq(shares, 50 ether);
        assertApproxEqAbs(vault.previewRedeem(shares), 100 ether, 1);
    }

    // ───────────────── roles / gating ─────────────────

    function test_FundRewards_NonRewarderReverts() public {
        vm.startPrank(alice);
        asset.approve(address(vault), 10 ether);
        vm.expectRevert(MerklioStakeVault.NotRewarder.selector);
        vault.fundRewards(10 ether);
        vm.stopPrank();
    }

    function test_OwnerCanFundAsImplicitRewarder() public {
        asset.mint(owner, 10 ether);
        vm.startPrank(owner);
        asset.approve(address(vault), 10 ether);
        vault.fundRewards(10 ether);
        vm.stopPrank();
        assertEq(vault.rewardBuffer(), 10 ether);
    }

    // ───────────────── Chainlink Automation ─────────────────

    function test_CheckUpkeep_FalseWhenNoBufferOrTooEarly() public {
        _deposit(alice, 100 ether);
        (bool need,) = vault.checkUpkeep("");
        assertFalse(need); // no buffer

        vm.startPrank(rewarder);
        asset.approve(address(vault), 10 ether);
        vault.fundRewards(10 ether);
        vm.stopPrank();

        (need,) = vault.checkUpkeep("");
        assertFalse(need); // interval not elapsed yet

        vm.warp(block.timestamp + INTERVAL);
        (need,) = vault.checkUpkeep("");
        assertTrue(need);
    }

    function test_PerformUpkeep_RevertsBeforeInterval() public {
        _deposit(alice, 100 ether);
        vm.startPrank(rewarder);
        asset.approve(address(vault), 10 ether);
        vault.fundRewards(10 ether);
        vm.stopPrank();
        vm.expectRevert(MerklioStakeVault.IntervalNotElapsed.selector);
        vault.performUpkeep("");
    }

    function test_PerformUpkeep_RevertsWithNothingToRelease() public {
        vm.warp(block.timestamp + INTERVAL);
        vm.expectRevert(MerklioStakeVault.NothingToRelease.selector);
        vault.performUpkeep("");
    }

    // ───────────────── Chainlink CCIP ─────────────────

    function test_ReportStateCrossChain_DeliversToReceiver() public {
        _deposit(alice, 100 ether);
        vm.startPrank(rewarder);
        asset.approve(address(vault), 100 ether);
        vault.fundRewards(100 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + INTERVAL);
        vault.performUpkeep(""); // 200 pooled, 100 shares

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        bytes32 mid = vault.reportStateCrossChain{value: 0.01 ether}();

        (uint256 pooled, uint256 shares, uint256 ts, uint64 srcSel, bytes32 lastId) = receiver.latest();
        assertEq(pooled, 200 ether);
        assertEq(shares, 100 ether);
        assertEq(ts, block.timestamp);
        assertEq(srcSel, router.sourceChainSelector());
        assertEq(lastId, mid);
    }

    function test_ReportState_RefundsExcessNative() public {
        _deposit(alice, 10 ether);
        vm.deal(owner, 1 ether);
        uint256 before = owner.balance;
        vm.prank(owner);
        vault.reportStateCrossChain{value: 1 ether}();
        // fee 0.001, refund the rest
        assertEq(owner.balance, before - router.fee());
    }

    function test_ReportState_OnlyOwner() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        vault.reportStateCrossChain{value: 0.01 ether}();
    }

    function test_Receiver_RejectsUnknownSender() public {
        // remove allow-list, expect revert on delivery
        uint64 sel = router.sourceChainSelector(); // cache before prank (arg eval would consume it)
        vm.prank(owner);
        receiver.setAllowedSender(sel, address(vault), false);
        _deposit(alice, 10 ether);
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert();
        vault.reportStateCrossChain{value: 0.01 ether}();
    }

    // ───────────────── UUPS upgrade ─────────────────

    function test_Upgrade_OnlyOwner() public {
        MerklioStakeVaultV2 v2 = new MerklioStakeVaultV2();
        vm.prank(alice);
        vm.expectRevert();
        vault.upgradeToAndCall(address(v2), "");

        vm.prank(owner);
        vault.upgradeToAndCall(address(v2), "");
        assertEq(MerklioStakeVaultV2(payable(address(vault))).version(), 2);
        // state preserved
    }

    function test_UpgradePreservesState() public {
        _deposit(alice, 100 ether);
        MerklioStakeVaultV2 v2 = new MerklioStakeVaultV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2), "");
        assertEq(vault.totalPooled(), 100 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
    }

    // ───────────────── Ownable2Step ─────────────────

    function test_Ownable2Step_TwoPhaseTransfer() public {
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), owner); // not yet
        assertEq(vault.pendingOwner(), bob);
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
    }
}
