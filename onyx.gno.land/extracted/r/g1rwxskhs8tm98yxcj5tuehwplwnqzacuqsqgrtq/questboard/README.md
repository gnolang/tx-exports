# Quest Board

**An escrowed bounty board on Gno.land.** Post a task, lock GNOT as the reward, and pay whoever delivers. The reward sits in the realm's escrow until the poster awards it or it is refunded, and every address builds a public, on-chain record of what it paid out and what it earned.

- **Live on the Gno.land testnet (onyx-1):** _deployment link added after deploy_
- **Realm path:** `gno.land/r/g1rwxskhs8tm98yxcj5tuehwplwnqzacuqsqgrtq/questboard`
- Built by Crypto Bandit for the Gnome Tavern hackathon.

## Why

Most small bounties on any chain are a promise in a chat message. Hunters don't know whether the poster will actually pay, and posters have no neutral way to hold funds. Quest Board fixes the two parts that matter:

1. **The money is locked up front.** A quest only exists if its reward is sitting in the realm's escrow.
2. **Posters have a track record.** Each address's profile shows how many quests it paid out and how much, and also how many times it **cancelled after work was submitted** or **let a quest expire with hunters waiting**. Hunters can check a poster before they start.

It's useful for anyone who wants work done on Gno: core and ecosystem maintainers ("write tests for package X"), DAOs, hackathon organizers, or someone who just wants a README translated.

## How it works

| Step | Who | Function | Notes |
|---|---|---|---|
| Post | anyone | `PostQuest(title, body, days, arbiter)` + `-send` | Reward ≥ 0.1 GNOT, 1–90 days to submit, optional arbiter |
| Fund | anyone | `Fund(id)` + `-send` | Adds to the reward. Funders are refunded if the quest doesn't pay out |
| Submit | anyone but the poster/arbiter | `Submit(id, link, note)` | `http(s)` link to the work (MR, commit, demo). Resubmitting updates your entry |
| Reject | poster or arbiter | `Reject(id, hunter, reason)` | Public reason. The hunter can resubmit before the deadline |
| Award | poster or arbiter | `Award(id, hunter)` | Pays the **whole** escrow to one hunter. Allowed after the deadline too |
| Cancel | poster or arbiter | `Cancel(id)` | Refunds every funder. If work was already submitted, the poster's profile records it |
| Expire | **anyone** | `Expire(id)` | 7 days after the deadline with no award: refunds every funder, and the poster's profile records hunters were left waiting |

Pages served by `Render` (open them in gnoweb):

- `/r/<addr>/questboard`: board totals, open quests, recently closed
- `/r/<addr>/questboard:quest/<id>`: one quest, its submissions, funders, and one-click action links
- `/r/<addr>/questboard:u/<address>`: an address's track record as poster and hunter

Every action emits an event (`QuestPosted`, `QuestFunded`, `QuestSubmitted`, `QuestRejected`, `QuestAwarded`, `QuestCancelled`, `QuestExpired`) so indexers and bots can follow the board. Other realms can read `QuestCount()`, `RewardOf(id)` and `Stats()`.

## Use it

### From the browser (gnoweb + Adena)

Open the realm page, click **+ Post a quest** or a quest's **Submit your work** link. gnoweb's `$help` page pre-fills the call. Sign it with the [Adena](https://adena.app) wallet, or copy the `gnokey` command it prints.

### From the command line (gnokey)

```sh
REMOTE=https://rpc.onyx.testnets.gno.land:443
CHAINID=onyx-1
PKG=gno.land/r/g1rwxskhs8tm98yxcj5tuehwplwnqzacuqsqgrtq/questboard

# Post a quest with a 2 GNOT reward and 7 days to submit (no arbiter)
gnokey maketx call -pkgpath $PKG -func PostQuest \
  -args "Add a Render() test to r/demo/counter" \
  -args "Write a _test.gno covering Render() with 0 and 3 increments. Link the MR." \
  -args 7 -args "" \
  -send 2000000ugnot -gas-fee 1000000ugnot -gas-wanted 20000000 \
  -broadcast -chainid $CHAINID -remote $REMOTE mykey

# Submit work as a hunter
gnokey maketx call -pkgpath $PKG -func Submit \
  -args 1 -args "https://gitlab.com/you/repo/-/merge_requests/1" -args "Covers both cases" \
  -gas-fee 1000000ugnot -gas-wanted 20000000 -broadcast -chainid $CHAINID -remote $REMOTE hunterkey

# Award it (poster)
gnokey maketx call -pkgpath $PKG -func Award -args 1 -args <hunter-address> \
  -gas-fee 1000000ugnot -gas-wanted 20000000 -broadcast -chainid $CHAINID -remote $REMOTE mykey

# Read the board without a key
gnokey query vm/qrender -data "$PKG:" -remote $REMOTE
gnokey query vm/qrender -data "$PKG:quest/1" -remote $REMOTE
```

`scripts/tx.sh` wraps these calls (`REMOTE`, `CHAINID`, `KEYHOME` env vars).

## Trust model and limits

Quest Board is an escrow, not a court. Be clear about what it does and doesn't guarantee:

- **Funds can't vanish.** Coins leave the realm only through `Award` (to a hunter who submitted) or a refund to the exact addresses and amounts that funded the quest.
- **The poster decides.** A poster can still refuse to pay and cancel. What they can't do is hide it: cancelling after work was submitted, or ghosting until `Expire`, is written to their public profile. Name an **arbiter** at creation if you want a neutral third party who can also award or cancel.
- **Only direct user calls can send coins.** `PostQuest` and `Fund` reject calls from other realms and `maketx run` scripts, following the `unsafe.OriginSend` guidance used by the core examples, so a phantom deposit can't drain escrow.
- **Only `ugnot` is accepted.** Any other coin in the transaction makes it fail, so nothing gets stuck.
- **Bounded loops and sizes.** At most 50 submissions and 32 funders per quest; title ≤ 80 bytes, body ≤ 4,000, link ≤ 300, note ≤ 500. The home page lists the newest 30 open quests.
- **User text is sanitized** with `gno.land/p/nt/markdown/sanitize/v0` before rendering, so titles, bodies and notes can't inject headings, tables, raw HTML or `javascript:` links.

## Develop

Requires the Gno toolchain (`gno`, `gnokey`, `gnodev`) from [gnolang/gno](https://github.com/gnolang/gno). It was built and tested against `v1.8.0-rc.1`, the version onyx runs.

```sh
gno test -v .          # unit tests (escrow, refunds, deadlines, permissions, rendering)
gno lint .
gnodev local .         # local node + gnoweb at http://127.0.0.1:8888
```

Tests cover posting, funding, submitting, rejecting and resubmitting, awarding (by poster, arbiter, and after the deadline), cancelling (with and without submissions), expiry timing and grace period, input validation (coin denom, minimums, lengths, URL schemes, self-submission), and that rendered markdown is sanitized.

## Files

- `questboard.gno`: escrow state machine and public functions
- `types.gno`: `Quest`, `Submission`, `Contribution`, `Profile`
- `render.gno`: gnoweb pages
- `questboard_test.gno`: tests
- `scripts/tx.sh`: gnokey helper

## License

MIT. Uses Gno.land standard packages (`avl`, `seqid`, `ufmt`, `txlink`, `markdown/sanitize`) from [gnolang/gno](https://github.com/gnolang/gno).

Quest Board is an independent project and isn't affiliated with or endorsed by Gno.land.
