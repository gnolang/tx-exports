# Arisan — Rotating Savings Circle on Gno.land

> Built for the [Gnome Tavern Hackathon](https://dorahacks.io/hackathon/gnome-tavern) by Gno (23 Nov – 18 Dec 2026). Testnet only — no real funds.

## What is arisan, and why does it matter?

**Arisan** is an Indonesian tradition older than any bank: a group of neighbours,
coworkers or family each contribute a fixed amount every week or month, and each
round one member takes the entire pot. It is savings, credit and community in a
single ritual — and it runs entirely on trust.

That trust is also its weakness. An organizer can disappear with the pot, a
member can quietly skip payments, and the rotation order can be "reinterpreted".
This project moves the trust on-chain: the rules (who joined, who paid, whose
turn it is, where the money goes) and the money itself live in a Gno realm.
Nobody — not even the organizer — can take the pot out of turn, hide an unpaid
round, or change the rotation.

## What this project does

A Gno realm (`gno.land/r/<addr>/arisan`) implementing a full rotating savings
circle:

- **Multiple circles** — anyone can create a circle (name, contribution per
  round in ugnot, maximum members). The creator is the organizer.
- **Join order is rotation order** — members join while the circle is open;
  first to join, first to take the pot. Deterministic, no randomness.
- **Deposits** — every round, each member pays exactly the contribution via
  the `-send` envelope. Wrong amount, wrong denom or extra coins abort the
  transaction. Unpaid members are flagged **BELUM BAYAR** on the dashboard.
- **Advance** — the organizer advances the round only when *every* member has
  paid. The pot (members × contribution) is paid from the realm to the member
  whose turn it is, then the next round begins. The rotation wraps around, so
  everyone eventually takes the pot.
- **Exact money accounting** — all amounts are int64 ugnot; the realm refuses
  to pay out if its tracked pot does not equal members × contribution.
- **Live dashboard** — the realm's `Render()` shows every circle, members in
  rotation order, who has paid, whose turn it is, the current round and the
  pot size.

A static frontend (`docs/`, GitHub Pages) shows the live realm state and the
copy-paste commands to use it.

## Live links

- Realm (Onyx testnet): https://latest.testnets.gno.land/r/g1u9frcg00ncx6ws8h6whtkdg2z4gsv0hjvzh20w/arisan
- Frontend: https://ketong112.github.io/arisan/
- Hackathon: https://dorahacks.io/hackathon/gnome-tavern

## How to use it (Onyx testnet)

Install the [Gno toolchain](https://docs.gno.land/builders/quickstart/), fund a
key at https://faucet.gno.land (Onyx faucet), then:

```sh
REALM="gno.land/r/g1u9frcg00ncx6ws8h6whtkdg2z4gsv0hjvzh20w/arisan"
RPC="https://rpc.onyx.testnets.gno.land:443"

# 1. Create a circle (name, contribution in ugnot, max members)
gnokey maketx call -pkgpath "$REALM" -func CreateCircle \
  -args "Arisan RT 05" -args 1000 -args 4 \
  -gas-fee 20000ugnot -gas-wanted 10000000 \
  -chainid onyx-1 -remote $RPC mykey

# 2. Join circle #1
gnokey maketx call -pkgpath "$REALM" -func JoinCircle -args 1 \
  -gas-fee 20000ugnot -gas-wanted 10000000 \
  -chainid onyx-1 -remote $RPC mykey

# 3. Organizer starts round 1
gnokey maketx call -pkgpath "$REALM" -func StartCircle -args 1 \
  -gas-fee 20000ugnot -gas-wanted 10000000 \
  -chainid onyx-1 -remote $RPC mykey

# 4. Deposit your contribution for the round
gnokey maketx call -pkgpath "$REALM" -func Deposit -args 1 \
  -send 1000ugnot -gas-fee 20000ugnot -gas-wanted 10000000 \
  -chainid onyx-1 -remote $RPC mykey

# 5. Organizer advances when everyone has paid
gnokey maketx call -pkgpath "$REALM" -func AdvanceRound -args 1 \
  -gas-fee 20000ugnot -gas-wanted 10000000 \
  -chainid onyx-1 -remote $RPC mykey
```

Read the state any time:

```sh
gnokey query vm/qeval -remote $RPC -data "$REALM.Render(\"/1\")"
```

## Development

```sh
# Install the toolchain (see SETUP notes in the project workspace)
# Run the unit tests (Gno VM tests, no chain needed)
gno test ./...

# Run a local chain with hot reload and try the full flow
gnodev local .
```

Tests cover: circle creation rules, join/start rules, deposit rules (wrong
amount / wrong denom / non-member / double pay), the full 4-round rotation
with exact balance assertions, independence of two circles, and Render output.

## License

MIT. See [LICENSE](LICENSE).
