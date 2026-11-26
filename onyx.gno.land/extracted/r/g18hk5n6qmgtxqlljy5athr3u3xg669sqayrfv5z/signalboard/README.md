# SignalBoard

An on-chain trading signal board on **Gno.land Onyx testnet** (chain `onyx-1`),
built for the Gnome Tavern hackathon.

Anyone can post a structured trading signal (asset, direction, reference
price, short rationale). The author later resolves their own signal as won or
lost. The realm keeps a **public, verifiable per-author track record**
(posted / won / lost / win rate) and renders the board on gnoweb — no separate
frontend, no off-chain database: the performance record lives on-chain and
anyone can audit it.

## Deployment status

| Item | Value |
|---|---|
| Realm path | `gno.land/r/g18hk5n6qmgtxqlljy5athr3u3xg669sqayrfv5z/signalboard` |
| Deployer address | `g18hk5n6qmgtxqlljy5athr3u3xg669sqayrfv5z` |
| gnoweb (once live) | https://onyx.testnets.gno.land/r/g18hk5n6qmgtxqlljy5athr3u3xg669sqayrfv5z/signalboard |
| Status | **PENDING FUNDING** — see below |
| addpkg tx hash | _(pending)_ |
| Example signal tx hashes | _(pending)_ |
| gpao approval | _(not yet submitted)_ |

**Why pending:** the Onyx faucet (https://faucet.onyx.testnets.gno.land)
requires an hCaptcha token minted in a real browser session (JSON-RPC `drip`
with `meta.captcha`); it cannot be claimed from a headless shell. The deployer
account exists and everything else is built, tested and scripted. The moment
the address is funded, deployment is a single command:

```bash
./deploy.sh                          # deploys + waits for gpao activation
python3 bridge/post_signals.py --live  # posts 3 example signals from
                                       # live public prices
```

`deploy.sh` polls the render query until the realm answers, because new
packages on Onyx pass the **gpao (package approvals oracle)** queue before
they become callable; if approval stalls, check the rejection reason on the
gpas testnet explorer.

## Architecture

```
                 gnokey maketx call                 gnoweb / vm/qrender
  Python bridge ───────────────►  SignalBoard realm ───────────────► board
  (bridge/post_signals.py)        (signalboard.gno)                  (public)
        │                               │
        │ live prices                   │ PostSignal / ResolveSignal
        ▼                               │ per-author stats + events
  data-api.binance.vision               ▼
  (public, no key)                 Onyx testnet (onyx-1)
```

- **`signalboard.gno`** — the realm. State: a slice of `Signal` structs and a
  per-author `AuthorStats` map. Written for the current Gno realm API
  (`cur realm` crossing functions, caller identity from `cur.Previous()`,
  direct-user-call guard via `IsUserCall()`). Free-text fields are sanitized
  on write so user input cannot break out of the markdown board rendering.
  Emits `SignalPosted` / `SignalResolved` events.
- **`signalboard_test.gno`** — 5 tests (post, validation + sanitization,
  resolve-as-won incl. non-author/double-resolve rejection, resolve-as-lost,
  rendering). All pass: `gno test .` → `ok`.
- **`bridge/post_signals.py`** — small Python bridge (stdlib only). Reads a
  JSON list of signals — or builds three from live public prices with
  `--live` (naive 24h-momentum direction) — and posts each via
  `gnokey maketx call`, recording tx hashes in `bridge/last_run.json`.
- **`deploy.sh`** — balance check → `gnokey maketx addpkg` → poll render
  until the realm is live through the gpao queue.

### Realm API

| Function | Kind | Description |
|---|---|---|
| `PostSignal(cur realm, asset, direction, refPrice, note string) uint64` | tx | Post a signal; direction `long`/`short`; returns the signal ID. Emits `SignalPosted`. |
| `ResolveSignal(cur realm, id uint64, won bool)` | tx | Author-only resolution of an open signal. Emits `SignalResolved`. |
| `TotalSignals() int` / `OpenSignals() int` | query | Board counters. |
| `Render(path string) string` | query | `""` = board + leaderboard; `"signal/<id>"` = one signal. |

## Run the tests locally

Toolchain: official Gno **v1.8.0** binaries (`gno`, `gnokey`, `gnodev` from
the gnolang/gno GitHub release, checksums verified). The standalone `gno`
binary needs the matching source tree for its stdlibs:

```bash
export GNOROOT=/path/to/gno-v1.8.0-source
cd app/
gno test .        # 5/5 pass
gno lint .
```

## Network notes (this VM)

`gnokey`'s Go RPC client ignores HTTP(S)_PROXY and dials directly; on
machines whose direct egress is intercepted, all chain traffic must go
through a local forwarder that tunnels via the egress proxy:

```bash
python3 ../rpc_forwarder.py 26657 rpc.onyx.testnets.gno.land &
# then use -remote http://127.0.0.1:26657 (the default in deploy.sh/bridge)
```

On an unrestricted network, skip the forwarder and use
`GNO_REMOTE=https://rpc.onyx.testnets.gno.land:443`.

## Keys

The deployer key (`gnokey` name `signalboard`) and its mnemonic backup live
outside this repository in `~/.keys-gno/` (dir 700, files 600). The mnemonic
is never printed, logged, or committed. The key password is in
`~/.keys-gno/keypass.txt` and is fed to gnokey via
`-insecure-password-stdin` by the scripts.

## Test evidence

```
$ gno test -v .
=== RUN   TestPostSignal            --- PASS
=== RUN   TestPostSignalValidation  --- PASS
=== RUN   TestResolveSignal         --- PASS
=== RUN   TestResolveLost           --- PASS
=== RUN   TestRender                --- PASS
ok      .   ~2s
```

Bridge dry-run and live-price signal generation verified; a real
`PostSignal` call was attempted and correctly fails at simulation today
only because the package is not deployed yet and the account is unfunded —
the full path (bridge → gnokey → forwarder → Onyx RPC) responds end to end.
