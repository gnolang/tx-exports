# 🍻 GnoTab — Tavern Tab on Gno

**Group expense tabs, settled on-chain.** GnoTab is a Splitwise-style shared
expense ledger implemented as a [Gno.land](https://gno.land) realm. Create a
tab for your group, record who paid for what, and the realm keeps a running
net balance per member. At any moment it reduces everyone's balances to the
shortest list of "who pays whom" payments (netting), and members record a
settlement once a debt is paid off — until the tab reads *all settled up*.

Built for the **Gnome Tavern** hackathon (DoraHacks). Target network:
**Gno.land testnet Onyx (`onyx-1`)**.

## How it works

| Function | What it does |
|---|---|
| `CreateGroup(name, members)` | Opens a new tab. The caller becomes creator + first member; `members` lists the other g1 addresses. Returns the group ID. |
| `AddExpense(groupID, amount, participants, memo)` | Records an expense paid by the caller, split equally (in ugnot) among `participants`. The indivisible remainder goes one ugnot at a time to the first participants listed. |
| `GetBalance(groupID, member)` | Net balance in ugnot: **> 0** the group owes them, **< 0** they owe the group, **0** settled. |
| `Settle(groupID, to, amount)` | Records that the caller paid `amount` ugnot of their debt to member `to` (e.g. after a real GNOT transfer) and adjusts both balances. Validates against both sides' outstanding balances. |
| `Render(path)` | The realm's UI on gnoweb: `""` lists all tabs; `g/<id>` shows one tab's live balance sheet — balances, the netted *who pays whom* list, expenses, and settlements. |

### Example flow

1. Alice creates a tab with Bob and Carol → group `1`.
2. Alice pays 900000 ugnot (0.9 GNOT) for dinner, split 3 ways →
   Alice `+600000`, Bob `-300000`, Carol `-300000`.
3. The tab's page shows: *Bob pays Alice 0.300000 GNOT · Carol pays Alice
   0.300000 GNOT*.
4. Bob pays Alice off-chain/on-chain and calls `Settle(1, <alice>, 300000)` →
   Bob is at `0`. Carol does the same → **all settled up. 🎉**

Two-way debts net automatically: if Alice covers Bob for 150 and Bob later
covers Alice for 50, the tab shows a single net debt of 100 — not two
opposite payments.

## Run it locally

Prerequisites: the Gno toolchain (this project is developed against
**gno v1.8.0**).

```bash
# Install the toolchain (precompiled binaries, no Go required)
curl -fsSL https://raw.githubusercontent.com/gnolang/gno/master/misc/install.sh | sh
export PATH="$HOME/.gno/bin:$PATH"
gno version && gnokey version

# The precompiled binaries look for the Gno stdlibs under GNOROOT.
# Point it at a checkout of the matching release:
git clone --depth 1 --branch v1.8.0 https://github.com/gnolang/gno.git ~/gno-src
export GNOROOT="$HOME/gno-src"
```

Then, in this directory:

```bash
gno fmt ./...
gno lint ./...   # must be clean
gno test ./...   # 5 unit tests: group creation, 3-way split, two-way
                 # netting, settlement pay-off, split remainder
```

> **API note:** v1.8.0 uses the current Gno realm API — exported functions
> take `cur realm` as their first parameter and read the caller from
> `cur.Previous().Address()`; addresses use the builtin `address` type.
> (The older `std.GetOriginCaller()` API no longer exists.)

## Status

- ✅ Realm implemented: groups, expenses, equal split with remainder,
  per-member net balances, greedy deterministic netting, settlements.
- ✅ `Render()` balance-sheet UI for gnoweb (index + per-group pages).
- ✅ Unit tests: **5/5 passing**; `gno lint` clean; `gno fmt` applied.
- ⏳ Not yet deployed — see the runbook below.
- 🔜 Planned hardening before/after deploy: reject non-EOA callers on
  mutating functions (`cur.Previous().IsUserCall()`), optional coin-backed
  settlement via `chain/banker` (pay the debt *through* the realm in the
  same call), member nicknames in `Render()`.

## Deploy runbook — testnet Onyx (next stage)

Network: **Onyx / Test17**, chain ID `onyx-1`,
RPC `https://rpc.onyx.testnets.gno.land:443` (alias
`https://rpc.latest.testnets.gno.land:443`), faucet https://faucet.gno.land,
explorer https://onyx.testnets.gno.land. Onyx state persists across
upgrades, so the deployed realm will not vanish mid-hackathon.

```bash
export PATH="$HOME/.gno/bin:$PATH"

# 1) Create a dedicated hackathon key (testnet only — never reuse for real funds)
gnokey add gnotab-dev
gnokey list   # note the g1... address

# 2) Fund it from the faucet: open https://faucet.gno.land,
#    paste the g1 address, select the current testnet (Onyx), submit.
#    One request is enough for deploy + test calls.

# 3) Verify the balance landed
gnokey query bank/balances/<g1-address> \
  -remote https://rpc.latest.testnets.gno.land:443

# 4) Point the module path at your own address (namespace rule on Onyx:
#    permissionless realm paths live under your own g1 address).
#    In gnomod.toml set:  module = "gno.land/r/<g1-address>/gnotab"
#    and update the two /r/gnotab/gnotab links in gnotab.gno's Render().

# 5) Deploy (AddPackage)
gnokey maketx addpkg \
  -pkgpath "gno.land/r/<g1-address>/gnotab" -pkgdir . \
  -gas-fee 5000ugnot -gas-wanted 5000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 gnotab-dev

# If the package is refused, look up the exact reason at
# https://gpas.latest.testnets.gno.land with the full package path.

# 6) Smoke-test with real calls (the package activates a few seconds
#    after addpkg; if a call fails immediately, wait and retry)
gnokey maketx call \
  -pkgpath "gno.land/r/<g1-address>/gnotab" \
  -func "CreateGroup" -args "Tavern Night" -args "<member-g1-address>" \
  -gas-fee 2000ugnot -gas-wanted 2000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 gnotab-dev

# 7) Open the live tab book in the explorer:
#    https://onyx.testnets.gno.land/r/<g1-address>/gnotab
```

## Layout

```
gnotab/
├── gnomod.toml      # module gno.land/r/gnotab/gnotab (gno 0.9)
├── gnotab.gno       # the realm: state, logic, netting, Render()
├── gnotab_test.gno  # unit tests
└── README.md
```
