// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAny2EVMMessageReceiver} from "../interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "../libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Vendored from @chainlink/contracts (src/v0.8/ccip/applications/CCIPReceiver.sol).
/// Base for non-upgradeable CCIP receivers: gates delivery to the trusted Router and exposes
/// a virtual _ccipReceive for app logic. Matches the real base's external surface.
abstract contract CCIPReceiver is IAny2EVMMessageReceiver, IERC165 {
    address internal immutable i_ccipRouter;

    error InvalidRouter(address router);

    constructor(address router) {
        if (router == address(0)) revert InvalidRouter(address(0));
        i_ccipRouter = router;
    }

    /// @notice IERC165 support so the Router can detect a valid receiver.
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message) external virtual override onlyRouter {
        _ccipReceive(message);
    }

    /// @notice Override with destination-chain application logic.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal virtual;

    /// @return the configured CCIP Router address.
    function getRouter() public view returns (address) {
        return i_ccipRouter;
    }

    modifier onlyRouter() {
        if (msg.sender != i_ccipRouter) revert InvalidRouter(msg.sender);
        _;
    }
}
