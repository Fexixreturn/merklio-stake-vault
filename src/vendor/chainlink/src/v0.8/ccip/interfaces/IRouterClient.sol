// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "../libraries/Client.sol";

/// @notice Vendored from @chainlink/contracts (src/v0.8/ccip/interfaces/IRouterClient.sol).
/// The on-chain entrypoint a sender uses to dispatch a CCIP message.
interface IRouterClient {
    error UnsupportedDestinationChain(uint64 destChainSelector);
    error InsufficientFeeTokenAmount();
    error InvalidMsgValue();

    /// @param chainSelector destination chain selector.
    /// @return supported true if the destination chain is supported.
    function isChainSupported(uint64 chainSelector) external view returns (bool supported);

    /// @notice Quote the fee (in feeToken, or native if feeToken==address(0)) for a message.
    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message)
        external
        view
        returns (uint256 fee);

    /// @notice Dispatch a message to the destination chain. Returns the CCIP messageId.
    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32);
}
