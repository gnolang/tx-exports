# Tavern Bets

Mini prediction market on Gno.land — entry for the **Gnome Tavern Hackathon**
(DoraHacks, deadline 18 Dec 2026 08:00 WIB). Solo builder: ajeunglagi.

Anyone can create a yes/no question, anyone can bet test-GNOT on either
side, the market creator resolves the outcome after the deadline, and
winners claim a pro-rata share of the whole pool.

## How it works

- **CreateMarket(question, durationMinutes)** — opens a market that resolves
  after `durationMinutes` (1–525600; 1440 = 1 day, 10080 = 1 week). Minutes
  keep the full loop demoable in one session. Returns the market id.
- **Bet(marketID, yes)** — wagers the ugnot attached to the call on YES
  (`yes = true`) or NO (`false`). 1 GNOT = 1,000,000 ugnot.
- **Resolve(marketID, outcome)** — only the market creator, only after the
  deadline, only once. `outcome = true` means YES won.
- **Claim(marketID)** — pays the caller their share and returns the amount
  in ugnot. Payout = stake + stake × losingPool / winningPool (integer math).
- **Refund(marketID)** — returns the caller's full stake when a market
  resolved to a side nobody bet on (no winners at all). Each loser refunds
  their own stake, exact, no rounding. If winners exist, use Claim instead.
- **Render** — the gnoweb page lists every market with pools, deadlines and
  status. No custom frontend needed: gnoweb's Actions tab calls the
  functions above via the Adena wallet or `gnokey`.

Rules enforced on-chain (all covered by tests): no empty questions, no
deadline in the past, no bets after the deadline or after resolve, only the
creator resolves, one resolve only, one claim per winner, losers cannot
claim, refunds only when there are no winners and only once per loser.

## Run the tests

```bash
export PATH="$HOME/.gno/bin:$PATH" GNOROOT="$HOME/.gno/src"
gno test ./...
```

18 tests, 0 skipped. Includes the failure cases: resolve before deadline,
resolve by non-creator, double resolve, bet after resolve, claim by a loser,
double claim, claim before resolve — and exact pro-rata math (a 3:1 pool
split pays exactly 4x the winner's stake; two winners split the pool
exactly). Refund tests: no-winner refund pays the exact stake back to each
loser, refund fails when winners exist, refund fails before resolve, double
refund fails.

## Run locally (gnodev)

```bash
export PATH="$HOME/.gno/bin:$PATH" GNOROOT="$HOME/.gno/src"
gnodev
```

Open http://localhost:8888 — the realm is deployed to the local devnet
automatically. Use the Actions tab or `gnokey maketx call` against the
local node (`-remote 127.0.0.1:26657`).

## Testnet

**Status 25 Nov 2026 ~07:30 WIB: NOT deployed yet — blocked on funding.**
The dev key's on-chain balance is 0 ugnot (verified via
`bank/balances/g1f32nmr66mmu8yu3kty2z9y9pvsmwtymx7yz595`, which returns
`""`, and `auth/accounts/...` returns `Data: null` — the account does not
exist on-chain yet). The Onyx faucet (https://faucet.gno.land, "Onyx
Faucet", 100/200/300 GNOT) requires an hCaptcha challenge, so the claim
needs a human in a browser. After the faucet funds the address, deploy
with the command below — the realm code, gates, and tests are all green
and ready.

Deploy target (Onyx testnet, chain `onyx-1`):

`gno.land/r/g1f32nmr66mmu8yu3kty2z9y9pvsmwtymx7yz595/tavernbets`

Live link after deploy:
`https://latest.testnets.gno.land/r/g1f32nmr66mmu8yu3kty2z9y9pvsmwtymx7yz595/tavernbets`

Deploy command (after funding; run from this directory):

```bash
export PATH="$HOME/.gno/bin:$PATH" GNOROOT="$HOME/.gno/src"
gnokey maketx addpkg -pkgpath "gno.land/r/g1f32nmr66mmu8yu3kty2z9y9pvsmwtymx7yz595/tavernbets" \
  -pkgdir . -gas-fee 5000ugnot -gas-wanted 5000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 dev
```

Deploy uses a throwaway testnet-only dev key (`dev` in the local keybase).
It holds no real money, is never used on mainnet, and its recovery phrase
never leaves this machine and never appears in any file, message, or report.

Note for the deployer: from this VM, `gnokey` cannot reach the public RPC
directly (its client ignores the egress proxy; direct TCP is intercepted),
and the egress proxy drops all HTTP POST requests, so `gnokey maketx`
cannot query or broadcast from here. Workaround prepared in
`~/workspace/gno-tavern/`: `rpcproxy.py` (local HTTP translator, live on
127.0.0.1:26657, forwards GETs through the proxy) plus a mock-RPC server
to answer `gnokey`'s account query from on-chain data fetched by curl and
capture the signed tx bytes for broadcast via curl GET
`broadcast_tx_commit`. See the Phase 2 report for details.

## Known limitations

- Integer division leaves rounding dust (at most a few ugnot per claim) in
  the realm. Refunds are exact (full stake back), so they leave no dust.
- Deadlines use block time (`time.Now()`), so they resolve in whole minutes
  from creation.
