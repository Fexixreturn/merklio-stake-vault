// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from
    "@chainlink/contracts/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

/// @notice Local CCIP router stub for Foundry: on ccipSend it synchronously delivers the message
///         to the destination receiver in the same tx (no real cross-chain hop), so the full
///         send -> receive path is unit-testable. Mirrors IRouterClient's external surface.
contract MockCCIPRouter is IRouterClient {
    uint256 public fee = 0.001 ether;
    uint64 public sourceChainSelector = 1; // selector the receiver sees as the source
    uint256 private _nonce;

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setSourceSelector(uint64 sel) external {
        sourceChainSelector = sel;
    }

    function isChainSupported(uint64) external pure override returns (bool) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view override returns (uint256) {
        return fee;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage calldata message)
        external
        payable
        override
        returns (bytes32 messageId)
    {
        if (msg.value < fee) revert InsufficientFeeTokenAmount();
        messageId = keccak256(abi.encode(block.timestamp, msg.sender, _nonce++));

        address receiver = abi.decode(message.receiver, (address));
        Client.Any2EVMMessage memory delivered = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(msg.sender),
            data: message.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        IAny2EVMMessageReceiver(receiver).ccipReceive(delivered);
    }
}
