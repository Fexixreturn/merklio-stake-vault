// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Vendored from @chainlink/contracts (src/v0.8/ccip/libraries/Client.sol).
/// Struct layout and extra-args tag match Chainlink CCIP exactly, so messages built with this
/// library are wire-compatible with the real CCIP Router.
library Client {
    /// @dev A token and the amount sent with a cross-chain message.
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    /// @dev Message delivered to a CCIP receiver on the destination chain.
    struct Any2EVMMessage {
        bytes32 messageId; // message id of the source chain message
        uint64 sourceChainSelector; // source chain selector
        bytes sender; // abi.decode(sender, (address)) if the source chain is an EVM chain
        bytes data; // payload sent in the source chain message
        EVMTokenAmount[] destTokenAmounts; // tokens and amounts delivered
    }

    /// @dev Message sent from an EVM chain to any destination via ccipSend.
    struct EVM2AnyMessage {
        bytes receiver; // abi.encode(receiver address) for EVM destinations
        bytes data; // arbitrary payload
        EVMTokenAmount[] tokenAmounts; // tokens and amounts to transfer
        address feeToken; // fee token; address(0) means pay fees in native gas token
        bytes extraArgs; // see EVMExtraArgsV1
    }

    // bytes4(keccak256("CCIP EVMExtraArgsV1"));
    bytes4 public constant EVM_EXTRA_ARGS_V1_TAG = 0x97a657c9;

    struct EVMExtraArgsV1 {
        uint256 gasLimit; // gas limit for the receiver's ccipReceive on the destination chain
    }

    /// @notice Encodes extra args with the V1 tag, exactly as the CCIP Router expects.
    function _argsToBytes(EVMExtraArgsV1 memory extraArgs) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(EVM_EXTRA_ARGS_V1_TAG, extraArgs);
    }
}
