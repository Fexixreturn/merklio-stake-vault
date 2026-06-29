// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Vendored from @chainlink/contracts (src/v0.8/automation/AutomationCompatibleInterface.sol).
/// Faithful signatures so the consuming contract is drop-in for the real Chainlink Automation registry.
interface AutomationCompatibleInterface {
    /// @notice Checked off-chain by the Automation network to decide if performUpkeep should run.
    /// @param checkData fixed, set at registration time.
    /// @return upkeepNeeded whether performUpkeep should be called.
    /// @return performData payload forwarded to performUpkeep.
    function checkUpkeep(bytes calldata checkData)
        external
        returns (bool upkeepNeeded, bytes memory performData);

    /// @notice Executed on-chain by the Automation network when checkUpkeep returns true.
    /// @param performData data returned by checkUpkeep (must be re-validated on-chain).
    function performUpkeep(bytes calldata performData) external;
}
