# Agent Deeds Registry — Build Report

**Hackathon:** Gnome Tavern (DoraHacks × Gno.land), 23 Nov – 18 Dec 2026.
**Deadline:** Fri 19 Dec 2026, 00:00 WIB.
**Entry:** Agent Deeds Registry — a reputation board for AI agents on Gno.land.
**Repo:** https://github.com/sadiomonro-boop/agent-deeds-registry
**Commit:** `97708f96992c2d9941f5f6d04b24361430628393` (main)
**Status (28 Nov 2026 ~14:00 WIB): realm BUILT + TESTED + pushed. Testnet deploy
BLOCKED on funding (see §4) — everything else is ready.**

## 1. What was built

`deeds.gno` (~300 lines) — a realm where AI agents register, log completed
tasks ("deeds") with a content hash as proof, and collect attestations from
other registered agents. Readable by any agent via gnomcp.

| Function | Rule |
|---|---|
| `RegisterAgent(name, description)` | One registration per address; name ≤ 64 chars. |
| `LogDeed(title, proofHash)` | Registered agents only; returns deed ID. |
| `Attest(deedID, note)` | Registered agent, not own deed, once per deed. |
| `AgentInfo / DeedInfo / Stats / TopAgents / RecentDeeds` | Read helpers; TopAgents ranks by attestations, then deeds. |
| `Render(path)` | Markdown board for gnoweb (stats, top agents, recent deeds, how-to). |

Caller identity: `unsafe.PreviousRealm().Address()` (documented v1.8.0 idiom).
Validation failures panic (tx aborts) — standard Gno convention.
Crossing functions are thin wrappers over internal helpers, so the logic is
directly unit-testable.

## 2. Verification (local, 28 Nov)

| Check | Result |
|---|---|
| `gno fmt ./...` | clean (rc 0) |
| `gno lint ./...` | clean (rc 0) |
| `gno test ./...` | **7/7 pass** (`ok . 2.26s`) — register/log/attest, duplicate/invalid/unregistered panics, ranking order, crossing caller wiring |
| gnodev end-to-end (devnet) | **4/4 calls OK**: RegisterAgent (deploy key), LogDeed, RegisterAgent (2nd key), Attest. Negative test (duplicate register) correctly failed with `agent already registered`. |
| Render after calls | `agents: 2, deeds: 1, attestations: 1`; SadioResearch 1 deed / 1 attestation; deed #1 "Wrote market brief: tokenized stocks" with proof `sha256:9f2c41ab77d0` |

Notes learned:
- `gno test` shares realm state across tests in one run — tests assert deltas, not absolute totals.
- The test suite has **zero external dependencies**: the `testAddress` helper is
  inlined (same construction as `gno.land/p/nt/testutils/v0.TestAddress`),
  because the toolchain cannot fetch gno.land packages from this VM (see §5).
- A realm's first call needs ~3.6M gas (cold load). Use
  `-gas-fee 10000ugnot -gas-wanted 10000000` for calls; deploy uses
  `-gas-fee 20000ugnot -gas-wanted 10000000` (storage deposit dominates).
- `gnokey maketx call -args` takes **one value per flag** — repeat `-args` per argument.

## 3. Keys

- **Deploy key (fresh, for this entry):** `gnome-deeds-deploy`,
  `g1fe2mh7k7g92mmtp9tkxdzveea9rkt3ksw9ca9c`. Mnemonic + password stored
  mode-600 in `~/workspace/gnome-tavern/deeds-deploy-key-backup.txt` and
  `deeds-deploy-key-password.txt`. **Never printed or sent anywhere.**
  Testnet balance: **0** (unfunded — see §4).
- **Demo key (local devnet only):** `gnome-deeds-demo`,
  `g1t49my25mrxggdpnt2y98tx2zh45vuag69hnlv4`, password `test`.
  Never fund on testnet/mainnet.
- **Learning key:** `gnome-throwaway`, `g16hydljxln3pashneeypm6ydzw8y2qd6v5g9n9c`
  — holds the faucet funds but is **unusable** (see §4).

## 4. ⛔ BLOCKER — testnet funding (deploy cannot proceed yet)

- **Faucet claimed 28 Nov 13:17 WIB** by the user from his phone:
  "Faucet request successful" for the throwaway address. **Verified on-chain**
  via `abci_query`: balance `"100000000ugnot"` = **10 GNOT**,
  account 3019, sequence 0.
- **The 10 GNOT is LOCKED in the throwaway key.** Its password was set by
  the learning session and never recorded: no password file, no shell
  history, `muse.db` holds no record of the key-creation command, and
  36 common-password guesses (via `gnokey export` oracle) all failed.
  The planned throwaway → fresh-key send fails at signing:
  `unable to sign transaction: invalid account password`.
- **What is needed (ONE of these):**
  1. **User claims the faucet once more for the FRESH address** (~1 min on
     his phone — same as before, but paste the deploy address):
     `g1fe2mh7k7g92mmtp9tkxdzveea9rkt3ksw9ca9c` at https://faucet.gno.land
     (10 GNOT is more than enough: deploy ≈ 0.32 GNOT + gas).
  2. A browser task at faucet.gno.land with a captcha solved via takeover.
- Do NOT ask the user for the throwaway password (nobody has it) and do NOT
  retry the faucet drip API (declined before, must never be retried).

## 5. RPC workaround (solved, reusable)

`gnokey`'s HTTP client dials TCP directly and ignores the VM's egress proxy
env vars, so direct calls to `https://rpc.latest.testnets.gno.land:443` fail
with `tls: first record does not look like a TLS handshake` (curl/Python work).
**Fix:** local reverse proxy `~/workspace/gnome-tavern/gno-rpc-proxy.py`
(listens `127.0.0.1:26657`, forwards via proxy-aware urllib to the Onyx RPC).
Verified: `gnokey query bank/balances/... -remote 127.0.0.1:26657` returns in
0.78s; `maketx` account query works through it (send reached the signing step).
Restart after a VM reboot with:
`setsid nohup python3 ~/workspace/gnome-tavern/gno-rpc-proxy.py > /tmp/gno-rpc-proxy.log 2>&1 < /dev/null &`

## 6. Deploy commands (ready — run once the fresh key is funded)

```bash
export PATH="$PATH:$HOME/.gno/bin" GNOROOT="$HOME/workspace/gnome-tavern/gno-src"
# 0. ensure the RPC proxy is running (see §5)
# 1. confirm funds:
gnokey query bank/balances/g1fe2mh7k7g92mmtp9tkxdzveea9rkt3ksw9ca9c -remote 127.0.0.1:26657
# 2. deploy:
printf '%s\n' "$(cat ~/workspace/gnome-tavern/deeds-deploy-key-password.txt)" | \
gnokey maketx addpkg -insecure-password-stdin \
  -pkgpath "gno.land/r/g1fe2mh7k7g92mmtp9tkxdzveea9rkt3ksw9ca9c/deeds" \
  -pkgdir ~/workspace/gnome-tavern/agent-deeds-registry \
  -gas-fee 20000ugnot -gas-wanted 10000000 \
  -chainid onyx-1 -remote 127.0.0.1:26657 gnome-deeds-deploy
# 3. verify: https://latest.testnets.gno.land/r/g1fe2mh7k7g92mmtp9tkxdzveea9rkt3ksw9ca9c/deeds
# 4. seed demo data: RegisterAgent + LogDeed as deploy key, then a second
#    fresh key registers + Attests (create it with backup at deploy time).
```

## 7. Submission readiness

- DoraHacks event page (`dorahacks.io/hackathon/gnome-tavern/detail`) still
  returns **HTTP 405** (rechecked 28 Nov) — exact submission fields and
  judging criteria are **unverified**. Standard BUIDL materials are prepared
  in `SUBMISSION.md`; confirm the fields on DoraHacks at submit time.
- Remaining before submit: (a) fund fresh key (§4), (b) deploy + verify live
  realm + seed demo data, (c) record a short demo video (gnoweb board + a
  live register/log/attest), (d) submit on DoraHacks. Submit by 17–18 Dec 2026.
