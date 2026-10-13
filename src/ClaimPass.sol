// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IERC5192} from "./interfaces/IERC5192.sol";

/// @title ClaimPass – tokenized claim verification for If P&C Insurance
/// @notice A closed, permissioned claims-verification network between If, the customer,
///         repair shops and suppliers. Every claim gets one non-transferable token that
///         records the verified status and audit trail of the claim:
///
///           Token issued → Accident report → Damage assessment → Repair estimate
///                        → Parts order → Repair completed → Payout
///
///         Design rules from the litepaper:
///         - Non-transferable utility token (ERC-721 + ERC-5192 "locked"). It moves no value.
///         - No personal data on-chain: only claim status, amounts, a pseudonymous holder id
///           and hashes of documents kept in If's own systems (GDPR, EDPB 02/2025).
///         - Each step is verified once, by the party responsible for it ("own step only").
///           Nobody can change a record another party created.
///         - Payouts stay in SEK through ordinary banking; the contract only emits the
///           instruction that If's payment system acts on.
///         - Automation can approve a payout but never reject a claim. Rejections need a
///           human decision by a second If handler (GDPR art. 22, four-eyes principle).
/// @dev This is a course prototype (Blockchain for business, Medieinstitutet). Not audited.
contract ClaimPass is ERC721, AccessControl, Pausable, IERC5192 {
    using Strings for uint256;

    // ---------------------------------------------------------------------
    // Roles (all held by If or by systems If operates)
    // ---------------------------------------------------------------------

    /// @notice If's claims system: issues a token when a claim is opened, anchors audit roots.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    /// @notice If claims handlers: damage assessment, payout approval, human review.
    bytes32 public constant HANDLER_ROLE = keccak256("HANDLER_ROLE");
    /// @notice Backend of If's customer app. Customers never hold a wallet; the app records
    ///         the customer's own confirmation of the accident report on their behalf.
    bytes32 public constant CUSTOMER_RELAY_ROLE = keccak256("CUSTOMER_RELAY_ROLE");
    /// @notice Onboards, re-tiers and offboards repair shops and suppliers.
    bytes32 public constant PARTNER_MANAGER_ROLE = keccak256("PARTNER_MANAGER_ROLE");

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum Step {
        AccidentReport, // customer (via If app)
        DamageAssessment, // If handler
        RepairEstimate, // assigned workshop
        PartsOrder, // assigned supplier
        RepairCompleted, // assigned workshop
        Payout // If handler, or automatic (phase 3)

    }

    uint8 public constant STEP_COUNT = 6;

    enum Status {
        None,
        Active,
        UnderReview, // waiting for a human decision
        Rejected,
        Closed // payout released

    }

    enum ProductLine {
        Motor,
        Home
    }

    enum PartnerKind {
        None,
        Workshop,
        Supplier
    }

    /// @notice Access tiers that map to the partner SaaS plans.
    /// Basic  = read claim status (free tier, so small workshops are not shut out)
    /// Submit = may verify its own steps on assigned claims
    /// Priority = Submit + priority queue / higher API limits (enforced off-chain)
    enum Tier {
        None,
        Basic,
        Submit,
        Priority
    }

    struct Partner {
        PartnerKind kind;
        Tier tier;
        bool active;
        uint32 verifiedSteps; // reputation: number of steps verified
        uint32 onTimeSteps; // reputation: steps verified within the SLA
    }

    struct StepRecord {
        address verifier;
        uint64 verifiedAt;
        bytes32 docHash; // hash of the off-chain document (estimate, invoice, photos ...)
    }

    struct Claim {
        bytes32 holder; // pseudonymous id (salted hash kept by If), never a name
        ProductLine productLine;
        Status status;
        uint8 stepsVerified;
        uint64 issuedAt;
        uint64 lastActivityAt;
        uint256 claimValueSEK; // initial reserve set when the claim is opened
        uint256 approvedAmountSEK; // set by the damage assessment
        uint256 estimateAmountSEK; // set by the repair estimate
        address workshop;
        address supplier;
        address flaggedBy; // handler who sent the claim to review (four-eyes)
        bytes32 auditHead; // rolling hash over every event on this claim
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(uint256 => Claim) private _claims;
    mapping(uint256 => mapping(Step => StepRecord)) private _steps;
    mapping(address => Partner) private _partners;

    /// @notice Phase 3 switch: automatic payouts only after legal review.
    bool public autoPayoutEnabled;
    /// @notice "Within one working day" – used for the partner reputation signal.
    uint64 public slaSeconds = 1 days;
    /// @notice Minimum history before a partner can be fast-tracked.
    uint32 public fastTrackMinSteps = 20;
    /// @notice Share of on-time steps (percent) needed for fast-track.
    uint8 public fastTrackOnTimePct = 90;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ClaimIssued(
        uint256 indexed claimId, bytes32 indexed holder, ProductLine productLine, uint256 claimValueSEK
    );
    event PartnersAssigned(uint256 indexed claimId, address workshop, address supplier);
    event StepVerified(
        uint256 indexed claimId,
        Step indexed step,
        address indexed verifier,
        bytes32 docHash,
        uint256 amountSEK
    );
    event SentToReview(uint256 indexed claimId, address indexed by, bytes32 reasonHash);
    event ReviewResolved(
        uint256 indexed claimId, address indexed reviewer, bool rejected, bytes32 reasonHash
    );
    /// @notice Picked up by If's payment system, which pays the customer in SEK via the bank.
    event PayoutReleased(uint256 indexed claimId, uint256 amountSEK, bool automatic);
    event PartnerUpdated(address indexed partner, PartnerKind kind, Tier tier, bool active);
    event AuditAnchored(bytes32 indexed root, string target, string externalRef);
    event SettingsUpdated(
        bool autoPayoutEnabled, uint64 slaSeconds, uint32 fastTrackMinSteps, uint8 fastTrackOnTimePct
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NonTransferable();
    error ClaimExists(uint256 claimId);
    error UnknownClaim(uint256 claimId);
    error ClaimNotActive(uint256 claimId, Status status);
    error WrongStep(Step expected, Step given);
    error NotResponsibleParty(Step step, address caller);
    error PartnerNotEligible(address partner);
    error PartnersNotAssigned(uint256 claimId);
    error InvalidHolder();
    error InvalidAmount();
    error NotUnderReview(uint256 claimId);
    error FourEyesRequired();

    // ---------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------

    /// @param admin If governance account (multisig in production).
    constructor(address admin) ERC721("ClaimPass", "CLAIM") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------------
    // Claim lifecycle
    // ---------------------------------------------------------------------

    /// @notice Opens a claim and mints its non-transferable token.
    /// @param claimId   If's claim number (e.g. 8842 for CP-8842).
    /// @param holder    Pseudonymous holder id = keccak256(secretSalt, internalCustomerId).
    ///                  Computed off-chain; the salt never leaves If, so the id cannot be
    ///                  linked to a person from chain data alone.
    /// @param claimValueSEK Initial reserve for the claim, whole SEK.
    function issueClaim(uint256 claimId, bytes32 holder, ProductLine productLine, uint256 claimValueSEK)
        external
        onlyRole(ISSUER_ROLE)
        whenNotPaused
    {
        if (_claims[claimId].status != Status.None) revert ClaimExists(claimId);
        if (holder == bytes32(0)) revert InvalidHolder();

        Claim storage c = _claims[claimId];
        c.holder = holder;
        c.productLine = productLine;
        c.status = Status.Active;
        c.issuedAt = uint64(block.timestamp);
        c.lastActivityAt = uint64(block.timestamp);
        c.claimValueSEK = claimValueSEK;
        c.auditHead = keccak256(abi.encode(claimId, holder, productLine, claimValueSEK, block.timestamp));

        // The token is held by the contract itself: it belongs to the claim, not to a person.
        _mint(address(this), claimId);
        emit Locked(claimId);
        emit ClaimIssued(claimId, holder, productLine, claimValueSEK);
    }

    /// @notice If assigns the repair shop and parts supplier that may verify steps on a claim.
    function assignPartners(uint256 claimId, address workshop, address supplier)
        external
        onlyRole(HANDLER_ROLE)
        whenNotPaused
    {
        Claim storage c = _activeClaim(claimId);
        _requireEligible(workshop, PartnerKind.Workshop);
        _requireEligible(supplier, PartnerKind.Supplier);
        c.workshop = workshop;
        c.supplier = supplier;
        _appendAudit(c, keccak256(abi.encode("ASSIGN", workshop, supplier)));
        emit PartnersAssigned(claimId, workshop, supplier);
    }

    /// @notice Records one verified step. Steps must come in order and each can be verified
    ///         exactly once, by the party responsible for it.
    /// @param docHash   Hash of the supporting document stored off-chain.
    /// @param amountSEK Approved amount (DamageAssessment), estimate (RepairEstimate),
    ///                  otherwise 0.
    function verifyStep(uint256 claimId, Step step, bytes32 docHash, uint256 amountSEK)
        external
        whenNotPaused
    {
        Claim storage c = _activeClaim(claimId);
        Step expected = Step(c.stepsVerified);
        if (step != expected) revert WrongStep(expected, step);
        _requireResponsible(claimId, c, step, msg.sender);

        if (step == Step.DamageAssessment) {
            if (amountSEK == 0) revert InvalidAmount();
            c.approvedAmountSEK = amountSEK;
        } else if (step == Step.RepairEstimate) {
            if (amountSEK == 0) revert InvalidAmount();
            c.estimateAmountSEK = amountSEK;
        } else if (amountSEK != 0) {
            revert InvalidAmount();
        }

        _recordStep(claimId, c, step, docHash, amountSEK);

        // Estimate above the approved amount → a person must look at it.
        if (step == Step.RepairEstimate && amountSEK > c.approvedAmountSEK) {
            _sendToReview(claimId, c, address(0), keccak256("ESTIMATE_ABOVE_APPROVED"));
            return;
        }

        if (step == Step.RepairCompleted && autoPayoutEnabled) {
            _releasePayout(claimId, c, true);
        } else if (step == Step.Payout) {
            _releasePayout(claimId, c, false);
        }
    }

    /// @notice Any If handler can stop the automation and send a claim to a person.
    function sendToReview(uint256 claimId, bytes32 reasonHash)
        external
        onlyRole(HANDLER_ROLE)
        whenNotPaused
    {
        Claim storage c = _activeClaim(claimId);
        _sendToReview(claimId, c, msg.sender, reasonHash);
    }

    /// @notice Human decision on a claim under review. A rejection always comes from a person,
    ///         and never from the same handler who flagged the claim.
    /// @param reject       true = reject the claim, false = continue (and accept a higher estimate).
    /// @param reasonHash   Hash of the written explanation given to the customer.
    function resolveReview(uint256 claimId, bool reject, bytes32 reasonHash)
        external
        onlyRole(HANDLER_ROLE)
        whenNotPaused
    {
        Claim storage c = _claims[claimId];
        if (c.status != Status.UnderReview) revert NotUnderReview(claimId);
        if (c.flaggedBy == msg.sender) revert FourEyesRequired();

        c.flaggedBy = address(0);
        if (reject) {
            c.status = Status.Rejected;
        } else {
            c.status = Status.Active;
            // Handler accepted the estimate: it becomes the approved amount.
            if (c.estimateAmountSEK > c.approvedAmountSEK) c.approvedAmountSEK = c.estimateAmountSEK;
        }
        c.lastActivityAt = uint64(block.timestamp);
        _appendAudit(c, keccak256(abi.encode("REVIEW", msg.sender, reject, reasonHash)));
        emit ReviewResolved(claimId, msg.sender, reject, reasonHash);
    }

    /// @notice Stores the hash of a batch of audit trails that has been written to a public
    ///         chain (e.g. Polygon), so outsiders can check that nothing was changed.
    function recordAnchor(bytes32 root, string calldata target, string calldata externalRef)
        external
        onlyRole(ISSUER_ROLE)
    {
        emit AuditAnchored(root, target, externalRef);
    }

    // ---------------------------------------------------------------------
    // Partner registry
    // ---------------------------------------------------------------------

    function setPartner(address partner, PartnerKind kind, Tier tier, bool active)
        external
        onlyRole(PARTNER_MANAGER_ROLE)
    {
        Partner storage p = _partners[partner];
        p.kind = kind;
        p.tier = tier;
        p.active = active;
        emit PartnerUpdated(partner, kind, tier, active);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function updateSettings(bool autoPayout, uint64 sla, uint32 minSteps, uint8 onTimePct)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(onTimePct <= 100, "pct");
        autoPayoutEnabled = autoPayout;
        slaSeconds = sla;
        fastTrackMinSteps = minSteps;
        fastTrackOnTimePct = onTimePct;
        emit SettingsUpdated(autoPayout, sla, minSteps, onTimePct);
    }

    /// @notice Emergency stop (DORA incident handling).
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        if (_claims[claimId].status == Status.None) revert UnknownClaim(claimId);
        return _claims[claimId];
    }

    function getStep(uint256 claimId, Step step) external view returns (StepRecord memory) {
        return _steps[claimId][step];
    }

    /// @notice The step the claim is waiting for (only meaningful while Active).
    function nextStep(uint256 claimId) external view returns (Step) {
        Claim storage c = _claims[claimId];
        if (c.status != Status.Active) revert ClaimNotActive(claimId, c.status);
        return Step(c.stepsVerified);
    }

    function getPartner(address partner) external view returns (Partner memory) {
        return _partners[partner];
    }

    /// @notice Reputation signal: a partner with a good verified history can be fast-tracked.
    ///         Partners can read their own score, so it can be checked and challenged.
    function isFastTrack(address partner) public view returns (bool) {
        Partner storage p = _partners[partner];
        if (!p.active || p.verifiedSteps < fastTrackMinSteps) return false;
        return uint256(p.onTimeSteps) * 100 >= uint256(p.verifiedSteps) * fastTrackOnTimePct;
    }

    /// @inheritdoc IERC5192
    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    /// @notice On-chain metadata: status only, no personal data.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Claim storage c = _claims[tokenId];
        string memory json = string.concat(
            '{"name":"ClaimPass CP-',
            tokenId.toString(),
            '","description":"Non-transferable claim verification token. No personal data on-chain.",',
            '"attributes":[{"trait_type":"Status","value":"',
            _statusName(c.status),
            '"},{"trait_type":"Steps verified","value":',
            uint256(c.stepsVerified).toString(),
            '},{"trait_type":"Steps total","value":6},{"trait_type":"Transferable","value":"No"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Non-transferability
    // ---------------------------------------------------------------------

    /// @dev Only minting is allowed. Every transfer or burn reverts.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override {
        revert NonTransferable();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert NonTransferable();
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _activeClaim(uint256 claimId) private view returns (Claim storage c) {
        c = _claims[claimId];
        if (c.status == Status.None) revert UnknownClaim(claimId);
        if (c.status != Status.Active) revert ClaimNotActive(claimId, c.status);
    }

    function _requireEligible(address partner, PartnerKind kind) private view {
        Partner storage p = _partners[partner];
        if (!p.active || p.kind != kind || p.tier < Tier.Submit) revert PartnerNotEligible(partner);
    }

    function _requireResponsible(uint256 claimId, Claim storage c, Step step, address caller) private view {
        bool ok;
        if (step == Step.AccidentReport) {
            ok = hasRole(CUSTOMER_RELAY_ROLE, caller);
        } else if (step == Step.DamageAssessment || step == Step.Payout) {
            ok = hasRole(HANDLER_ROLE, caller);
        } else {
            if (c.workshop == address(0)) revert PartnersNotAssigned(claimId);
            address assigned = step == Step.PartsOrder ? c.supplier : c.workshop;
            ok = caller == assigned;
            if (ok) {
                _requireEligible(
                    caller, step == Step.PartsOrder ? PartnerKind.Supplier : PartnerKind.Workshop
                );
            }
        }
        if (!ok) revert NotResponsibleParty(step, caller);
    }

    function _recordStep(uint256 claimId, Claim storage c, Step step, bytes32 docHash, uint256 amountSEK)
        private
    {
        uint64 nowTs = uint64(block.timestamp);
        _steps[claimId][step] = StepRecord({verifier: msg.sender, verifiedAt: nowTs, docHash: docHash});

        Partner storage p = _partners[msg.sender];
        if (p.kind != PartnerKind.None) {
            p.verifiedSteps += 1;
            if (nowTs - c.lastActivityAt <= slaSeconds) p.onTimeSteps += 1;
        }

        c.stepsVerified += 1;
        c.lastActivityAt = nowTs;
        _appendAudit(c, keccak256(abi.encode(step, msg.sender, docHash, amountSEK, nowTs)));
        emit StepVerified(claimId, step, msg.sender, docHash, amountSEK);
    }

    function _releasePayout(uint256 claimId, Claim storage c, bool automatic) private {
        if (automatic) {
            // The contract records the payout step itself, triggered by the verified repair.
            _steps[claimId][Step.Payout] = StepRecord({
                verifier: address(this),
                verifiedAt: uint64(block.timestamp),
                docHash: bytes32(0)
            });
            c.stepsVerified += 1;
            _appendAudit(c, keccak256(abi.encode(Step.Payout, address(this), block.timestamp)));
            emit StepVerified(claimId, Step.Payout, address(this), bytes32(0), 0);
        }
        uint256 amount = c.estimateAmountSEK < c.approvedAmountSEK ? c.estimateAmountSEK : c.approvedAmountSEK;
        c.status = Status.Closed;
        emit PayoutReleased(claimId, amount, automatic);
    }

    function _sendToReview(uint256 claimId, Claim storage c, address by, bytes32 reasonHash) private {
        c.status = Status.UnderReview;
        c.flaggedBy = by;
        _appendAudit(c, keccak256(abi.encode("FLAG", by, reasonHash)));
        emit SentToReview(claimId, by, reasonHash);
    }

    function _appendAudit(Claim storage c, bytes32 entry) private {
        c.auditHead = keccak256(abi.encode(c.auditHead, entry));
    }

    function _statusName(Status s) private pure returns (string memory) {
        if (s == Status.Active) return "Active";
        if (s == Status.UnderReview) return "Under review";
        if (s == Status.Rejected) return "Rejected";
        if (s == Status.Closed) return "Closed";
        return "None";
    }
}
