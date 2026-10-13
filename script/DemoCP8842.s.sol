// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ClaimPass} from "../src/ClaimPass.sol";

/// @notice Plays the CP-8842 story from the litepaper on a local Anvil chain:
///         collision damage, Volkswagen Golf GTI, claim value SEK 24,800.
///         Every party signs with its own key, so you can see "own step only" in action.
///
///   anvil                                   # terminal 1
///   forge script script/DemoCP8842.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
///
/// Uses Anvil's public test keys. Never use these keys on a real network.
contract DemoCP8842 is Script {
    // Anvil default accounts 0–5 (public test keys)
    uint256 constant IF_ADMIN = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant IF_HANDLER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant CUSTOMER_APP = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant WORKSHOP = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant SUPPLIER = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

    uint256 constant CLAIM = 8842;

    function run() external {
        address ifAdmin = vm.addr(IF_ADMIN);
        address workshop = vm.addr(WORKSHOP);
        address supplier = vm.addr(SUPPLIER);

        // 1. If deploys the network and sets up roles and partners
        vm.startBroadcast(IF_ADMIN);
        ClaimPass cp = new ClaimPass(ifAdmin);
        cp.grantRole(cp.ISSUER_ROLE(), ifAdmin);
        cp.grantRole(cp.PARTNER_MANAGER_ROLE(), ifAdmin);
        cp.grantRole(cp.HANDLER_ROLE(), vm.addr(IF_HANDLER));
        cp.grantRole(cp.CUSTOMER_RELAY_ROLE(), vm.addr(CUSTOMER_APP));
        cp.setPartner(workshop, ClaimPass.PartnerKind.Workshop, ClaimPass.Tier.Submit, true);
        cp.setPartner(supplier, ClaimPass.PartnerKind.Supplier, ClaimPass.Tier.Submit, true);

        // 2. Claim opened → token minted. Holder = salted hash, not a name.
        bytes32 holder = keccak256(abi.encodePacked("if-secret-salt", "customer-internal-id"));
        cp.issueClaim(CLAIM, holder, ClaimPass.ProductLine.Motor, 24_800);
        vm.stopBroadcast();
        _log(cp, "Token issued for the claim");

        // 3. Customer confirms the accident report in If's app (app relays it)
        vm.broadcast(CUSTOMER_APP);
        cp.verifyStep(CLAIM, ClaimPass.Step.AccidentReport, keccak256("accident-report.pdf"), 0);
        _log(cp, "Accident report verified by customer");

        // 4. If handler assesses the damage and assigns workshop + supplier
        vm.startBroadcast(IF_HANDLER);
        cp.verifyStep(CLAIM, ClaimPass.Step.DamageAssessment, keccak256("assessment.pdf"), 24_800);
        cp.assignPartners(CLAIM, workshop, supplier);
        vm.stopBroadcast();
        _log(cp, "Damage assessment verified by If  (= prototype screen: awaiting repair estimate)");

        // 5. Workshop, supplier, workshop
        vm.broadcast(WORKSHOP);
        cp.verifyStep(CLAIM, ClaimPass.Step.RepairEstimate, keccak256("estimate.pdf"), 21_500);
        _log(cp, "Repair estimate verified by workshop");

        vm.broadcast(SUPPLIER);
        cp.verifyStep(CLAIM, ClaimPass.Step.PartsOrder, keccak256("parts-order.pdf"), 0);
        _log(cp, "Parts order verified by supplier");

        vm.broadcast(WORKSHOP);
        cp.verifyStep(CLAIM, ClaimPass.Step.RepairCompleted, keccak256("repair-done.jpg"), 0);
        _log(cp, "Repair completed verified by workshop");

        // 6. If releases the payout (SEK, via the bank)
        vm.broadcast(IF_HANDLER);
        cp.verifyStep(CLAIM, ClaimPass.Step.Payout, keccak256("payout-order"), 0);
        _log(cp, "Payout released - claim closed");

        console.log("");
        console.log("ClaimPass contract:", address(cp));
        console.log("Token owner (the contract itself):", cp.ownerOf(CLAIM));
        console.log("Locked / non-transferable:", cp.locked(CLAIM));
    }

    function _log(ClaimPass cp, string memory what) internal view {
        ClaimPass.Claim memory c = cp.getClaim(CLAIM);
        console.log(
            string.concat("CP-8842 | ", vm.toString(uint256(c.stepsVerified)), " of 6 verified | ", what)
        );
    }
}
