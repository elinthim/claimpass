// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ClaimPass} from "../src/ClaimPass.sol";

/// @notice Deploys ClaimPass and hands out If's roles.
/// Env vars: PRIVATE_KEY (deployer = admin), ISSUER, HANDLER, CUSTOMER_RELAY, PARTNER_MANAGER
///
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    function run() external returns (ClaimPass cp) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);

        vm.startBroadcast(pk);
        cp = new ClaimPass(admin);
        cp.grantRole(cp.ISSUER_ROLE(), vm.envOr("ISSUER", admin));
        cp.grantRole(cp.HANDLER_ROLE(), vm.envOr("HANDLER", admin));
        cp.grantRole(cp.CUSTOMER_RELAY_ROLE(), vm.envOr("CUSTOMER_RELAY", admin));
        cp.grantRole(cp.PARTNER_MANAGER_ROLE(), vm.envOr("PARTNER_MANAGER", admin));
        vm.stopBroadcast();

        console.log("ClaimPass deployed at", address(cp));
    }
}
