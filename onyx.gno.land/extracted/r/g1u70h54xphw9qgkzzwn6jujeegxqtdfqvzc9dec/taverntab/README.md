# TavernTab — a tavern tab (escrow) realm on Gno.land

At the Gnome Tavern you don't pay per drink — you **open a tab**. The realm
holds your GNOT, and the tab is later **settled** (the payee gets paid) or
**cancelled** (you get refunded in full). Only the payer can settle or cancel
their own tab, and only once. Everything is on the record: the realm's
`Render` board shows every tab and how much the tavern is holding, readable
in a browser on gnoweb with no wallet.

Built for the Gnome Tavern Hackathon (DoraHacks). Entrant: Indra Dwi Junianto.

## Realm

Path: `gno.land/r/ghea12/taverntab` (namespace to be confirmed/claimed at
testnet deploy time)

| Function | What it does |
| --- | --- |
| `OpenTab(payee, memo)` | Payable. Send ugnot with the call; the realm records tab {id, payer, payee, amount, memo, status=open} and returns the id. Direct user calls only. |
| `SettleTab(id)` | Payer only, tab open: the realm sends the held amount to the payee; status=settled. |
| `CancelTab(id)` | Payer only, tab open: full refund to the payer; status=cancelled. |
| `GetTab(id)` | Read-only snapshot of one tab. |
| `HeldTotal()` | ugnot currently held across all open tabs. |
| `Render("")` / `Render("<id>")` | The public board / a single tab, rendered by gnoweb. |

## Develop

Toolchain: official precompiled binaries in `~/.gno/bin` (v1.8.0). The
binaries need the matching source tree for stdlibs/examples:

```sh
export PATH="$HOME/.gno/bin:$PATH"
export GNOROOT="$HOME/.gno/src/gno-1.8.0"   # v1.8.0 source tarball, files only (nothing built from it)

gno test .        # unit tests
gno lint .
gnodev local .    # local devnet: realm auto-deploys, gnoweb on http://127.0.0.1:8888
```

Local dependency note: the realm imports three small public packages
(`gno.land/p/nt/ufmt/v0`, `gno.land/p/nt/markdown/sanitize/v0`, and the test
helpers `testutils`/`uassert`). On this machine the toolchain's on-chain
package download is blocked by the sandbox proxy, so the workspace root
(`~/workspace/hackathons/gnome/`) carries a `gnowork.toml` plus pristine
copies of those packages (and their one transitive dep, `p/onbloc/diff/v0`)
under `gno.land/p/...`, which the tooling resolves locally. On an
unrestricted machine the same imports resolve from the chain and the copies
are unnecessary.

## Status

Phase 1 (local) complete: tests green, both escrow cycles proven on a local
`gnodev` devnet. See `../EVIDENCE.md`. Testnet (Onyx) deployment is phase 2.
