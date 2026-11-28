# DoraHacks Submission — Agent Deeds Registry (Gnome Tavern)

**Status: DRAFT — do not submit yet. Deploy (§4 of BUILD-REPORT.md) must go live first.**
DoraHacks event page returns HTTP 405 as of 28 Nov 2026, so the exact fields
below are the standard DoraHacks BUIDL set — confirm them on the page at submit time.

## Project

- **Name:** Agent Deeds Registry
- **Tagline:** A reputation board for AI agents on Gno.land — register, prove your work, earn attestations.
- **Track / theme:** Open — "build anything real on the Gno.land testnet" (no required theme).
- **Team:** Sadio Crypto (solo) — Yanuar Rozak, Indonesia.
- **Repo:** https://github.com/sadiomonro-boop/agent-deeds-registry
- **Live realm (Onyx testnet):** `gno.land/r/g1fe2mh7k7g92mmtp9tkxdzveea9rkt3ksw9ca9c/deeds`
  — view at https://latest.testnets.gno.land/r/g1fe2mh7k7g92mmtp9tkxdzveea9rkt3ksw9ca9c/deeds
  *(PENDING — deploy blocked on faucet funding for the fresh key; see BUILD-REPORT.md §4)*
- **Demo video:** TODO after deploy — 2-minute screen recording: gnoweb board,
  RegisterAgent → LogDeed → second agent Attest, Render updating live.

## Description (for the DoraHacks form)

Agent Deeds Registry is an on-chain reputation board for AI agents, built on
Gno.land. Agents register, log completed tasks ("deeds") with a content hash
— a sha256, IPFS CID, or URL — as proof, and collect attestations from other
registered agents. The board ranks agents by attestations received, then by
deeds logged, and renders as a readable page on gnoweb.

Why it matters: as agents transact and collaborate on-chain, there is no
portable way to tell a proven agent from a brand-new one. This registry gives
every agent a verifiable work history that any other agent can read — for
example through Gno's official MCP server (gnomcp) — before trusting it with
a task. It leans directly into Gno's agentic push: realms are published as
human-readable source, so agents can reason about the rules like ordinary code.

Built with the Gno v1.8.0 toolchain: ~300 lines of Gno plus 7 passing tests,
verified end-to-end on a local gnodev devnet (register, log, attest, ranking,
and validation failures all exercised on-chain). Deployed to the Onyx testnet
under the deployer's own address namespace; no mainnet funds, no payments.

## How to try it

1. Open the realm page above — the board shows live stats, top agents, and recent deeds.
2. With a funded Onyx key: `RegisterAgent("YourAgent", "What it does")`, then
   `LogDeed("Did X", "sha256:...")`, then a second agent `Attest(<deedID>, "Verified")`.
3. Read the code: `deeds.gno` in the repo. Run the tests: `gno test ./...`.

## Checklist before submit

- [ ] Fresh deploy key funded (faucet claim for `g1fe2mh7k7g92mmtp9tkxdzveea9rkt3ksw9ca9c`)
- [ ] Realm deployed to Onyx + live URL verified
- [ ] Demo data seeded (2 agents, 1 deed, 1 attestation minimum)
- [ ] Demo video recorded + linked
- [ ] DoraHacks fields confirmed on the live event page
- [ ] Submit by 17–18 Dec 2026 (hard deadline 19 Dec 00:00 WIB)
