// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "../libraries/Client.sol";

/// @notice Vendored from @chainlink/contracts (src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol).
/// Implemented by contracts that receive CCIP messages.
interface IAny2EVMMessageReceiver {
    /// @notice Called by the CCIP Router to deliver a cross-chain message.
    function ccipReceive(Client.Any2EVMMessage calldata message) external;
}
