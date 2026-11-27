# TavernPay — recurring payment mandates on Gno.land

A payer locks an escrow of `amount x maxPayments` ugnot and names a payee.
Anyone (a keeper) can execute a payment once it is due by block height;
the realm pays `amount` ugnot from escrow to the payee. The payer can
cancel at any time and get the remaining escrow refunded.

Built for the **Gnome Tavern Hackathon** (DoraHacks, Gno.land) — target:
a $500 Builder Award. Realm path:

```
gno.land/r/g1h2fd0ykqkfgh6heggn6uh0r9qnxz9ujpka5fce/tavernpay
```

## Functions

| Function | Who | What |
|---|---|---|
| `CreateMandate(payee, amount, intervalBlocks, maxPayments)` | payer, direct user call, with `-send amount*maxPayments ugnot` | Opens a mandate, returns its ID. First payment due at `current height + intervalBlocks`. |
| `ExecuteMandate(id)` | anyone (keeper) | Pays one due installment to the payee. Panics if not due / inactive / complete. |
| `CancelMandate(id)` | payer only | Closes the mandate, refunds remaining escrow to the payer. |
| `GetMandate(id)` | anyone | One mandate (copy). |
| `ListMandates()` | anyone | All mandates (copy — callers cannot mutate realm state). |
| `MandateCount()` | anyone | How many mandates exist. |
| `RealmBalance()` | anyone | Realm's current ugnot balance. |
| `Render(path)` | anyone | Markdown dashboard of all mandates. |

## Security design

- Caller identity from `cur.Previous()`; no `cur.IsCurrent()` guard
  (always true inside a crossing function).
- `CreateMandate` accepts payment via the `-send` envelope, so it
  requires `cur.Previous().IsUserCall()` (NOT `IsUser()`, which also
  accepts maketx-run ephemeral realms that could pre-consume the
  envelope), paired with `runtime.AssertOriginCall()`.
- State is mutated before any coin movement (CEI).
- `Render` never echoes user-controlled strings: the only inputs are
  typed bech32 addresses and integers.

## Verify (needs a working Gno toolchain — see blocker below)

```sh
export PATH="$HOME/.gno/bin:$HOME/go-dist/bin:$PATH"
cd ~/workspace/gnome-tavern/tavernpay
gno fmt ./...
gno lint ./...
gno test ./...          # 6 tests: create, bad inputs, full payment flow, cancel, list, render
```

Local devnet:

```sh
gnodev .                 # serves the realm at http://localhost:8888
```

## Deploy to Onyx testnet (after faucet claim)

```sh
# key already exists: gnokey name "tavern", address g1h2fd0ykqkfgh6heggn6uh0r9qnxz9ujpka5fce
gnokey maketx addpkg --pkgpath "gno.land/r/g1h2fd0ykqkfgh6heggn6uh0r9qnxz9ujpka5fce/tavernpay" \
  --pkgdir ~/workspace/gnome-tavern/tavernpay \
  --deposit 100000000ugnot --gas-fee 1000000ugnot --gas-wanted 2000000 \
  --broadcast --chainid onyx-1 --remote https://rpc.testnet.gno.land:443 tavern

# demo: create a mandate of 100 ugnot x 3, every 100 blocks
gnokey maketx call --pkgpath "gno.land/r/g1h2fd0ykqkfgh6heggn6uh0r9qnxz9ujpka5fce/tavernpay" \
  --func CreateMandate --args "g1<...> 100 100 3" --send 300ugnot \
  --gas-fee 1000000ugnot --gas-wanted 2000000 \
  --broadcast --chainid onyx-1 --remote https://rpc.testnet.gno.land:443 tavern
```

## ⚠️ Toolchain blocker (27 Nov ~15:00 WITA)

The binary-only Gno install (`install.sh`, default mode) ships binaries
whose `GNOROOT` is baked to the CI build path `/__w/gno/gno`, which does
not exist on this VM — so `gno fmt`, `gno lint`, `gno test` and `gnodev`
all fail with `unable to load "/__w/gno/gno/gnovm/stdlibs"`. The only
supported fix is the official installer's `--from-source` mode (clone
the repo + `make install`, source lands in `~/.gno/src` and the built
binaries get a working GNOROOT). That step is a parent decision — it was
NOT run by this task. Until then the realm is written and syntax-checked
(`gofmt -e` passes) but NOT verified by `gno test` / `gnodev`.

Stdlib APIs used were verified by reading the gno source tree:
`banker.NewBanker(BankerTypeRealmSend)`, `NewReadonlyBanker().GetCoin`,
`Coins.AmountOf`, `runtime.ChainHeight`, `runtime.AssertOriginCall`,
`unsafe.OriginSend`, `cur.Previous().IsUserCall()/Address()`,
`address.String()`.
