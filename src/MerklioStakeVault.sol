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
///         transferable LST shares whose redeemable value rises as buffered rewards are dripped
///         into the pool. Reward drips are started by Chainlink Automation; vault state is
///         reported to a destination chain via Chainlink CCIP.
/// @dev Accounting invariant (see tests):
///      `asset.balanceOf(this) >= totalPooled + rewardBuffer + releaseAmount`
///      (equality absent direct donations; donated assets stay in the vault unaccounted and are
///      deliberately not sweepable). Rewards vest LINEARLY over `distributionInterval` rather than
///      as a step, so a release cannot be sandwiched for an instant share-price jump.
///      Assumes a standard ERC-20 asset: no fee-on-transfer, no rebasing, no transfer hooks.
contract MerklioStakeVault is
    Initializable,
    ERC20Upgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;

    // ───────────────────────── Storage ─────────────────────────
    IERC20 public asset; // staking asset (20 bytes; own slot, next var is a full word)

    uint256 public totalPooled; // settled assets backing live shares
    uint256 public rewardBuffer; // funded rewards awaiting the next drip window

    IRouterClient public ccipRouter; // ─┐ 20 bytes + uint64: share one slot
    uint64 public destChainSelector; // ─┘
    uint64 public lastDistribution; // ──┐
    uint64 public distributionInterval; // ┴ share the next slot

    address public destReceiver; // CCIP receiver on the destination chain

    mapping(address => bool) public rewarders; // role: may fund rewards

    // Drip window + CCIP gas config (appended in rev2; __gap shrunk 40 -> 38)
    uint256 public releaseAmount; // unvested rewards in the current drip window
    uint64 public releaseStart; // ──┐ last settlement time within the window
    uint64 public releaseEnd; //     │ window end
    uint64 public ccipGasLimit; // ──┴ dest-chain execution gas for CCIP extraArgs

    uint256[38] private __gap; // upgrade-safe storage gap

    // ───────────────────────── Events ─────────────────────────
    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 assets);
    event RewardsFunded(address indexed from, uint256 amount);
    event RewardsReleased(uint256 amount, uint64 releaseStart, uint64 releaseEnd);
    event RewarderSet(address indexed account, bool allowed);
    event CcipConfigSet(address router, uint64 destChainSelector, address destReceiver);
    event CcipGasLimitSet(uint64 gasLimit);
    event DistributionIntervalSet(uint64 interval);
    event StateReported(bytes32 indexed messageId, uint256 totalAssets, uint256 totalShares);

    // ───────────────────────── Errors ─────────────────────────
    error ZeroAmount();
    error ZeroShares();
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
    /// @param asset_ staking ERC-20 (standard semantics assumed — no fee-on-transfer/rebasing).
    /// @param owner_ admin / upgrade authority (Ownable2Step pending-accept transfer).
    /// @param router_ Chainlink CCIP router (address(0) allowed; configure later).
    /// @param destChainSelector_ CCIP destination chain selector.
    /// @param destReceiver_ CCIP receiver contract on the destination chain.
    /// @param distributionInterval_ length of each reward drip window, and the minimum
    ///        seconds between starting two windows.
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
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        asset = asset_;
        ccipRouter = router_;
        destChainSelector = destChainSelector_;
        destReceiver = destReceiver_;
        distributionInterval = distributionInterval_;
        lastDistribution = uint64(block.timestamp);
        ccipGasLimit = 200_000;
    }

    // ───────────────────────── Staking ─────────────────────────

    /// @notice Stake `assets` and mint LST shares at the current exchange rate.
    /// @dev Reverts with `ZeroShares` if rounding would mint nothing — the deposit would
    ///      otherwise be silently donated to existing holders.
    function deposit(uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _settle();
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        totalPooled += assets;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Burn `shares` and withdraw the corresponding assets at the current exchange rate.
    function withdraw(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        _settle();
        assets = previewRedeem(shares);
        _burn(msg.sender, shares);
        totalPooled -= assets;
        asset.safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, shares, assets);
    }

    /// @notice Shares minted for a given asset amount at the current rate.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 pooled = totalAssets();
        return (supply == 0 || pooled == 0) ? assets : (assets * supply) / pooled;
    }

    /// @notice Assets returned for a given share amount at the current rate.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 0 : (shares * totalAssets()) / supply;
    }

    /// @notice Current redeemable assets backing all shares: settled pool plus the
    ///         already-vested portion of the current drip window.
    function totalAssets() public view returns (uint256) {
        return totalPooled + pendingVested();
    }

    // ───────────────────────── Rewards ─────────────────────────

    /// @notice Fund the reward buffer (dripped later by Automation). Rewarder-gated.
    function fundRewards(uint256 amount) external onlyRewarder {
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        rewardBuffer += amount;
        emit RewardsFunded(msg.sender, amount);
    }

    /// @notice Assets vested so far in the current drip window, not yet settled into `totalPooled`.
    function pendingVested() public view returns (uint256) {
        uint256 amount = releaseAmount;
        if (amount == 0) return 0;
        if (block.timestamp >= releaseEnd) return amount;
        // here releaseEnd > block.timestamp >= releaseStart, so the divisor is non-zero
        return (amount * (block.timestamp - releaseStart)) / (releaseEnd - releaseStart);
    }

    /// @dev Move the vested drip portion into `totalPooled` so deposits/withdrawals mutate
    ///      settled state only. `releaseEnd` stays fixed, which preserves the drip rate:
    ///      the remainder vests over the remaining time.
    function _settle() internal {
        uint256 vested = pendingVested();
        if (vested == 0) return;
        totalPooled += vested;
        releaseAmount -= vested;
        releaseStart = uint64(block.timestamp);
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
    /// @dev Starts a new drip window: buffered rewards vest linearly into the share price over
    ///      `distributionInterval`. Linear vesting (vs. a step release) means there is no instant
    ///      price jump to sandwich with a deposit-before / withdraw-after pair.
    ///      Callable by anyone — the interval gate and buffer check make it state-safe.
    function performUpkeep(bytes calldata) external override {
        if (rewardBuffer == 0) revert NothingToRelease();
        if (block.timestamp < uint256(lastDistribution) + distributionInterval) {
            revert IntervalNotElapsed();
        }
        _settle(); // prior window is fully vested by now unless the interval was shortened
        uint256 amount = rewardBuffer;
        rewardBuffer = 0;
        releaseAmount += amount; // `+=`: any unvested residue re-drips over the new window
        releaseStart = uint64(block.timestamp);
        releaseEnd = uint64(block.timestamp) + distributionInterval;
        lastDistribution = uint64(block.timestamp);
        emit RewardsReleased(amount, releaseStart, releaseEnd);
    }

    // ───────────────────────── Chainlink CCIP ─────────────────────────

    /// @notice Report current vault state (redeemable assets, share supply, timestamp) to the
    ///         configured destination chain via CCIP. Fees paid in native gas token (msg.value).
    /// @return messageId the CCIP message id.
    function reportStateCrossChain() external payable onlyOwner returns (bytes32 messageId) {
        if (address(ccipRouter) == address(0) || destReceiver == address(0)) revert CcipNotConfigured();

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destReceiver),
            data: abi.encode(totalAssets(), totalSupply(), block.timestamp),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // pay in native
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: ccipGasLimit}))
        });

        uint256 fee = ccipRouter.getFee(destChainSelector, message);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        messageId = ccipRouter.ccipSend{value: fee}(destChainSelector, message);

        // refund any excess native sent
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
        emit StateReported(messageId, totalAssets(), totalSupply());
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

    /// @notice Set the destination-chain execution gas limit used in CCIP extraArgs.
    /// @dev Mutable per CCIP best practice — hardcoded extraArgs can't follow protocol upgrades.
    function setCcipGasLimit(uint64 gasLimit) external onlyOwner {
        ccipGasLimit = gasLimit;
        emit CcipGasLimitSet(gasLimit);
    }

    /// @notice Set the drip-window length / minimum gap between drip starts.
    /// @dev Takes effect from the next drip window; the current window keeps its `releaseEnd`.
    function setDistributionInterval(uint64 interval) external onlyOwner {
        distributionInterval = interval;
        emit DistributionIntervalSet(interval);
    }

    /// @dev UUPS upgrade authorization.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
