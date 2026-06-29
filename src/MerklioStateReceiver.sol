// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MerklioStateReceiver
/// @notice Destination-chain mirror of a MerklioStakeVault's state, delivered via Chainlink CCIP.
/// @dev Accepts messages only from an allow-listed (sourceChainSelector, sender) pair.
contract MerklioStateReceiver is CCIPReceiver, Ownable2Step {
    struct VaultState {
        uint256 totalPooled;
        uint256 totalShares;
        uint256 reportedAt; // source-chain block.timestamp at send
        uint64 sourceChainSelector;
        bytes32 lastMessageId;
    }

    VaultState public latest;
    mapping(uint64 => mapping(address => bool)) public allowedSender; // selector => sender => ok

    event SenderAllowed(uint64 indexed sourceChainSelector, address indexed sender, bool allowed);
    event StateReceived(
        bytes32 indexed messageId, uint64 indexed sourceChainSelector, uint256 totalPooled, uint256 totalShares
    );

    error SenderNotAllowed(uint64 sourceChainSelector, address sender);

    constructor(address router, address owner_) CCIPReceiver(router) Ownable(owner_) {}

    /// @notice Allow-list a (source chain, sender) pair permitted to update state.
    function setAllowedSender(uint64 sourceChainSelector, address sender, bool allowed) external onlyOwner {
        allowedSender[sourceChainSelector][sender] = allowed;
        emit SenderAllowed(sourceChainSelector, sender, allowed);
    }

    /// @inheritdoc CCIPReceiver
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        if (!allowedSender[message.sourceChainSelector][sender]) {
            revert SenderNotAllowed(message.sourceChainSelector, sender);
        }
        (uint256 totalPooled, uint256 totalShares, uint256 reportedAt) =
            abi.decode(message.data, (uint256, uint256, uint256));

        latest = VaultState({
            totalPooled: totalPooled,
            totalShares: totalShares,
            reportedAt: reportedAt,
            sourceChainSelector: message.sourceChainSelector,
            lastMessageId: message.messageId
        });
        emit StateReceived(message.messageId, message.sourceChainSelector, totalPooled, totalShares);
    }
}
