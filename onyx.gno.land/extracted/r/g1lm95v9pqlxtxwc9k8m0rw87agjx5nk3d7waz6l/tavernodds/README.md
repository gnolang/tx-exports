# Tavern Odds

Binary prediction markets on Gno.land (Onyx testnet), priced by an LMSR.
Gnome Tavern hackathon entry — no "Gno" prefix in the name, by design.

## What it is

Anyone creates a YES/NO market (question + close time + liquidity `b` +
a resolver address) by seeding it with at least `ceil(b*ln(2))` ugnot.
Traders buy/sell YES/NO shares priced by a logarithmic market scoring
rule; the resolver sets the outcome after close; after a 24h dispute
window, winning shares redeem 1 ugnot each and losing shares are worth 0.
Shares are GRC20 tokens (two per market, YES/NO).

Ported from the Solana Prophet program (same lifecycle, same solvency
rule `seed >= b*ln(2)`), adapted to Gno idioms. Amounts are ugnot
(1 GNOT = 1,000,000 ugnot). All money math is `int64`.

## Files

| File | What |
|---|---|
| `market.gno` | Market lifecycle: create/buy/sell/resolve/redeem + read views |
| `render.gno` | `Render` — market list, detail pages, how-to-play |
| `lmsr.gno` | Fixed-point LMSR pricing (math agent) |
| `lmsr_test.gno` | Pricing tests (math agent) |
| `market_test.gno` | Lifecycle tests — behaviour, not exact pricing values |
| `gnomod.toml` | Module `gno.land/r/g1lm95v9pqlxtxwc9k8m0rw87agjx5nk3d7waz6l/tavernodds` |

`../vendor/` holds local copies of the `gno.land/p/nt/*` packages the
realm imports (GRC20, seqid, ufmt, avl, sanitize, test helpers) so
`gno test` works offline — `gno mod download` cannot reach the chain
RPC from this VM (Go client TLS failure; curl works). On-chain, the
imports resolve to the already-deployed packages; the vendor tree is
never deployed (`gnokey maketx addpkg` only sends this directory).
`../gnowork.toml` (empty) marks the workspace so the tooling resolves
the vendored packages.

## Design choices worth knowing

- **Clock is block time.** Gno has no wall-clock syscall; `time.Now()`
  returns the block time (the chain sets it from the block header).
  Close/dispute times are unix seconds of block time.
- **Payments are push-only.** Gno has no `transferFrom`. Buyers and
  creators attach ugnot with `-send`; the realm checks
  `unsafe.OriginSend()` **and** requires a direct EOA caller
  (`cur.Previous().IsUserCall()`) — the pair is mandatory, because an
  intermediate `maketx run` realm could otherwise spend the envelope
  and leave `OriginSend()` describing a phantom payment. Payouts use a
  fresh `BankerTypeRealmSend` banker per call.
- **Buys cost delta + 1 ugnot.** The fixed-point delta truncates, so
  charging one extra ugnot keeps the strict solvency direction
  (sells pay the raw delta). `QuoteBuy` returns exactly what `Buy`
  charges.
- **Double-redeem is prevented twice:** a redeemed flag per
  (market, user) and burning the winning shares on redeem.
- **No fees, no registry, no sweep.** Shares are not registered in
  `grc20reg` (per-market `YES1`/`NO1` symbols would collide in its
  symbol-keyed index). Leftover vault funds stay locked after all
  redemptions; a creator sweep is future work.
- **Dispute window is 24h** (`DisputeWindow = 86400`) between resolve
  and redeem.

## Test

```bash
export PATH="$HOME/.gno/bin:$PATH" GNOROOT="$HOME/.gno/src"
gno test ./...   # 15 tests: 8 pricing + 7 lifecycle, all PASS
```

Test note: `testing.SetRealm` must be called directly from the test
function, never via a helper — the realm override attaches to the
frame `SetRealm` is called from. See the header comment in
`market_test.gno`.

## Use (after Onyx deploy; needs faucet funds — currently blocked)

```bash
# create (attach at least ceil(b*ln2) ugnot; b=1,000,000 -> 693,148)
gnokey maketx call -send 700000ugnot -gas-fee 5000ugnot -gas-wanted 5000000 \
  -chainid onyx-1 -remote https://rpc.latest.testnets.gno.land:443 <key> \
  CreateMarket "Will it rain tomorrow?" 1796000000 1000000 <resolver-g1...>

# buy 100 YES (quote first, attach the exact cost)
gnokey maketx call -send <cost>ugnot -gas-fee 5000ugnot -gas-wanted 5000000 \
  -chainid onyx-1 -remote https://rpc.latest.testnets.gno.land:443 <key> \
  Buy 1 1 100 <maxCost>

# sell / resolve (resolver only) / redeem
gnokey maketx call ... Sell 1 1 100 0
gnokey maketx call ... Resolve 1 1
gnokey maketx call ... Redeem 1
```

Browse at `https://latest.testnets.gno.land/r/g1lm95v9pqlxtxwc9k8m0rw87agjx5nk3d7waz6l/tavernodds`.
