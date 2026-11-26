# BUILD-NOTES.md — Tavern Board (rewritten 25 Nov 2026, Gno v1.8)

## What was built

On-chain forum/board for Gno.land (Onyx testnet): posts and replies are chain
state, authors earn GNOT tips, front page ranks posts by tips received.

- `realm.gno` — realm implementation on the **Gno v1.8 API** (see "Rewrite" below)
- `realm_test.gno` — 8 unit tests (posts, replies, render, validation)
- `filetests/z_tip_filetest.gno` — filetest (tip flows, leaderboard, refund)
- `gnomod.toml` — module `gno.land/r/tavernboard`
- `../gnowork.toml` — workspace root (lets `gno test` resolve the realm locally)
- `README.md`, `LICENSE` (MIT), this file

## Verified by the coordinator (not taken on trust)

### `gno test` — 9/9 PASS (Gno v1.8.0, 25 Nov ~17:45 WIB)

```
ok . 2.01s
TestCreatePost, TestCreatePostValidation, TestCreateReply,
TestCreateReplyValidation, TestRenderBoard, TestRenderPost,
TestRenderErrors, TestRenderEscapesUserContent — PASS
./z_tip_filetest.gno — PASS (gas 6,279,791)
```

The filetest proves the money movement with distinct author/tipper addresses:
author balance +1000 on a 1000ugnot tip, reply author +500, leaderboard order
500 > 300 > 100, author-tips totals, and a 500ugnot leftover refund
(send 1500, tip 1000).

### gnodev local verification — all live (25 Nov ~18:00 WIB)

gnodev loaded the realm cleanly (no dependency errors), gnoweb on :8888.
Real transactions against the local node (`http://localhost:26657`):

| Call | Height | Tx hash | Gas used |
|---|---|---|---|
| CreatePost "Hello from gnodev" | 3 | `PpbJI8kk/tHbuFZZOoSRFLaIuRMYFiZ1PwYfbmtSkWA=` | 2,970,356 |
| CreateReply (post 1) | 5 | `KOVa+OFLFYaocSTaBjdYXxncdPYWgZIeOOo26NLpYYk=` | 2,900,196 |
| TipPost 1, 1000ugnot (`-send 1000ugnot`) | 7 | `S/iFwaJRrenbPbRsqksa7kiIYMTDfAN3ZzuJ+yxFw6s=` | 3,704,065 |

State verified via `gnokey query vm/qeval`:
`GetPost(1)` → TipTotal **1000**, ReplyCount **1**; `GetAuthorTips` → **1000**;
`GetPosts()` returns the post in the leaderboard.

Render verified via curl:
- `/r/tavernboard` (200) shows "Hello from gnodev", "Tips: 1000 ugnot", "Replies: 1"
- `/r/tavernboard:post/1` (200) shows the post, the reply, "Back to Board"
- `/r/tavernboard:post/abc` renders "Invalid post ID"

Gas note: a call needs `-gas-wanted 5000000` (first attempt at 2000000 failed
"out of gas" in simulation; suggested gas-wanted was 3,118,885).

## The rewrite (why the first version was wrong)

The builder's first version used the old v0.9-era API (`gno.land/p/std`,
`gno.land/r/system/bank`, `std.GetCaller`, `bank.Send`, `Render()` with no
argument). That API does not exist in Gno v1.8: no example in the repo imports
`gno.land/p/std`, and `gno test` could not resolve those packages at all.
The realm was rewritten to the sanctioned v1.8 API, following the official
examples (`examples/gno.land/r/demo/disperse`, `examples/gno.land/r/gnoland/boards2`)
and `~/.gno/src/AGENTS.md`:

- `address` / `realm` are built-in types (no import); caller via
  `cur.Previous().Address()`; `chain` + `chain/banker` for money
  (`banker.GetCoin`, `banker.NewBanker(BankerTypeRealmSend, cur)`,
  `SendCoins`); imports `"strconv"`, `"strings"`, `"errors"`, `"time"`.
- `Render(path string)` — gnoweb requires the path argument (`""` = front
  page, `"post/<id>"` = detail). Links use the colon-args form
  (`/r/tavernboard:post/1`). User content is markdown-escaped.
- Tips follow the **disperse pattern**: a RealmSend banker moves coins out of
  the realm's balance, guarded by `cur.Previous().IsUserCall()` (required
  with `unsafe.OriginSend()` — a non-EOA caller could otherwise spend
  pre-existing realm balance) plus a balance check that the realm actually
  holds the sent coins. An OriginSend banker would be safer by construction
  but cannot be exercised in a filetest (the envelope belongs to the
  filetest package), so RealmSend + guard is the sanctioned, testable shape.

## Test-framework lessons (all learned the hard way, 25 Nov)

- In `_test.gno`, `cross(cur)` always passes the test frame's own realm
  (a code realm, `IsUserCall() == false`); `SetRealm`/`SetOriginCaller`
  do NOT change it. Tip flows therefore live in a **filetest**, not unit tests.
- `cross()` only accepts the frame's current `cur` or a bare realm identifier;
  `cross(expr)` and passing a plain realm value are rejected at preprocess.
- `testing.SetRealm` mutates the **current frame's** captured cur — it must be
  called directly in `main`, not via a helper (a helper's SetRealm dies with
  the helper's frame).
- A filetest that imports its own realm needs a `gnowork.toml` workspace root
  above the package, or the loader tries to download the realm from chain.
- Never call `err.Error()` on a possibly-nil error when building a check
  message — it panics ("method selector on nil interface").

## Environment quirk (sandbox only, not a code issue)

This VM's egress proxy breaks Go tools' direct dials: `gnokey`/`gno` use a
custom dialer that ignores `https_proxy`, so direct RPC calls fail with a TLS
error. A local TLS reverse proxy (`/tmp/gnomitm`, 127.0.0.1:8443 → Onyx RPC,
8444 → mainnet RPC) works around it for `gnokey` queries; `gno test`'s
filetest download path does not use it (hence the `gnowork.toml` fix above).
None of this affects the realm or a normal developer machine.

## Honest gaps — NOT verified yet

- **NOT deployed to Onyx.** The deploy key
  (`g15kxyhlw2zgz2l2sg8526j0nw5j77mkumyuztwj`) holds **0 GNOT**. The Onyx
  faucet (`https://faucet.onyx.testnets.gno.land`) is a JS SPA with Google
  reCAPTCHA + hCaptcha + GitHub OAuth — it needs a **browser task** to claim
  test GNOT. No deployment, no Onyx tip tx, no explorer link until then.
- **README's deploy `-gas-wanted 10000000` is an estimate**, not measured:
  the addpkg gas will only be known from the deployment simulation.
- The gnodev tip above was self-directed (one funded account was both author
  and tipper). Cross-address transfer is proven by the filetest; a
  cross-address tip on Onyx is still to be done after deployment (fund a
  second key from the deploy key, have it author a post, tip it from the
  deploy key).

## Keys (test-only, never in the repo)

- Deploy key `tavern-board-testnet` → `g15kxyhlw2zgz2l2sg8526j0nw5j77mkumyuztwj`
  in the gnokey keybase (`~/.config/gno`, passphrase-encrypted). The brief
  asked for `~/workspace/gnome-tavern/keys/tavern-board.key`; the builder put
  it in the keybase instead. Key material was never printed or stored in the repo.
- Throwaway local test keys (unfunded, test-only): `tb_author1..5`, `tb_tipper1`,
  `gnodev-default` (gnodev's deterministic test account, recovered from the
  mnemonic gnodev prints). All passphrase-protected with a throwaway password.

## Time spent (coordinator rewrite + verification, 25 Nov)

- Root-cause + v1.8 API study: ~40 min
- Realm + test rewrite, filetest, workspace fix: ~60 min
- `gno test` 9/9 + gnodev live verification (3 txs, qeval, render): ~30 min
- Docs (README + this file): ~15 min
