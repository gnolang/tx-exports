# TavernBoard realm

TavernBoard is a community message board realm for Gno.land, built for the
Gnome Tavern Hackathon. Anyone can post a short message on chain, and anyone
can cheer (like) a message once. The board renders as Markdown through
gnoweb, newest first. There is no admin, no delete, and no edit.

- Realm path: `gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard`
- Package name: `tavernboard`
- Network target: Gno.land Onyx testnet, chain ID `onyx-1`
- RPC: `https://rpc.onyx.testnets.gno.land:443` (alias `https://rpc.latest.testnets.gno.land:443`)
- Faucet: `https://faucet.gno.land` (Onyx Faucet, chain `onyx-1`)
- Gnoweb (after deploy): `https://onyx.testnets.gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard`

Status: written, unit tested (6 tests pass), and proven end to end on a
local gnodev chain (3 posts, 1 cheer, renders and queries verified). Testnet
deploy is pending faucet funding: the faucet needs a captcha solved in a
browser. See REALM-RESULT.md for the full record and the exact deploy steps
below.

## API

State-mutating (crossing) functions, called with `gnokey maketx call` or a
wallet such as Adena:

- `PostMessage(text string) int` - posts a message from the caller and
  returns its ID. IDs start at 0 and never change. Panics if the text is
  empty or longer than 280 bytes.
- `LikeMessage(id int) int` - cheers a message. Each address can cheer a
  given message at most once. Returns the new cheer count. Panics on an
  unknown ID or a repeat cheer.

Read-only functions, safe for queries (no transaction, no gas):

- `MessageCount() int` - how many messages have been posted.
- `GetMessage(id int) (author string, text string, height int64, likes int)`
  - one message in full. Panics on an unknown ID.
- `HasLiked(id int, who address) bool` - whether an address cheered a
  message. Panics on an unknown ID.
- `Render(path string) string` - Markdown for gnoweb. Root (`""` or `"/"`)
  lists the newest 50 messages; `"/<id>"` shows one message.

Each message stores: author address, text, block height at posting time,
cheer count, and the set of addresses that cheered it.

Gas note: posting costs more gas as the board grows (about 2.3M gas for the
first post, about 2.9M by the third in local testing). Use
`-gas-wanted 5000000 -gas-fee 5000ugnot` for calls to stay safe.

## Run locally (no testnet needed)

Toolchain used here: `gno`, `gnokey`, `gnodev` v1.8.0 in
`~/workspace/gno-tools/bin`, with `GNOROOT=~/workspace/gno-tools/gno`
(a v1.8.0 checkout of github.com/gnolang/gno; the `gno` CLI needs the
stdlib sources from the repo).

```bash
export PATH="$HOME/workspace/gno-tools/bin:$PATH"
export GNOROOT="$HOME/workspace/gno-tools/gno"
cd ~/workspace/hackathons/gnome-tavern-2026-11-26/realm

gno fmt -w ./...
gno lint ./...
gno test -v ./...          # 6 tests, all pass

# Local chain with hot reload (RPC 127.0.0.1:26657, gnoweb 127.0.0.1:8888).
# Keep logs and scratch files OUT of this directory while gnodev runs:
# its file watcher reloads the chain on any file change in the package dir.
gnodev local -no-watch -home ./.gnokey-home \
  -deploy-key g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl \
  -add-account g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl=100000000000ugnot .

# In another terminal:
gnokey query vm/qrender -data "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard:" -remote http://127.0.0.1:26657
gnokey maketx call -pkgpath "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard" \
  -func PostMessage -args "Hello from the tavern" \
  -gas-fee 4000ugnot -gas-wanted 4000000 -chainid dev -remote http://127.0.0.1:26657 \
  -home ./.gnokey-home tavernboard-dev
# Open http://127.0.0.1:8888/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard
```

The local key `tavernboard-dev` lives in `./.gnokey-home`. Its mnemonic and
password are recorded only in `keyfile-info.txt` (chmod 600) in this
directory. Testnet only: never use this key on mainnet or with real funds.

## Deploy to Onyx testnet

1. Fund the key (browser step, captcha required). Go to
   https://faucet.gno.land, choose the Onyx Faucet (chain `onyx-1`), paste
   `g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl`, solve the captcha, submit.
   100 GNOT is more than enough. Tokens arrive in seconds.

2. Confirm the funds landed:

```bash
gnokey query bank/balances/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl \
  -remote https://rpc.onyx.testnets.gno.land:443
```

3. Deploy the realm (run from this directory; gnokey asks for the key
   password from `keyfile-info.txt`):

```bash
gnokey maketx addpkg \
  -pkgpath "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard" \
  -pkgdir . \
  -gas-fee 5000ugnot -gas-wanted 5000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 \
  -home ./.gnokey-home tavernboard-dev
```

4. Wait a few seconds: the testnet enables a new package shortly after
   `addpkg`. If calls fail with "package not known", wait and retry. If it
   still fails after a minute, look up the exact package path at
   https://gpas.latest.testnets.gno.land for the refusal reason.

5. Post and cheer:

```bash
gnokey maketx call -pkgpath "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard" \
  -func PostMessage -args "Welcome to TavernBoard" \
  -gas-fee 5000ugnot -gas-wanted 5000000 -chainid onyx-1 \
  -remote https://rpc.onyx.testnets.gno.land:443 -home ./.gnokey-home tavernboard-dev

gnokey maketx call -pkgpath "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard" \
  -func LikeMessage -args "0" \
  -gas-fee 5000ugnot -gas-wanted 5000000 -chainid onyx-1 \
  -remote https://rpc.onyx.testnets.gno.land:443 -home ./.gnokey-home tavernboard-dev
```

6. View it: https://onyx.testnets.gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard
   (single message: append `:/0`, `:/1`, and so on).

Note for this VM: `gnokey` cannot reach the testnet RPC from here (the
egress proxy breaks Go TLS; `curl` queries work, `gnokey` broadcasts do
not). Run the deploy commands from a normal machine, or see
REALM-RESULT.md for details.

## Reading state from a front end

- Render (Markdown, best for display): ABCI query path `vm/qrender`, data
  `gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard:` for the
  board, or `.../tavernboard:/<id>` for one message. With gnokey:
  `gnokey query vm/qrender -data "gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard:" -remote https://rpc.onyx.testnets.gno.land:443`
- Eval (typed values, best for app logic): ABCI query path `vm/qeval`, data
  `gno.land/r/g1q5ra3080jnhk8skw664lyz9p97t7reddup89rl/tavernboard.MessageCount()`,
  `.../tavernboard.GetMessage(0)`, `.../tavernboard.HasLiked(0, "g1...")`.
  Loop `GetMessage(i)` for `i` in `0..MessageCount()-1` to rebuild the
  board in the UI.
- Writes: MsgCall to `PostMessage` / `LikeMessage` via Adena wallet or
  gnokey. The gnoweb Actions tab for the realm shows a form per function
  plus the equivalent gnokey command.

## Files

- `tavernboard.gno` - the realm.
- `tavernboard_test.gno` - unit tests (`gno test`).
- `gnomod.toml` - module path and Gno version (0.9).
- `local-proof.log` - full local chain proof (deploy, posts, cheer, renders).
- `REALM-RESULT.md` - research notes, test results, deployment status.
- `keyfile-info.txt` - testnet key record (chmod 600, keep private).
- `.gnokey-home/` - encrypted gnokey keybase for `tavernboard-dev`
  (chmod 700). Recoverable from `keyfile-info.txt` with
  `gnokey add tavernboard-dev --recover -home <dir>` (verified).
- `.gnokey-home-superseded/` - keybase of a superseded first key that was
  never funded or deployed. Safe to delete.
