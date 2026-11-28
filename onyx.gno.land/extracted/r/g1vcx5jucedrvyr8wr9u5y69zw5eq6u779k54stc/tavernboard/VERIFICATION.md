# Verification — Tavern Board

How every claim about this project was checked, what passed, what is
still pending, and the exact evidence. Written 28 Nov 2026 (WIB).

## 1. What is verified (done)

### 1.1 Toolchain (28 Nov 2026)

- Installed the official prebuilt Gno toolchain via
  `misc/install.sh` from `github.com/gnolang/gno` (script downloaded,
  inspected, then run; sha256 verified by the installer itself).
- `gno version` → **v1.8.0**; `gnokey version` → **v1.8.0**.
- A sparse checkout of the Gno repo at `~/.gno/src` (stdlib +
  `gnovm/tests/stdlibs` + `examples`) is required because the prebuilt
  `gno` binary looks for the stdlib at its build-time path
  (`/__w/gno/gno`). Used via `GNOROOT=$HOME/.gno/src` and
  `gno test -root-dir $HOME/.gno/src`.

### 1.2 Unit tests — 10/10 PASS

Command (from the project dir):

```bash
export GNOROOT=$HOME/.gno/src
gno test -v -root-dir $GNOROOT .
```

Result: **all 10 suites PASS, `ok . 4.10s`** (last run 28 Nov 2026):

| Suite | What it proves |
|---|---|
| `TestHappyPathPostClaimProofApprove` | post → claim → proof → approve; worker balance +5,000,000 ugnot exactly; locked → 0; invariant holds after every step |
| `TestCancelRefundsPoster` | cancel refunds the poster +2,000,000 ugnot exactly; locked → 0 |
| `TestExpiredRefund` | release before deadline panics; after `SkipHeights(150)` the refund succeeds; no-deadline and already-settled tasks cannot be released |
| `TestRoleGuards` | poster cannot claim own task; non-worker cannot submit/unclaim; non-poster cannot approve/reject; double-approve panics; cancel of a claimed task panics; non-poster cancel panics |
| `TestRejectAndResubmit` | reject returns task to CLAIMED with proof cleared; resubmit + approve completes |
| `TestUnclaimReopens` | unclaim re-opens the task with no worker; another user can then claim it |
| `TestPostValidation` | zero reward, empty title, empty description, past deadline, missing task id all panic |
| `TestListTasksAndStats` | newest-first ordering, status filter, limit, and all 10 `Stats()` counters |
| `TestRenderAndSanitize` | home/task/stats/guide routes render; `2.5 GNOT` formatting; `\|`, `[markdown]`, backticks in user titles are escaped; stats shows invariant PASS; unknown route → 404 |
| `TestConservationAcrossMixedFlow` | one paid + one cancelled + one expired + one open task: deposited 10,000,000 = paid 1,000,000 + refunded 5,000,000 + locked 4,000,000; both invariant computations agree |

Also: `gno fmt` clean, `gno lint` clean (no findings).

### 1.3 Local devnet smoke test (gnodev, 28 Nov 2026)

- `gnodev .` started cleanly; gnoweb at `http://localhost:8888`.
- Home page rendered: "Live Board Snapshot", "Escrowed right now",
  "Current block height", "No open tasks right now".
- Stats route (`:stats`) rendered: "Conservation invariant" +
  "Invariant holds".
- gnodev stopped afterwards; ports 8888/26657 free.

### 1.4 Onyx testnet reachability (28 Nov 2026)

- `https://rpc.onyx.testnets.gno.land:443/status` answers (JSON-RPC).
  Confirmed live via the proxy on 28 Nov 2026: network `onyx-1`,
  latest height **1,460,220**, `catching_up: false`.
- `https://onyx.testnets.gno.land/` answers HTTP 200.
- `https://faucet.gno.land` answers HTTP 200; Onyx faucet
  `https://faucet.onyx.testnets.gno.land/health` answers HTTP 200.
- `gnokey query vm/qeval` through the local proxy (see §1.5) returns a
  real value (`wugnot.BalanceOf(...)` → `(0 int64)`).
- Both dev keys have **zero balance** (accounts do not exist on-chain
  yet — expected before faucet funding):
  - poster `g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc` → empty
  - worker `g1lf8eme0xwh272yyax7kgcf3w43myedy90cg2rr` → empty

### 1.5 gnokey ↔ Onyx proxy (needed on this VM)

`gnokey`'s tm2 client ignores the VM's egress CONNECT proxy, so direct
TLS to the public RPC fails (`tls: first record does not look like a TLS
handshake`). Fix (in this repo, `scripts/gno-rpc-proxy.py`): a local
plain-HTTP reverse proxy on `127.0.0.1:26657` that forwards to
`https://rpc.onyx.testnets.gno.land:443` via the egress proxy from the
environment. Verified working: balance/qeval queries succeed through it
(3/3 consecutive `qeval` calls after a retry fix — see below).
`scripts/deploy-onyx.sh` and `scripts/demo-flow.sh` default to it
(`GNO_REMOTE` overrides) and fail fast with instructions if it is not
running. Start it with:

```bash
python3 scripts/gno-rpc-proxy.py   # leave running in the background
```

Note: the egress proxy is flaky (occasional failed CONNECTs); the proxy
retries each request up to 3 times, and its credentials are fixed at
process start — if requests start failing with 502s after a long time,
restart the proxy to pick up fresh credentials.

### 1.6 Key findings about Gno testing (documented, not hidden)

Three behaviors of `gno test` v1.8.0 were found empirically (with probe
tests) and are now encoded in the test helpers — future maintainers must
not "simplify" them away:

1. **Caller switching is frame-scoped.** `testing.SetRealm` overrides
   the `cur` realm of the *frame that calls it directly*. A helper that
   switches the caller and returns leaves the test frame's `cur`
   unchanged. Every test helper therefore takes `cur realm` as its first
   parameter, calls `SetOriginCaller`/`SetRealm` directly (no extra
   helper layer in between), and makes its `cross(cur)` call inside
   itself.
2. **Simulated `-send` must target the package address derived from the
   realm path** (`chain.PackageAddress(RealmPath)`), not `cur.Address()`:
   after the first switch, `cur` points at a user realm, so the
   simulated send would go user → user (self-send) and the realm's real
   bank balance would stay zero while accounting claims the escrow
   exists. Symptom before the fix: `Approve` failed with
   `source address <realm> has ; cannot send ...`.
3. **`revive()` only recovers panics from crossing calls** in this
   version. A panic from a plain (non-crossing) function such as
   `GetTask` propagates uncaught and fails the test — even a bare
   `panic("boom")` inside `revive` is not caught. Negative tests
   therefore go through crossing helpers; the `GetTask(999)` case was
   removed (its `mustTask` code path is already covered by the
   "claim missing task" case).

## 2. What is PENDING (blocked on faucet funding)

### 2.1 Blocker: faucet needs a browser (hCaptcha)

The Onyx faucet (`https://faucet.onyx.testnets.gno.land`, amounts
100/200/300 GNOT) requires an hCaptcha token
(site key `85609fa2-6ed6-4fe0-904c-2bae865ab6ec`). A direct JSON-RPC
`drip` call without a captcha was tried on 28 Nov 2026 and rejected:

```json
{"error":{"message":"invalid captcha request","code":-32600},"jsonrpc":"2.0","id":1}
```

A subagent cannot open a browser, so this step needs the parent agent
(a browser task on https://faucet.gno.land) or the user (two taps on
their phone). Exact funding needed:

| Key | Address | Amount |
|---|---|---|
| `tavern-poster` (deployer) | `g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc` | 100 GNOT |
| `tavern-worker` | `g1lf8eme0xwh272yyax7kgcf3w43myedy90cg2rr` | 100 GNOT |

100 GNOT each is far more than enough (deploy ≈ 0.005 GNOT gas;
the whole demo flow ≈ 0.01 GNOT gas + 7 GNOT escrow, which mostly
returns to the poster). No real money is involved — testnet only.

Key material: mnemonics + passphrase are stored at
`~/workspace/dorahacks/gnome-tavern-board-keys/` (mode 600, outside
this repo, never committed). The gnokey keybase holds the same keys
(`~/.config/gno`).

### 2.2 After funding — run in this order

```bash
# 0. start the RPC proxy (background)
python3 scripts/gno-rpc-proxy.py

# 1. confirm funding
gnokey query bank/balances/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc -remote 127.0.0.1:26657
gnokey query bank/balances/g1lf8eme0xwh272yyax7kgcf3w43myedy90cg2rr -remote 127.0.0.1:26657

# 2. deploy
./scripts/deploy-onyx.sh

# 3. live demo flow (task 1 DONE + task 2 CANCELLED on-chain)
./scripts/demo-flow.sh

# 4. verify in the browser
#    https://onyx.testnets.gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard
#    and the :stats route (invariant must show PASS)
```

Then fill in §3 below with the deploy transaction hash, the task ids,
and the before/after balances.

## 3. Live testnet evidence (TO FILL after §2)

- [ ] Deploy tx hash: _pending_
- [ ] Realm live URL: https://onyx.testnets.gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard
- [ ] Task #___ DONE (5 GNOT to worker `g1lf8e…`): tx hashes _pending_
- [ ] Task #___ CANCELLED (2 GNOT refunded to poster): tx hash _pending_
- [ ] Worker balance before/after: _pending_
- [ ] Stats route shows invariant PASS: _pending_

## 4. Not yet done (before DoraHacks submit — user reviews first)

- [ ] Live deploy + demo flow (§2.2) and §3 evidence.
- [ ] Demo video (script in `docs/DEMO-SCRIPT.md`) — recorded 12–14 Dec
      per the plan; needs the live realm.
- [ ] GitHub repo `keybot111/tavernboard` — the USER creates it (not done
      by the agent); push this directory's contents there.
- [ ] DoraHacks submission — **NOT submitted**. The user reviews
      everything first, as instructed on 28 Nov 2026.
