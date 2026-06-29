// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MerklioStakeVault} from "../src/MerklioStakeVault.sol";
import {MerklioStateReceiver} from "../src/MerklioStateReceiver.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

/// @notice Deploys the vault (UUPS proxy) + destination-chain receiver and wires CCIP config.
/// @dev Configure via env:
///   ASSET                 staking ERC-20 address (required)
///   CCIP_ROUTER           Chainlink CCIP router on this chain (e.g. Sepolia router)
///   DEST_CHAIN_SELECTOR   CCIP selector of the destination chain
///   DEST_RECEIVER         pre-deployed receiver address (optional; else deploy one here)
///   DEST_ROUTER           CCIP router on the destination chain (for the receiver we deploy)
///   DISTRIBUTION_INTERVAL seconds between automated releases (default 86400)
///   PRIVATE_KEY           deployer key
///
/// Real Sepolia router/selector values are published in the Chainlink CCIP directory.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address asset = vm.envAddress("ASSET");
        address router = vm.envOr("CCIP_ROUTER", address(0));
        uint64 destSelector = uint64(vm.envOr("DEST_CHAIN_SELECTOR", uint256(0)));
        uint64 interval = uint64(vm.envOr("DISTRIBUTION_INTERVAL", uint256(86400)));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // optional receiver on the destination chain
        address receiver = vm.envOr("DEST_RECEIVER", address(0));
        if (receiver == address(0)) {
            address destRouter = vm.envOr("DEST_ROUTER", router);
            receiver = address(new MerklioStateReceiver(destRouter, deployer));
            console2.log("MerklioStateReceiver:", receiver);
        }

        MerklioStakeVault impl = new MerklioStakeVault();
        bytes memory init = abi.encodeCall(
            MerklioStakeVault.initialize,
            (IERC20(asset), deployer, IRouterClient(router), destSelector, receiver, interval)
        );
        address proxy = address(new ERC1967Proxy(address(impl), init));

        vm.stopBroadcast();

        console2.log("MerklioStakeVault impl:", address(impl));
        console2.log("MerklioStakeVault proxy:", proxy);
        console2.log("asset:", asset);
        console2.log("ccipRouter:", router);
        console2.log("destChainSelector:", uint256(destSelector));
    }
}
