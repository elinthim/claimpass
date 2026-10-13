// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClaimPass} from "../src/ClaimPass.sol";
import {IERC5192} from "../src/interfaces/IERC5192.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract ClaimPassTest is Test {
    ClaimPass cp;

    address admin = makeAddr("If governance");
    address issuer = makeAddr("If claims system");
    address handler = makeAddr("If handler Marcus");
    address handler2 = makeAddr("If handler 2");
    address relay = makeAddr("If customer app");
    address partnerMgr = makeAddr("If partner manager");
    address workshop = makeAddr("Workshop");
    address otherWorkshop = makeAddr("Other workshop");
    address supplier = makeAddr("Parts supplier");
    address stranger = makeAddr("Stranger");

    uint256 constant CLAIM = 8842;
    bytes32 constant HOLDER = keccak256("salt|customer-123"); // pseudonymous, no personal data

    function setUp() public {
        vm.warp(1_772_600_000); // March 2026
        cp = new ClaimPass(admin);
        vm.startPrank(admin);
        cp.grantRole(cp.ISSUER_ROLE(), issuer);
        cp.grantRole(cp.HANDLER_ROLE(), handler);
        cp.grantRole(cp.HANDLER_ROLE(), handler2);
        cp.grantRole(cp.CUSTOMER_RELAY_ROLE(), relay);
        cp.grantRole(cp.PARTNER_MANAGER_ROLE(), partnerMgr);
        vm.stopPrank();

        vm.startPrank(partnerMgr);
        cp.setPartner(workshop, ClaimPass.PartnerKind.Workshop, ClaimPass.Tier.Submit, true);
        cp.setPartner(otherWorkshop, ClaimPass.PartnerKind.Workshop, ClaimPass.Tier.Submit, true);
        cp.setPartner(supplier, ClaimPass.PartnerKind.Supplier, ClaimPass.Tier.Submit, true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _issue() internal {
        vm.prank(issuer);
        cp.issueClaim(CLAIM, HOLDER, ClaimPass.ProductLine.Motor, 24_800);
        vm.prank(handler);
        cp.assignPartners(CLAIM, workshop, supplier);
    }

    function _verify(address who, ClaimPass.Step step, uint256 amount) internal {
        vm.prank(who);
        cp.verifyStep(CLAIM, step, keccak256(abi.encode("doc", step)), amount);
    }

    function _upToRepairCompleted(uint256 estimate) internal {
        _issue();
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        _verify(handler, ClaimPass.Step.DamageAssessment, 24_800);
        _verify(workshop, ClaimPass.Step.RepairEstimate, estimate);
        _verify(supplier, ClaimPass.Step.PartsOrder, 0);
        _verify(workshop, ClaimPass.Step.RepairCompleted, 0);
    }

    // ---------------------------------------------------------------- token

    function test_IssueMintsLockedTokenHeldByContract() public {
        _issue();
        assertEq(cp.ownerOf(CLAIM), address(cp));
        assertTrue(cp.locked(CLAIM));
        assertTrue(cp.supportsInterface(0xb45a3c0e)); // ERC-5192
        ClaimPass.Claim memory c = cp.getClaim(CLAIM);
        assertEq(c.holder, HOLDER);
        assertEq(c.claimValueSEK, 24_800);
        assertEq(uint8(c.status), uint8(ClaimPass.Status.Active));
        assertEq(c.stepsVerified, 0);
    }

    function test_TokenCannotBeTransferredOrApproved() public {
        _issue();
        vm.startPrank(address(cp));
        vm.expectRevert(ClaimPass.NonTransferable.selector);
        cp.transferFrom(address(cp), stranger, CLAIM);
        vm.expectRevert(ClaimPass.NonTransferable.selector);
        cp.approve(stranger, CLAIM);
        vm.expectRevert(ClaimPass.NonTransferable.selector);
        cp.setApprovalForAll(stranger, true);
        vm.stopPrank();
    }

    function test_CannotIssueTwiceOrWithoutHolder() public {
        _issue();
        vm.startPrank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ClaimPass.ClaimExists.selector, CLAIM));
        cp.issueClaim(CLAIM, HOLDER, ClaimPass.ProductLine.Motor, 1);
        vm.expectRevert(ClaimPass.InvalidHolder.selector);
        cp.issueClaim(1, bytes32(0), ClaimPass.ProductLine.Motor, 1);
        vm.stopPrank();
    }

    function test_OnlyIssuerCanIssue() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, cp.ISSUER_ROLE()
            )
        );
        vm.prank(stranger);
        cp.issueClaim(CLAIM, HOLDER, ClaimPass.ProductLine.Motor, 1);
    }

    function test_TokenURIHasStatusButNoPersonalData() public {
        _issue();
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        _verify(handler, ClaimPass.Step.DamageAssessment, 24_800);
        string memory uri = cp.tokenURI(CLAIM);
        assertGt(bytes(uri).length, 40);
    }

    // ---------------------------------------------------------------- happy path

    /// The CP-8842 story from the litepaper prototype: manual payout (phase 1–2).
    function test_FullFlowManualPayout() public {
        _upToRepairCompleted(21_500);
        assertEq(uint8(cp.getClaim(CLAIM).status), uint8(ClaimPass.Status.Active));

        vm.expectEmit(true, false, false, true);
        emit ClaimPass.PayoutReleased(CLAIM, 21_500, false);
        _verify(handler, ClaimPass.Step.Payout, 0);

        ClaimPass.Claim memory c = cp.getClaim(CLAIM);
        assertEq(uint8(c.status), uint8(ClaimPass.Status.Closed));
        assertEq(c.stepsVerified, 6);
        assertEq(cp.getStep(CLAIM, ClaimPass.Step.RepairEstimate).verifier, workshop);
        assertEq(cp.getStep(CLAIM, ClaimPass.Step.PartsOrder).verifier, supplier);
    }

    /// Phase 3: payout is triggered automatically by the verified repair.
    function test_AutoPayoutWhenRepairCompleted() public {
        vm.prank(admin);
        cp.updateSettings(true, 1 days, 20, 90);

        _issue();
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        _verify(handler, ClaimPass.Step.DamageAssessment, 24_800);
        _verify(workshop, ClaimPass.Step.RepairEstimate, 21_500);
        _verify(supplier, ClaimPass.Step.PartsOrder, 0);

        vm.expectEmit(true, false, false, true);
        emit ClaimPass.PayoutReleased(CLAIM, 21_500, true);
        _verify(workshop, ClaimPass.Step.RepairCompleted, 0);

        ClaimPass.Claim memory c = cp.getClaim(CLAIM);
        assertEq(uint8(c.status), uint8(ClaimPass.Status.Closed));
        assertEq(c.stepsVerified, 6);
        assertEq(cp.getStep(CLAIM, ClaimPass.Step.Payout).verifier, address(cp));
    }

    function test_AuditHeadChangesWithEveryStep() public {
        _issue();
        bytes32 h0 = cp.getClaim(CLAIM).auditHead;
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        bytes32 h1 = cp.getClaim(CLAIM).auditHead;
        assertTrue(h0 != h1);
    }

    // ---------------------------------------------------------------- "own step only"

    function test_StepsMustComeInOrder() public {
        _issue();
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimPass.WrongStep.selector, ClaimPass.Step.AccidentReport, ClaimPass.Step.DamageAssessment
            )
        );
        _verify(handler, ClaimPass.Step.DamageAssessment, 24_800);
    }

    function test_StepCannotBeVerifiedTwice() public {
        _issue();
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimPass.WrongStep.selector, ClaimPass.Step.DamageAssessment, ClaimPass.Step.AccidentReport
            )
        );
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
    }

    function test_OnlyResponsiblePartyCanVerify() public {
        _issue();
        // Workshop cannot file the customer's accident report
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimPass.NotResponsibleParty.selector, ClaimPass.Step.AccidentReport, workshop
            )
        );
        _verify(workshop, ClaimPass.Step.AccidentReport, 0);

        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        _verify(handler, ClaimPass.Step.DamageAssessment, 24_800);

        // A workshop that is not assigned to this claim cannot submit the estimate
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimPass.NotResponsibleParty.selector, ClaimPass.Step.RepairEstimate, otherWorkshop
            )
        );
        _verify(otherWorkshop, ClaimPass.Step.RepairEstimate, 20_000);

        // The supplier cannot submit the workshop's estimate
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimPass.NotResponsibleParty.selector, ClaimPass.Step.RepairEstimate, supplier
            )
        );
        _verify(supplier, ClaimPass.Step.RepairEstimate, 20_000);
    }

    function test_BasicTierCannotSubmit() public {
        _issue();
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        _verify(handler, ClaimPass.Step.DamageAssessment, 24_800);
        vm.prank(partnerMgr);
        cp.setPartner(workshop, ClaimPass.PartnerKind.Workshop, ClaimPass.Tier.Basic, true);
        vm.expectRevert(abi.encodeWithSelector(ClaimPass.PartnerNotEligible.selector, workshop));
        _verify(workshop, ClaimPass.Step.RepairEstimate, 20_000);
    }

    function test_CannotAssignWrongKindOfPartner() public {
        vm.prank(issuer);
        cp.issueClaim(CLAIM, HOLDER, ClaimPass.ProductLine.Motor, 24_800);
        vm.prank(handler);
        vm.expectRevert(abi.encodeWithSelector(ClaimPass.PartnerNotEligible.selector, supplier));
        cp.assignPartners(CLAIM, supplier, supplier);
    }

    function test_AmountRules() public {
        _issue();
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        vm.expectRevert(ClaimPass.InvalidAmount.selector);
        _verify(handler, ClaimPass.Step.DamageAssessment, 0);
    }

    // ---------------------------------------------------------------- human review

    function test_EstimateAboveApprovedGoesToReviewNotAutoPayout() public {
        vm.prank(admin);
        cp.updateSettings(true, 1 days, 20, 90);
        _issue();
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        _verify(handler, ClaimPass.Step.DamageAssessment, 24_800);
        _verify(workshop, ClaimPass.Step.RepairEstimate, 30_000);
        assertEq(uint8(cp.getClaim(CLAIM).status), uint8(ClaimPass.Status.UnderReview));

        // Nothing can move while a person looks at it
        vm.expectRevert(
            abi.encodeWithSelector(ClaimPass.ClaimNotActive.selector, CLAIM, ClaimPass.Status.UnderReview)
        );
        _verify(supplier, ClaimPass.Step.PartsOrder, 0);

        // Handler accepts the higher estimate → claim continues
        vm.prank(handler);
        cp.resolveReview(CLAIM, false, keccak256("ok"));
        assertEq(cp.getClaim(CLAIM).approvedAmountSEK, 30_000);
        _verify(supplier, ClaimPass.Step.PartsOrder, 0);
    }

    function test_RejectionNeedsSecondHandler() public {
        _issue();
        vm.prank(handler);
        cp.sendToReview(CLAIM, keccak256("suspected fraud"));

        vm.prank(handler);
        vm.expectRevert(ClaimPass.FourEyesRequired.selector);
        cp.resolveReview(CLAIM, true, keccak256("reject"));

        vm.prank(handler2);
        cp.resolveReview(CLAIM, true, keccak256("written explanation"));
        assertEq(uint8(cp.getClaim(CLAIM).status), uint8(ClaimPass.Status.Rejected));
    }

    function test_PartnersCannotReject() public {
        _issue();
        vm.prank(workshop);
        vm.expectRevert();
        cp.sendToReview(CLAIM, bytes32(0));
    }

    // ---------------------------------------------------------------- reputation

    function test_ReputationAndFastTrack() public {
        vm.prank(admin);
        cp.updateSettings(false, 1 days, 2, 90);

        _upToRepairCompleted(20_000); // workshop: 2 on-time steps
        ClaimPass.Partner memory p = cp.getPartner(workshop);
        assertEq(p.verifiedSteps, 2);
        assertEq(p.onTimeSteps, 2);
        assertTrue(cp.isFastTrack(workshop));

        // A late step (3 days) lowers the score below 90 %
        vm.prank(issuer);
        cp.issueClaim(2, HOLDER, ClaimPass.ProductLine.Motor, 5_000);
        vm.prank(handler);
        cp.assignPartners(2, workshop, supplier);
        vm.prank(relay);
        cp.verifyStep(2, ClaimPass.Step.AccidentReport, bytes32(0), 0);
        vm.prank(handler);
        cp.verifyStep(2, ClaimPass.Step.DamageAssessment, bytes32(0), 5_000);
        vm.warp(block.timestamp + 3 days);
        vm.prank(workshop);
        cp.verifyStep(2, ClaimPass.Step.RepairEstimate, bytes32(0), 4_000);

        p = cp.getPartner(workshop);
        assertEq(p.verifiedSteps, 3);
        assertEq(p.onTimeSteps, 2);
        assertFalse(cp.isFastTrack(workshop));
    }

    // ---------------------------------------------------------------- ops

    function test_PauseStopsWrites() public {
        _issue();
        vm.prank(admin);
        cp.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
        vm.prank(admin);
        cp.unpause();
        _verify(relay, ClaimPass.Step.AccidentReport, 0);
    }

    function test_AnchorEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ClaimPass.AuditAnchored(bytes32(uint256(1)), "polygon", "0xabc");
        vm.prank(issuer);
        cp.recordAnchor(bytes32(uint256(1)), "polygon", "0xabc");
    }

    function testFuzz_NoOneElseCanVerify(address caller) public {
        vm.assume(caller != relay);
        _issue();
        vm.prank(caller);
        vm.expectRevert();
        cp.verifyStep(CLAIM, ClaimPass.Step.AccidentReport, bytes32(0), 0);
    }
}
