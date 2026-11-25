# TavernEscrow — On-Chain Milestone Bounty Escrow & Hunter Reputation Realm (Gno.land)

> **Gnome Tavern Hackathon (`$20,000` in GNOT · DoraHacks)**
> Package name intentionally omits the `"Gno"` prefix per hackathon naming guidelines.

`TavernEscrow` is a pure-Gno (`v1.8.0`) smart-contract realm that enables trust-minimized on-chain bounties on Gno.land: sponsors lock native `ugnot` into realm escrow, contributors submit verifiable `https://` proofs of work, and sponsors atomically release payouts (or reject/reopen or cancel/refund)—all browsable directly through a zero-frontend `gnoweb` Markdown dashboard (`Render(path)`) with an on-chain **Verified Hunter Reputation** leaderboard.

---

## Key Features & Gno v1.8.0 Security Hardening

- **Atomic `ugnot` Escrow (`CreateBounty`):**
  - Enforces `cur.Previous().IsUserCall()` before reading `unsafe.OriginSend()`, preventing phantom-send draining attacks from intermediate code realms or ephemeral `maketx run` calls.
  - Locks positive `ugnot` inside the realm's bank address and indexes structured `*Bounty` records in an AVL tree (`gno.land/p/nt/avl/v0`).
- **Verifiable Proof Submission (`SubmitWork`):**
  - Validates `https://` proof URLs, blocks sponsors from self-claiming their own bounties, and transitions state `OPEN -> SUBMITTED`.
- **Checks-Effects-Interactions Settlement (`ApproveAndPay` / `RejectSubmission` / `CancelBounty`):**
  - Sponsor-gated `ApproveAndPay` mutates bounty status, lifetime escrow counters, and the hunter's on-chain `HunterStats` reputation BEFORE dispatching `banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(...)`.
  - `RejectSubmission` cleanly returns a `SUBMITTED` bounty to `OPEN` for other builders.
  - `CancelBounty` refunds exact locked `ugnot` to the sponsor.
- **Native Zero-Frontend `gnoweb` UI (`Render`):**
  - Root board (`/`): Aggregate escrow stats, reverse-chronological bounty table, and Verified Hunter Reputation table.
  - Detail view (`:bounty/<id>`): Full specification, locked reward, sponsor/hunter addresses, and clickable proof link.

---

## Verified Local Test Output (Gno `v1.8.0`)

```text
$ gno test -v .
=== RUN   TestBountyLifecycleAndEscrowPayout
--- PASS: TestBountyLifecycleAndEscrowPayout (0.10s)
--- GAS:  21366756
=== RUN   TestRejectReopensAndCancelRefundsSponsor
--- PASS: TestRejectReopensAndCancelRefundsSponsor (0.05s)
--- GAS:  12357296
=== RUN   TestCreateBountyGuards
--- PASS: TestCreateBountyGuards (0.01s)
--- GAS:  2448051
ok      . 	8.76s
```

Tests verify:
1. Full `OPEN -> SUBMITTED -> APPROVED` lifecycle + exact on-chain `ugnot` balance credit to hunter via `banker.NewReadonlyBanker()` + `HunterStats` reputation rendering.
2. Guardrails: rejecting sponsor self-claim, rejecting non-`https://` proofs, rejecting non-sponsor approval, rejecting empty titles and zero-`ugnot` escrow calls.
3. `RejectSubmission` reopening to `OPEN` and `CancelBounty` refunding exact `ugnot` back to sponsor.

---

## Quick Start & Deployment

```bash
# Run unit tests locally with Gno v1.8.0:
gno test -v .

# Deploy to Gno.land testnet via gnokey:
gnokey maketx addpkg \
  --pkgpath "gno.land/r/<your_handle>/tavernescrow" \
  --pkgdir . \
  --gas-fee 1000000ugnot \
  --gas-wanted 5000000 \
  --broadcast <keyname>
```
