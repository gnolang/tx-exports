# 🍺 Tavern Board — Open Task Board with GNOT Escrow

> **Gnome Tavern Hackathon | Gno.land** — built on the Onyx testnet (`onyx-1`).
> Live realm: https://onyx.testnets.gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard
> Realm path: `gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard`

Post a task, lock its reward in escrow, and let anyone in the tavern claim it.
The worker submits proof, you approve, and the escrow pays out — all on-chain,
no middleman, no frontend server. The board itself is the UI: gnoweb renders
it straight from the realm.

## How it works

1. **Post** a task with GNOT attached (`-send`) — the reward is escrowed in the realm.
2. **Claim** an open task (anyone except the poster).
3. **Submit proof** of the work (text + link).
4. **Approve** — the poster releases the escrow to the worker.
5. If a deadline passes unfinished, **anyone** can release the escrow back to
   the poster (`ReleaseExpired`). Funds can never be locked forever.

Side paths: the poster can `RejectProof` (worker may resubmit), `CancelTask`
an open task (full refund), and the worker can `Unclaim` before submitting
proof. Every ugnot obeys one invariant:

```
locked + paid + refunded == deposited
```

The `/stats` route of the realm checks it live, two independent ways.

## Try it (Onyx testnet)

Get free testnet GNOT at https://faucet.gno.land (paste your `g1...`
address, pick Onyx). 1 GNOT = 1,000,000 ugnot.

```bash
# 1. Post a task with a 5 GNOT escrow (deadline 0 = none)
gnokey maketx call -pkgpath "gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard" \
  -func "PostTask" -args "Write a README for my realm" -args "One page, English, with setup steps" -args "0" \
  -send 5000000ugnot -gas-fee 2000ugnot -gas-wanted 2000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>

# 2. Claim it (another key)
gnokey maketx call -pkgpath "gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard" \
  -func "ClaimTask" -args "1" \
  -gas-fee 2000ugnot -gas-wanted 2000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>

# 3. Submit proof (worker)
gnokey maketx call -pkgpath "gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard" \
  -func "SubmitProof" -args "1" -args "Done: https://github.com/example/repo/pull/7" \
  -gas-fee 2000ugnot -gas-wanted 2000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>

# 4. Approve (poster) — escrow pays the worker
gnokey maketx call -pkgpath "gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard" \
  -func "Approve" -args "1" \
  -gas-fee 2000ugnot -gas-wanted 2000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>
```

Read-only queries (no gas, no key):

```bash
gnokey query vm/qeval -remote https://rpc.onyx.testnets.gno.land:443 \
  -data 'gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard.TaskCount()'
gnokey query vm/qeval -remote https://rpc.onyx.testnets.gno.land:443 \
  -data 'gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard.Stats()'
```

Full command reference: open the realm's **Guide** route in gnoweb
(`.../tavernboard:guide`).

## Files

| File | What it is |
|---|---|
| `gnomod.toml` | Module declaration (`gno.land/r/.../tavernboard`) |
| `tavernboard.gno` | Realm: state machine, 8 crossing + 4 read-only functions, escrow + invariant |
| `render.gno` | `Render()` — gnoweb UI: home, `task/<id>`, `stats`, `guide`; input sanitizing |
| `tavernboard_test.gno` | 10 test suites: happy path, refunds, expiry, role guards, validation, Render, conservation |
| `docs/ARCHITECTURE.md` | State machine, invariant, threat model, security checklist |
| `docs/DEMO-SCRIPT.md` | Shot-by-shot script for the 1–3 min demo video |
| `scripts/deploy-onyx.sh` | Deploy to Onyx + verify it is live |
| `scripts/demo-flow.sh` | End-to-end demo transactions (post → claim → proof → approve + cancel) |
| `VERIFICATION.md` | What was tested, results, and live testnet evidence |

## Develop & test locally

Requires the [Gno toolchain](https://docs.gno.land/builders/install/)
(`gno`, `gnokey`, `gnodev` v1.8.0) and a checkout of `github.com/gnolang/gno`
for the stdlib (`-root-dir`).

```bash
export GNOROOT=$HOME/.gno/src   # path to the gno repo checkout
gno fmt ./...
gno test -v -root-dir $GNOROOT .
gnodev .                          # local devnet + hot reload at http://localhost:8888
```

Test coverage: 10 suites, all passing (`gno test -v .`).
See `VERIFICATION.md` for the full list and the live testnet evidence.

## Security design (summary)

- Caller identity always comes from `cur.Previous().Address()` — never from a parameter.
- `PostTask` (the only payable function) additionally requires a direct user
  call (`IsUserCall()`) and reads the attached amount from
  `unsafe.OriginSend()` — the reward cannot be faked.
- Checks-Effects-Interactions everywhere coins move: state + accounting
  first, `banker.SendCoins` last.
- Getters return value copies, never pointers to mutable state.
- User text is sanitized before it reaches Markdown (`Render`).
- Full checklist + threat model: `docs/ARCHITECTURE.md`.

## Why a task board

Gno.land already has escrow (MilestoneEscrow, bilateral) and forums (Boards,
no money) — but no open marketplace where anyone can post paid micro-work
with escrow. Tavern Board is that missing piece, built the way the ecosystem
itself works: one realm, gnoweb as the frontend, ugnot as the money.
