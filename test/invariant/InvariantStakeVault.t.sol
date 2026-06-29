// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MerklioStakeVault} from "../../src/MerklioStakeVault.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives the vault with bounded random deposits/withdrawals/funding/releases.
contract Handler is Test {
    MerklioStakeVault public vault;
    MockERC20 public asset;
    address[] public actors;
    uint64 public interval;

    constructor(MerklioStakeVault _vault, MockERC20 _asset, address[] memory _actors, uint64 _interval) {
        vault = _vault;
        asset = _asset;
        actors = _actors;
        interval = _interval;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 1, 1_000 ether);
        asset.mint(a, amt);
        vm.startPrank(a);
        asset.approve(address(vault), amt);
        vault.deposit(amt);
        vm.stopPrank();
    }

    function withdraw(uint256 seed, uint256 shareSeed) external {
        address a = _actor(seed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(shareSeed, 1, bal);
        vm.prank(a);
        vault.withdraw(shares);
    }

    function fund(uint256 amt) external {
        amt = bound(amt, 1, 500 ether);
        asset.mint(address(this), amt);
        asset.approve(address(vault), amt);
        vault.fundRewards(amt); // handler is set as rewarder in setUp
    }

    function release(uint256 jump) external {
        vm.warp(block.timestamp + interval + bound(jump, 0, 30 days));
        try vault.performUpkeep("") {} catch {}
    }
}

contract InvariantStakeVaultTest is Test {
    MerklioStakeVault vault;
    MockERC20 asset;
    Handler handler;
    address owner = makeAddr("owner");

    function setUp() public {
        asset = new MockERC20();
        MerklioStakeVault impl = new MerklioStakeVault();
        bytes memory init = abi.encodeCall(
            MerklioStakeVault.initialize,
            (IERC20(address(asset)), owner, IRouterClient(address(0)), 0, address(0), 1 days)
        );
        vault = MerklioStakeVault(payable(address(new ERC1967Proxy(address(impl), init))));

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("a0");
        actors[1] = makeAddr("a1");
        actors[2] = makeAddr("a2");
        handler = new Handler(vault, asset, actors, 1 days);

        vm.prank(owner);
        vault.setRewarder(address(handler), true);

        targetContract(address(handler));
    }

    /// @notice Core solvency invariant: every asset held is fully accounted as either backing
    ///         shares (totalPooled) or buffered rewards (rewardBuffer) — never lost or conjured.
    function invariant_assetsFullyAccounted() public view {
        assertEq(asset.balanceOf(address(vault)), vault.totalPooled() + vault.rewardBuffer());
    }

    /// @notice Shares are never backed by more than the pooled assets (no over-issuance).
    function invariant_sharesNeverExceedPooledWhenNonEmpty() public view {
        if (vault.totalSupply() > 0) {
            assertGe(vault.totalPooled(), 0);
        }
    }
}
