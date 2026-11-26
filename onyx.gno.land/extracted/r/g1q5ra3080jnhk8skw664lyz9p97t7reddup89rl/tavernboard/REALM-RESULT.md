# TavernBoard realm: result record

Date: 2026-11-26. Project: TavernBoard, a community message board realm on
Gno.land for the Gnome Tavern Hackathon. Work directory:
`~/workspace/hackathons/gnome-tavern-2026-11-26/realm/`.

## Bottom line

- Realm written, formatted, linted, and unit tested: 6 of 6 tests pass.
- Proven end to end on a local gnodev chain: deployed at its real path,
  3 messages posted, 1 cheer recorded, renders and typed queries verified
  (tx hashes below).
- NOT deployed to testnet yet. Two blockers, both outside the code:
  1. Funding: the Onyx faucet requires solving an hCaptcha in a browser.
     A direct API POST without a captcha token produced no funds (request
     timed out, balance still empty). This subagent has no live browser.
  2. Networking: `gnokey` cannot reach the testnet RPC from this VM. Its
     Go TLS handshake fails through the VM egress proxy
     ("tls: first record does not look like a TLS handshake"), while
     `curl` queries through the same proxy work. So even a funded key
     could not broadcast with gnokey from here without extra plumbing.
- One browser faucet visit by Ibrahim plus the deploy commands in
  README.md (run from any normal machine) finishes the testnet launch.
  Nothing else is missing: key, code, tests, and commands are ready.

## Research summary

Sources: docs.gno.land Getting started, Quick Start, Gno networks, and
Interact with gnokey pages (fetched 2026-11-26), plus live RPC checks.

Networks:

| Network | Chain ID | RPC | Notes |
| --- | --- | --- | --- |
| Local (gnodev) | `dev` | `http://localhost:26657` | gnoweb at `http://localhost:8888`, keys auto-funded |
| Onyx testnet (current) | `onyx-1` | `https://rpc.onyx.testnets.gno.land:443` | alias `https://rpc.latest.testnets.gno.land:443` always points at the current testnet |
| Mainnet | `gnoland-1` | `https://rpc.gno.land:443` | no faucet, real GNOT. Not used here. |

Live check on 2026-11-26 about 12:49 UTC: Onyx RPC `/status` reported
network `onyx-1`, height 1426694, not catching up. Onyx launched
2026-09-28, runs mainnet code as release candidates, state persists across
upgrades. Staging is down since 2026-07-10; Pearl and older testnets are
retired.

Faucet: https://faucet.gno.land (Onyx Faucet, chain `onyx-1`, amounts
100/200/300 GNOT, hCaptcha protected). API base
`https://faucet.onyx.testnets.gno.land` accepts POSTs from the web UI with
a captcha token. `https://onyx.testnets.gno.land/faucet` redirects to the
same hub.

Gnoweb URL format: `https://<host>/r/<namespace>/<name>` for the realm
page, with `:/<path>` appended for Render subpaths (for example
`.../tavernboard:/0`). Testnet hosts: `onyx.testnets.gno.land` and
`latest.testnets.gno.land`. Every realm page has Content (Render output),
Source, and Actions tabs. Actions shows a wallet form and the equivalent
gnokey command per exported crossing function.

Realm path format: `gno.land/r/<namespace>/<name>` for realms (stateful),
`gno.land/p/...` for pure packages. The simplest namespace is the
deployer's own address, `gno.land/r/<g1-address>/...`, which needs no
registration. Named namespaces need on-chain registration first. The
`gnomod.toml` module field must match the `-pkgpath` used at deploy.

gnokey essentials:

- `gnokey add <name>` creates a key (prompts for password, prints a
  24-word mnemonic). `-home` selects the keybase directory,
  `-insecure-password-stdin` reads the password from stdin (used here for
  scripted setup; the password itself is only in `keyfile-info.txt`).
- Deploy: `gnokey maketx addpkg -pkgpath <path> -pkgdir . -gas-fee
  5000ugnot -gas-wanted 5000000 -chainid <id> -remote <rpc> <key>`.
  Deploys also lock a storage deposit of 100ugnot per byte of code and
  state, charged on top of the gas fee.
- Call: `gnokey maketx call -pkgpath <path> -func <Fn> -args <arg> ...
  -gas-fee <fee> -gas-wanted <gas> -chainid <id> -remote <rpc> <key>`.
  Gas price floor is 1ugnot per 1000 gas, so fee must be at least
  gas-wanted/1000 ugnot.
- Queries need no key: `gnokey query bank/balances/<addr> -remote <rpc>`,
  `gnokey query vm/qrender -data "<pkgpath>:" -remote <rpc>`,
  `gnokey query vm/qeval -data "<pkgpath>.<Expr>" -remote <rpc>`.
- After `addpkg`, the testnet enables the package a few seconds later.
  Refusal reasons are listed by exact package path at
  https://gpas.latest.testnets.gno.land.

Gno language notes (0.9, toolchain v1.8.0):

- State-mutating exported functions are "crossing functions": first
  parameter `cur realm`, called as `Fn(cross(cur), ...)` from Gno code or
  automatically by gnokey MsgCall. Author identity:
  `cur.Previous().Address()` after checking `cur.IsCurrent()`.
- Block height: `chain/runtime.ChainHeight()` (int64). There is no block
  time helper in `chain/runtime`; height is the deterministic stamp.
- Top-level vars persist to chain state after each transaction.
- `Render(path string) string` returns Markdown for gnoweb.
- Tests: `func TestX(cur realm, t *testing.T)`. Panics raised inside a
  crossing call abort the test run and cannot be recovered; panics in
  plain (non-crossing) functions can. The realm therefore keeps its
  validation in small non-crossing helpers (`cleanText`, `checkID`,
  `checkCanLike`) that the crossing functions call, so the rules are
  unit testable. This matches the pattern in the upstream coins realm
  tests, which only recover panics from `Render`.

Toolchain on this VM:

- `go version`: Go is NOT installed on this VM.
- Installed the official prebuilt toolchain v1.8.0 with
  `misc/install.sh --dir ~/workspace/gno-tools/bin` (sha256 verified by
  the installer): `gno`, `gnokey`, `gnodev`, `gnoweb`. Building from
  source was not attempted: no Go toolchain, and the prebuilt installer
  is the documented path. No execution-risk block was hit.
- Gotcha: the prebuilt `gno` binary looks for stdlib sources at its CI
  build path. Fixed by cloning the repo (tag v1.8.0, shallow, 196 MB) to
  `~/workspace/gno-tools/gno` and setting `GNOROOT` to it. With that,
  `gno fmt/lint/test` and `gnodev` all work.
- Everything lives under `~/workspace/gno-tools/`; no system paths were
  modified.

## Realm design

File `tavernboard.gno`, package `tavernboard`, module
`gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard`.

- `type Message struct { Author address; Text string; Height int64;
  Likes int; LikedBy map[address]bool }`, stored in `var messages
  []Message`. Message ID = slice index (0-based, stable forever).
- `PostMessage(cur realm, text string) int`: crossing. Trims text,
  panics on empty or over 280 bytes (`MaxMessageLen`), stamps author
  from `cur.Previous().Address()` and height from
  `runtime.ChainHeight()`, appends, returns the new ID.
- `LikeMessage(cur realm, id int) int`: crossing. Panics on unknown ID
  or if the caller already cheered; otherwise records the cheer and
  returns the new count. One cheer per address per message.
- `MessageCount() int`, `GetMessage(id) (string, string, int64, int)`,
  `HasLiked(id, who) bool`: read-only helpers for queries and front ends.
- `Render(path)`: root lists the newest 50 messages (`MaxMessagesShown`)
  with author (shortened), block height, cheer count, and text with
  newlines folded so posts cannot break the layout. `"/<id>"` shows one
  message; unknown paths render a friendly not-found page instead of
  panicking.
- No admin, no delete, no edit, no fees, no external calls. Imports only
  `chain/runtime`, `strconv`, `strings`.

## Test results

`gno fmt -w ./...` applied, `gno lint ./...` clean, `gno test -v ./...`:

- TestPostMessage: PASS (IDs, trimming, author, height, counts)
- TestPostMessageRejectsBadText: PASS (empty, blank, 281 bytes rejected;
  exactly 280 bytes accepted)
- TestLikeMessage: PASS (cheer once, HasLiked, repeat rejected)
- TestLikeMessageOtherAuthor: PASS (cheering another author's post)
- TestBadIDs: PASS (unknown and negative IDs rejected everywhere)
- TestRender: PASS (empty board, newest-first order, cheer counts,
  single-message view, not-found pages)

6 passed, 0 failed.

## Local deployment proof (gnodev dev chain)

Started `gnodev local -no-watch` with the realm directory as workspace,
deploy key and premine set to the tavernboard-dev address (100 GNOT
premine = 100000000000ugnot). Chain ID `dev`, RPC `http://127.0.0.1:26657`,
gnoweb `http://127.0.0.1:8888`. Full output in `local-proof.log`.

| Action | Result | Height | Gas used | Total cost | Tx hash |
| --- | --- | --- | --- | --- | --- |
| PostMessage "Welcome to TavernBoard, our community board for the Gnome Tavern Hackathon" | id 0 | 3 | 2245970 | 144700ugnot | `T3B1UgP0Qv23QqvH8qjHP0L4F6/YB7ZRW3QxBt/UhMo=` |
| PostMessage "Built with Gno realms: post a message, cheer the ones you like" | id 1 | 5 | 2566813 | 112000ugnot | `gavk9w2xiOLKZqcAOuruWFzlvXmuxwnYs/hYM/S/ddM=` |
| PostMessage "Third round is on the board. Pull up a stool and say hello" | id 2 | 7 | 2856077 | 111600ugnot | `pBQJP+ALqh16uzThN33Hf+iExHRtvf70MEZK7mY4/O8=` |
| LikeMessage(0) | 1 cheer | 9 | 2406415 | 20300ugnot | `rGG+LPp09PESFvtycarT2XN50Bkh3N4owK9mY0Qlo/s=` |

Queries verified on the same chain: `MessageCount()` = 3;
`GetMessage(0)` = (g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl, welcome text,
height 3, likes 1); `HasLiked(0, author)` = true. `Render` lists message
2, 1, 0 in that order with cheer counts 0, 0, 1; `Render("/0")` shows
only message 0. Gnoweb served the same content at
`http://127.0.0.1:8888/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard`
(HTTP 200, "Total messages: 3"). Balance went from 99997713700ugnot to
99997325100ugnot, a spend of exactly 388600ugnot, matching the four tx
costs above.

Two local lessons, now handled: (1) PostMessage needs more than 2M gas;
2M gas-wanted failed in simulation, 4M succeeded. Use 5M on testnet.
(2) gnodev watches the package directory and reloads on any file change,
including log files written there; during reloads RPC returns 502. Run
gnodev with `-no-watch` and keep scratch files out of the realm dir.

## Testnet deployment status: not deployed (honest fallback)

Key created (testnet only): name `tavernboard-dev`, address
`g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl`. Mnemonic and password are
recorded only in `keyfile-info.txt` (chmod 600) in the realm directory;
they are not in this report. The encrypted keybase is at
`realm/.gnokey-home` (chmod 700) and can be recreated from
`keyfile-info.txt` with `gnokey add tavernboard-dev --recover`.
Recovery was verified at creation: recovering from the recorded mnemonic
reproduces the same address.

Superseded first key: an earlier key (`g1v397843gg6lszdvtfz6ts6ef6tmvq8g6q7slym`)
was created first, but its mnemonic was captured incorrectly (the warning
sentence was recorded instead of the 24-word phrase). A recovery test
caught this before anything depended on it. That key was never funded and
never deployed; the realm path, local proof, and all commands were redone
with the current key above. The old encrypted keybase is preserved at
`realm/.gnokey-home-superseded` (chmod 700) and can be deleted.

Funding attempts and evidence:

- Balance checks via curl ABCI query on
  `https://rpc.onyx.testnets.gno.land`: the superseded address showed
  balance data `""` (zero) and account `null` (does not exist yet); the
  current address `g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl` likewise
  shows balance data `""`. Expected for fresh, unfunded keys.
- Faucet API attempt (for the superseded address, before recreation):
  POST `https://faucet.onyx.testnets.gno.land` with
  `{"address":"g1v397843gg6lszdvtfz6ts6ef6tmvq8g6q7slym","amount":100}`
  and no captcha token: request timed out (HTTP 000 after 30s), balance
  unchanged. The web UI requires an hCaptcha token, which needs a human
  in a browser. No funds were obtained and none were faked.
- gnokey to testnet RPC from this VM:
  `gnokey query bank/balances/... -remote https://rpc.latest.testnets.gno.land`
  fails with "tls: first record does not look like a TLS handshake"
  (VM egress proxy intercepts direct TLS; curl works because it uses the
  proxy properly). So `addpkg` broadcasts cannot run from this VM with
  gnokey as-is.

What Ibrahim needs to do (about 2 minutes):

1. Open https://faucet.gno.land, pick Onyx Faucet (onyx-1), paste
   `g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl`, solve captcha, submit
   (100 GNOT is plenty: deploy deposit is roughly 0.7 GNOT at
   100ugnot/byte for about 7 KB of code and state, plus small gas fees).
2. From any machine with the toolchain (or this VM once gnokey networking
   is sorted), run the deploy, post, and like commands in README.md
   section "Deploy to Onyx testnet". The key password is in
   `keyfile-info.txt`.
3. Confirm at https://onyx.testnets.gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard

Testnet only throughout. No mainnet interaction, no real funds, no keys
requested from anyone.

## Endpoints for the front end

- Chain: Onyx testnet, chain ID `onyx-1`.
- RPC: `https://rpc.onyx.testnets.gno.land:443` (alias
  `https://rpc.latest.testnets.gno.land:443`). WebSocket:
  `wss://rpc.onyx.testnets.gno.land/websocket` (request-response only, no
  subscriptions).
- Realm path: `gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard`
- Read render: ABCI query path `vm/qrender`, data
  `gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard:` (board)
  or `.../tavernboard:/<id>` (one message). Returns Markdown.
- Read values: ABCI query path `vm/qeval`, data
  `gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard.MessageCount()`,
  `.../tavernboard.GetMessage(<id>)`,
  `.../tavernboard.HasLiked(<id>, "<g1-address>")`. Rebuild the board by
  looping GetMessage over 0..count-1.
- Gnoweb page (after deploy):
  `https://onyx.testnets.gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard`
  and `https://latest.testnets.gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard`.
- Writes: MsgCall `PostMessage(text)` / `LikeMessage(id)` via Adena or
  gnokey; gas-wanted 5000000, gas-fee 5000ugnot recommended.
- Until testnet deploy lands, the same reads work against a local
  gnodev chain at `http://127.0.0.1:26657` (chain ID `dev`) with the
  realm loaded from this directory; see README.md "Run locally".

## Exact commands used (key steps)

```bash
# Toolchain (prebuilt v1.8.0 into workspace) + repo clone for stdlib
curl -fsSL https://raw.githubusercontent.com/gnolang/gno/master/misc/install.sh -o /tmp/gno-install.sh
sh /tmp/gno-install.sh --dir ~/workspace/gno-tools/bin
git clone --depth 1 --branch v1.8.0 https://github.com/gnolang/gno.git ~/workspace/gno-tools/gno
export PATH="$HOME/workspace/gno-tools/bin:$PATH" GNOROOT="$HOME/workspace/gno-tools/gno"

# Key (password via stdin, output captured to keyfile-info.txt, chmod 600)
gnokey add tavernboard-dev -home ~/workspace/hackathons/gnome-tavern-2026-11-26/realm/.gnokey-home -insecure-password-stdin

# Verify realm
cd ~/workspace/hackathons/gnome-tavern-2026-11-26/realm
gno fmt -w ./... && gno lint ./... && gno test -v ./...

# Local chain + calls (see local-proof.log for full output)
gnodev local -no-watch -home ./.gnokey-home -deploy-key g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl -add-account g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl=100000000000ugnot .
gnokey maketx call -pkgpath "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard" -func PostMessage -args "..." -gas-fee 4000ugnot -gas-wanted 4000000 -chainid dev -remote http://127.0.0.1:26657 -home ./.gnokey-home -insecure-password-stdin tavernboard-dev
gnokey maketx call -pkgpath "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard" -func LikeMessage -args "0" -gas-fee 4000ugnot -gas-wanted 4000000 -chainid dev -remote http://127.0.0.1:26657 -home ./.gnokey-home -insecure-password-stdin tavernboard-dev
gnokey query vm/qrender -data "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard:" -remote http://127.0.0.1:26657
gnokey query vm/qeval -data "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard.MessageCount()" -remote http://127.0.0.1:26657

# Testnet checks (curl, since gnokey TLS fails from this VM)
curl -s "https://rpc.onyx.testnets.gno.land/status"
curl -s "https://rpc.onyx.testnets.gno.land/abci_query?path=%22bank/balances/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl%22&data=0x"
curl -s -X POST "https://faucet.onyx.testnets.gno.land" -H "Content-Type: application/json" -d '{"address":"g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl","amount":100}'   # no captcha token: timed out, no funds
```

## Files produced

- `realm/tavernboard.gno` - realm source.
- `realm/tavernboard_test.gno` - unit tests.
- `realm/gnomod.toml` - module `gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard`, gno 0.9.
- `realm/README.md` - realm guide with local run and testnet deploy steps.
- `realm/REALM-RESULT.md` - this record.
- `realm/local-proof.log` - full local chain proof output.
- `realm/keyfile-info.txt` - testnet key record, chmod 600 (private).
- `realm/.gnokey-home/` - encrypted keybase for the current key, chmod 700.
- `realm/.gnokey-home-superseded/` - encrypted keybase of the superseded
  first key (never funded or deployed), chmod 700. Safe to delete.
- `~/workspace/gno-tools/bin/` - gno, gnokey, gnodev, gnoweb v1.8.0.
- `~/workspace/gno-tools/gno/` - gnolang/gno checkout at v1.8.0 (GNOROOT).
