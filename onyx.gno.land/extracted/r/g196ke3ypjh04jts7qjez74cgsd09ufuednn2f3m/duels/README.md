# Tavern Duel Arena

**Two gnomes walk into a tavern. One leaves with the pot.**

A commit-reveal wagering game on [Gno.land](https://gno.land). Two players stake the
same amount of GNOT on a tavern-brawl match and the winner takes the pot, minus a
small house rake. The rules live in one Gno realm, every byte of state is public,
and the game is fair because **neither player can see the other's move before
committing**.

## How it works

Moves are a classic rock-paper-scissors cycle with tavern flavor:

| Move | Emoji | Beats |
|---|---|---|
| Ale | 🍺 | Broom (spills everywhere) |
| Broom | 🧹 | Dagger (sweeps it away) |
| Dagger | 🗡️ | Ale (stabs the keg) |

Ties refund both stakes in full, with no rake.

### Fair by commitment

1. **Commit.** Each player picks a move and a random salt, computes
   `sha256("<move>:<salt>")` (hex) locally, and keeps both secret.
2. **Open.** The creator calls `CreateDuel(commitment)` sending the stake
   (native `ugnot`, between 0.001 and 1 GNOT).
3. **Join.** The opponent calls `JoinDuel(id, theirCommitment)` with the
   *exact same* stake. Neither side has seen the other's move: the commitment
   hides it until the reveal.
4. **Reveal.** Both call `RevealDuel(id, move, salt)`. The realm checks each
   reveal against the stored commitment. When the second reveal lands, the
   winner is paid `2 × stake − rake` automatically.
5. **Walkouts.** Deadlines protect your stake:
   - nobody joined: `ClaimForfeit` refunds the creator after the join window,
   - joined but silent: the player who revealed on time takes the pot,
   - nobody revealed: both stakes are refunded.

### The realm

| Function | Who | What |
|---|---|---|
| `CreateDuel(commitment)` | anyone | open a duel, sending the stake |
| `JoinDuel(id, commitment)` | anyone but the creator | match the stake with your own commitment |
| `RevealDuel(id, move, salt)` | a player | open your commitment; the second reveal resolves |
| `ClaimForfeit(id)` | anyone | settle a duel whose opponent never showed up |
| `Init()` | deployer, once | record the realm admin |
| `SetWindows(join, reveal)` | admin | tune deadlines (in blocks) |
| `SetRakeBps(bps)` | admin | tune the house rake (≤ 10%) |
| `WithdrawTreasury(to, amount)` | admin | withdraw accumulated rake |
| `Render(path)` | gnoweb | serve the UI (see below) |

Parameters: stake 0.001–1 GNOT per player, rake 2.5% (default), windows 300
blocks by default (Onyx produces a block roughly every 5 s).

## Playing

Everything is on the testnet (`onyx-1`). Read-only views need no wallet:
call `Render` through gnoweb or `gnokey query vm/qeval`.

### 1. Create your key and get test GNOT

```bash
gnokey add mykey                     # store the mnemonic safely
# faucet: https://faucet.gno.land  (paste your g1... address, pick ONYX-1)
```

### 2. Compute a commitment

Any sha256 works; the help page next to the realm does it in the browser:

```bash
printf '0:hunter2' | sha256sum       # 0=🍺 Ale, 1=🧹 Broom, 2=🗡️ Dagger
```

### 3. Create a duel (0.01 GNOT stake)

```bash
gnokey maketx call \
  -pkgpath gno.land/r/<deployer-address>/duels \
  -func CreateDuel \
  -args <your-64-hex-commitment> \
  -send 10000000ugnot \
  -gas-fee 1000000ugnot -gas-wanted 20000000 -broadcast \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 \
  mykey
```

### 4. Join, then reveal

```bash
# opponent: same stake, own commitment
gnokey maketx call -pkgpath gno.land/r/<addr>/duels -func JoinDuel \
  -args <duel-id> -args <your-commitment> -send 10000000ugnot ...
gnokey maketx call -pkgpath gno.land/r/<addr>/duels -func RevealDuel \
  -args <duel-id> -args 0 -args <your-salt> ...
```

After the second reveal the winner is paid already — just read the page.

### 5. Read the game

- Arena: `https://latest.testnets.gno.land/r/<addr>/duels`
- One duel: `.../duels:duel/<id>`
- Player: `.../duels:stats/<address>`
- Leaderboard: `.../duels:leaderboard`

The render pages include working forms for `RevealDuel` and `ClaimForfeit`, so
with a connected wallet you can reveal straight from the browser.

## Repository layout

```
duels.gno        the realm: game rules, payout logic, gnoweb UI
duels_test.gno   12 test cases: full flows, ties, forfeits, rejection paths, admin, render
gnomod.toml      module path and language version
web/index.html   commitment calculator + command builder (no server, open in a browser)
tools/           WSL dev scripts: fmt/lint/test, local chain, end-to-end game
```

## Testing

```bash
bash tools/check.sh     # gno fmt -w, gno lint, gno test
```

The suite covers: creator wins / joiner wins / tie, the unjoined-duel refund,
the silent-revealer forfeit, the nobody-revealed refund, commitment mismatch,
double reveal, non-player calls, wrong stake, out-of-bounds stake, unknown duels,
deadlines, admin-only functions, and the render pages for every route.

## License

MIT