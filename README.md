# ClaimPass

**Tokenized claim verification for If P&C Insurance (If Skadeförsäkring AB)**
Course project – *Blockchain for business*, Medieinstitutet. This is the code that goes with the litepaper.

> Claims handling is slowed down by everything that has to pass between the customer, If, repair shops and suppliers, because each of them keeps its own records. ClaimPass is a closed, permissioned network where every claim gets **one non-transferable token** that records the verified status of each step. Customers use If's app as usual and never need a wallet. **No personal data is stored on-chain**, and payouts stay in **SEK through the customer's ordinary bank**.

The [web prototype](web/index.html) recreates the screens from Appendix A of the litepaper (claim CP-8842).

![Claim flow](https://img.shields.io/badge/steps-6-4f46e5) ![Token](https://img.shields.io/badge/token-non--transferable-14141c) ![Tests](https://github.com/elinthim/claimpass/actions/workflows/test.yml/badge.svg)

---

## What's in the repo

| Path | What it is |
|---|---|
| [`src/ClaimPass.sol`](src/ClaimPass.sol) | The smart contract: non-transferable claim token (ERC-721 + ERC-5192 "locked"), roles, the six claim steps, human review, partner reputation, payout trigger, audit hash |
| [`test/ClaimPass.t.sol`](test/ClaimPass.t.sol) | 21 Foundry tests, one or more for each rule in the litepaper |
| [`script/DemoCP8842.s.sol`](script/DemoCP8842.s.sol) | Plays the CP-8842 story (Volkswagen Golf GTI, SEK 24,800) on a local chain, each party signing with its own key |
| [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deploys the contract and hands out If's roles |
| [`web/index.html`](web/index.html) | Clickable prototype – switch between Customer, If handler, Workshop and Supplier |

## How the claim flows

```
 If claims system           Customer (If app)   If handler          Workshop          Supplier         Workshop          If handler / contract
 ───────────────            ────────────────    ──────────          ────────          ────────         ────────          ─────────────────────
 issueClaim()  ──► token ─► 1 Accident report ─► 2 Damage      ─► 3 Repair       ─► 4 Parts order ─► 5 Repair      ─► 6 Payout
 (mint, locked)                                  assessment        estimate                            completed         (SEK via bank)
                                                 + assign partners    │
                                                                      └─ estimate > approved? → Under review → a person decides
```

Each step is verified **once**, **in order**, and **only by the party responsible for it** ("own step only"). A record created by one party can never be changed by another.

## How the litepaper maps to the code

| Litepaper says | Code does |
|---|---|
| Non-transferable utility token, not a payment or security token (Week 3, 4) | `_update` reverts on every transfer, `approve`/`setApprovalForAll` revert, `locked()` always `true` (ERC-5192). The token is held by the contract itself – *it belongs to the claim, not a person* |
| No personal data on-chain (Week 4, 6 – GDPR, EDPB 02/2025) | Only status, amounts, a **pseudonymous holder id** (`keccak256(secretSalt, internalId)`, computed by If) and **document hashes**. Documents stay in If's systems where they can be corrected or deleted |
| Customers never need a wallet (Week 4, 5) | `CUSTOMER_RELAY_ROLE` – If's app backend records the customer's confirmation |
| Each step verified by the responsible party (Week 5) | `verifyStep()` + `_requireResponsible()`; workshop and supplier must be **assigned** to the claim |
| Tiered API access controlled by the token (Week 3, 5) | Partner registry with `Tier.Basic / Submit / Priority`; only `Submit`+ may verify. `Basic` is free so small workshops aren't shut out (Week 6 ethics) |
| Audit trail for disputes, audits and reporting | `StepVerified` events + a rolling `auditHead` hash per claim |
| Hash of audit trail anchored on a public chain (Week 6) | `recordAnchor(root, "polygon", txRef)` |
| Automated, milestone-based payouts – phase 3, after legal review | `autoPayoutEnabled` (off by default). When on, a verified *Repair completed* releases the payout automatically |
| Payout stays in SEK through ordinary banks | The contract only emits `PayoutReleased(claimId, amountSEK)`; If's payment system pays via the bank |
| Rejections must go to a person (Week 6, GDPR art. 22) | Automation can **never** reject. `resolveReview()` needs an If handler, and **not the same handler** who flagged the claim (four-eyes) |
| Reputation signal / fast-track (Week 3) | `verifiedSteps` and `onTimeSteps` (within `slaSeconds`, default one working day) → `isFastTrack()`. Partners can read their own score |
| Permissioned network, If accountable (Week 4, 6 – DORA) | OpenZeppelin `AccessControl` roles, `pause()` for incident handling |

## Run it

You need [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules https://github.com/elinthim/claimpass
cd claimpass

forge build
forge test -vv
```

### Play the CP-8842 demo on a local chain

```bash
anvil                                   # terminal 1 – local EVM chain
forge script script/DemoCP8842.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
```

Output:

```
CP-8842 | 0 of 6 verified | Token issued for the claim
CP-8842 | 1 of 6 verified | Accident report verified by customer
CP-8842 | 2 of 6 verified | Damage assessment verified by If  (= prototype screen: awaiting repair estimate)
CP-8842 | 3 of 6 verified | Repair estimate verified by workshop
CP-8842 | 4 of 6 verified | Parts order verified by supplier
CP-8842 | 5 of 6 verified | Repair completed verified by workshop
CP-8842 | 6 of 6 verified | Payout released - claim closed
Locked / non-transferable: true
```

### Open the web prototype

Open `web/index.html` in a browser, or turn on **GitHub Pages** (Settings → Pages → Source: *GitHub Actions*) and the included workflow publishes it.

Things to try:
- Switch role to **Customer** and press *Try anyway* on the workshop's step → `NotResponsibleParty`
- Press **Try to transfer token** → `NonTransferable`
- As **Workshop**, enter an estimate above SEK 24,800 → claim goes to a person; as **If handler**, try rejecting as Marcus Lind (blocked, four-eyes) and then as Sara Holm
- Turn on **Automatic payout** and finish the claim

### Deploy to a network

```bash
export PRIVATE_KEY=0x...      # If governance key (multisig in production)
export ISSUER=0x... HANDLER=0x... CUSTOMER_RELAY=0x... PARTNER_MANAGER=0x...
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

The litepaper's target is a **private, permissioned EVM chain** (e.g. Hyperledger Besu) run by If and its partners. The contract is standard Solidity, so it also runs on Anvil, a Besu dev network or a testnet such as Polygon Amoy.

## Roadmap (from the litepaper)

| Phase | Months | In the code |
|---|---|---|
| 1. Pilot – car claims, status verification only | 0–6 | Steps 1–5, manual payout (`autoPayoutEnabled = false`) |
| 2. Partner platform – API tiers, SaaS fee | 7–10 | Partner `Tier`s (billing itself is off-chain) |
| 3. Automatic payouts, person reviews rejections | 11–15 | `autoPayoutEnabled = true`, `resolveReview()` |
| 4. Home insurance, other Nordic markets | 16–18+ | `ProductLine.Home` already supported |

## Limitations and open points

- **Course prototype, not audited.** A security and smart contract audit is in the budget (Week 8) before anything real.
- **MiCA:** the assumption that a non-transferable, unsold token falls outside MiCA must be confirmed by a lawyer.
- The web prototype simulates the contract rules in the browser and uses demo data; it is not connected to a chain.
- As the litepaper's critical review says: a normal shared database might solve much of this more cheaply. The pilot should compare the two.
- Not an If product and not affiliated with If P&C Insurance. All names, numbers and hashes are demo data.

## License

MIT
