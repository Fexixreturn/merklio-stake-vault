// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/AutomationCompatibleInterface.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

/// @title MerklioStakeVault
/// @notice Upgradeable (UUPS) liquid-staking vault for a single ERC-20 asset. Depositors receive
///         transferable LST shares whose redeemable value rises as buffered rewards are released.
///         Reward release is automated via Chainlink Automation; vault state is reported to a
///         destination chain via Chainlink CCIP.
/// @dev Accounting invariant (see tests): `asset.balanceOf(this) == totalPooled + rewardBuffer`.
///      Shares are priced as `totalPooled / totalSupply` (1:1 bootstrap on first deposit).
contract MerklioStakeVault is
    Initializable,
    ERC20Upgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;

    // ───────────────────────── Storage (packed) ─────────────────────────
    IERC20 public asset; // slot: staking asset

    uint256 public totalPooled; // asset backing live shares
    uint256 public rewardBuffer; // funded rewards awaiting release

    // CCIP + Automation config packed into one slot where possible
    IRouterClient public ccipRouter; // 20 bytes
    uint64 public destChainSelector; // ─┐ pack with router? separate slot (router is 20b alone)
    uint64 public lastDistribution; //   │
    uint64 public distributionInterval; // ┘ three uint64 share a slot

    address public destReceiver; // CCIP receiver on the destination chain

    mapping(address => bool) public rewarders; // role: may fund rewards

    uint256[40] private __gap; // upgrade-safe storage gap

    // ───────────────────────── Events ─────────────────────────
    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 assets);
    event RewardsFunded(address indexed from, uint256 amount);
    event RewardsReleased(uint256 amount, uint256 newTotalPooled, uint64 at);
    event RewarderSet(address indexed account, bool allowed);
    event CcipConfigSet(address router, uint64 destChainSelector, address destReceiver);
    event StateReported(bytes32 indexed messageId, uint256 totalPooled, uint256 totalShares);

    // ───────────────────────── Errors ─────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error NotRewarder();
    error NothingToRelease();
    error IntervalNotElapsed();
    error CcipNotConfigured();
    error InsufficientFee(uint256 needed, uint256 provided);

    modifier onlyRewarder() {
        if (!rewarders[msg.sender] && msg.sender != owner()) revert NotRewarder();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy.
    /// @param asset_ staking ERC-20.
    /// @param owner_ admin / upgrade authority (Ownable2Step pending-accept transfer).
    /// @param router_ Chainlink CCIP router (address(0) allowed; configure later).
    /// @param destChainSelector_ CCIP destination chain selector.
    /// @param destReceiver_ CCIP receiver contract on the destination chain.
    /// @param distributionInterval_ minimum seconds between automated reward releases.
    function initialize(
        IERC20 asset_,
        address owner_,
        IRouterClient router_,
        uint64 destChainSelector_,
        address destReceiver_,
        uint64 distributionInterval_
    ) external initializer {
        if (address(asset_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        __ERC20_init("Merklio Staked Token", "mLST");
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        asset = asset_;
        ccipRouter = router_;
        destChainSelector = destChainSelector_;
        destReceiver = destReceiver_;
        distributionInterval = distributionInterval_;
        lastDistribution = uint64(block.timestamp);
    }

    // ───────────────────────── Staking ─────────────────────────

    /// @notice Stake `assets` and mint LST shares at the current exchange rate.
    function deposit(uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        shares = previewDeposit(assets);
        asset.safeTransferFrom(msg.sender, address(this), assets);
        totalPooled += assets;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Burn `shares` and withdraw the corresponding assets at the current exchange rate.
    function withdraw(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        assets = previewRedeem(shares);
        _burn(msg.sender, shares);
        totalPooled -= assets;
        asset.safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, shares, assets);
    }

    /// @notice Shares minted for a given asset amount at the current rate.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return (supply == 0 || totalPooled == 0) ? assets : (assets * supply) / totalPooled;
    }

    /// @notice Assets returned for a given share amount at the current rate.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 0 : (shares * totalPooled) / supply;
    }

    // ───────────────────────── Rewards ─────────────────────────

    /// @notice Fund the reward buffer (released later by Automation). Rewarder-gated.
    function fundRewards(uint256 amount) external onlyRewarder {
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        rewardBuffer += amount;
        emit RewardsFunded(msg.sender, amount);
    }

    // ───────────────────── Chainlink Automation ─────────────────────

    /// @inheritdoc AutomationCompatibleInterface
    /// @dev Off-chain simulation only; performUpkeep re-validates on-chain.
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded =
            rewardBuffer > 0 && block.timestamp >= uint256(lastDistribution) + distributionInterval;
        performData = "";
    }

    /// @inheritdoc AutomationCompatibleInterface
    /// @dev Releases the whole buffer into `totalPooled`, lifting the share price for all holders.
    function performUpkeep(bytes calldata) external override {
        if (rewardBuffer == 0) revert NothingToRelease();
        if (block.timestamp < uint256(lastDistribution) + distributionInterval) {
            revert IntervalNotElapsed();
        }
        uint256 amount = rewardBuffer;
        rewardBuffer = 0;
        totalPooled += amount;
        lastDistribution = uint64(block.timestamp);
        emit RewardsReleased(amount, totalPooled, lastDistribution);
    }

    // ───────────────────────── Chainlink CCIP ─────────────────────────

    /// @notice Report current vault state (pooled assets, share supply, timestamp) to the
    ///         configured destination chain via CCIP. Fees paid in native gas token (msg.value).
    /// @return messageId the CCIP message id.
    function reportStateCrossChain() external payable onlyOwner returns (bytes32 messageId) {
        if (address(ccipRouter) == address(0) || destReceiver == address(0)) revert CcipNotConfigured();

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destReceiver),
            data: abi.encode(totalPooled, totalSupply(), block.timestamp),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // pay in native
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 200_000}))
        });

        uint256 fee = ccipRouter.getFee(destChainSelector, message);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        messageId = ccipRouter.ccipSend{value: fee}(destChainSelector, message);

        // refund any excess native sent
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
        emit StateReported(messageId, totalPooled, totalSupply());
    }

    // ───────────────────────── Admin ─────────────────────────

    function setRewarder(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        rewarders[account] = allowed;
        emit RewarderSet(account, allowed);
    }

    function setCcipConfig(IRouterClient router_, uint64 destChainSelector_, address destReceiver_)
        external
        onlyOwner
    {
        ccipRouter = router_;
        destChainSelector = destChainSelector_;
        destReceiver = destReceiver_;
        emit CcipConfigSet(address(router_), destChainSelector_, destReceiver_);
    }

    function setDistributionInterval(uint64 interval) external onlyOwner {
        distributionInterval = interval;
    }

    /// @notice Current redeemable assets backing all shares.
    function totalAssets() external view returns (uint256) {
        return totalPooled;
    }

    /// @dev UUPS upgrade authorization.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Accept native for CCIP fee refunds / funding.
    receive() external payable {}
}
