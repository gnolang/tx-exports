# 🍺 Tavern Wagers

**Bet on anything with your friends. The money's locked upfront, neutral judges call it, and the winner gets paid automatically. No more "I'll pay you later."**

Built on [Gno.land](https://gno.land) for the Gnome Tavern hackathon.

## The problem

Friendly bets ("I'll beat you at chess", "Arsenal wins Saturday") break down in three ways:

1. **The loser doesn't pay.** "I'll pay you later" turns into never.
2. **Someone has to hold the pot**, and everyone has to trust them.
3. **Arguments about who won.** Two people, two different stories.

## How Tavern Wagers fixes it

| Problem | Fix |
|---|---|
| Loser doesn't pay | Both players lock their stake in the realm **before** the game. Payout is automatic. |
| Someone holds the pot | Nobody does. The realm holds it, and its code is public. |
| Arguments about who won | Everyone else at the table becomes a **judge**. Judges have no money in the bet, so they have no reason to lie. |
| People lie anyway | Each player also locks a **10% honesty bond**. Lose the judges' vote and you lose your bond, plus a permanent 🚩 on the leaderboard. |

The realm takes **no cut**. Every coin that goes in comes back out to players and judges.

## How it works

1. **Open a table** and add your friends with nicknames.
2. **Make a bet** against a friend at the table. You lock `stake + 10% bond`.
3. Your friend **accepts** by locking the same amount.
4. After the game, **both players report** `a`, `b` or `draw`.
   - **Same report:** paid instantly, both bonds back, no fees.
   - **Different reports:** the bet goes to the judges.
5. **Judges vote.** The moment one result has a strict majority, the bet settles:
   - The pot goes to the winner (or back to both players on a draw), minus a **1% judge fee**.
   - A player whose report lost the vote **forfeits their bond**: half to the honest player, half to the judges.
   - Judges who voted with the majority split the fee and their half of the bond.
6. **No majority within 48 hours?** Anyone can trigger a full refund, bonds included.
7. **No-shows:** if one player reports and the other goes quiet for 24 hours, either player can escalate to the judges.

### Example

Alice and Bob each lock 5 GNOT + 0.5 GNOT bond. Alice won, but Bob claims he did. Two of three judges vote "Alice won".

| Who | Gets | Why |
|---|---|---|
| Alice | 9.9 GNOT | the pot minus the 1% judge fee |
| Alice | 0.5 GNOT | her bond back |
| Alice | 0.25 GNOT | half of Bob's forfeited bond |
| Judge 1 | 0.175 GNOT | half of (fee + other half of Bob's bond) |
| Judge 2 | 0.175 GNOT | same |
| Bob | 0 | lost the bet and the bond, 🚩 on the leaderboard |

Total paid out: 11 GNOT = exactly what went in.

## Why Gno.land

- **The rules are the code.** Anyone can read the realm's source on-chain before putting money in.
- **The pot is held by the realm**, not a person or a company.
- **Every table renders itself** on gnoweb (leaderboards, bets, votes and payouts) with action links for every step. No separate backend.

## Realm API

| Function | Who | What |
|---|---|---|
| `CreateTable(name, nickname)` | anyone | opens a table, you're the owner |
| `AddMember(tableID, address, nickname)` | table owner | adds a friend |
| `SetNickname(tableID, nickname)` | member | changes your nickname |
| `CreateBet(tableID, title, opponent, stake)` + send `stake*1.1` ugnot | member | challenges another member |
| `AcceptBet(betID)` + send `stake*1.1` ugnot | player B | accepts the challenge |
| `CancelBet(betID)` | player A | takes back an unaccepted bet |
| `Report(betID, "a"/"b"/"draw")` | players | reports the result |
| `Escalate(betID)` | players | sends a no-show to the judges after 24h |
| `Vote(betID, "a"/"b"/"draw")` | judges | votes on a disputed bet |
| `ExpireDispute(betID)` | anyone | refunds everyone if judges miss the 48h deadline |

Pages: `:` (home), `:table/<id>`, `:bet/<id>`.

## Deployment

- Testnet (onyx-1): `gno.land/r/g1sgp0eyezdescdtzd32n2vdktazva4nyt9ppmcx/tavernwagers`
- Page: https://onyx.testnets.gno.land/r/g1sgp0eyezdescdtzd32n2vdktazva4nyt9ppmcx/tavernwagers

## Run it locally

Requires the Gno toolchain v1.8.0 (`gno`, `gnokey`, `gnodev`).

```sh
gno test -v .                      # unit tests
bash scripts/demo-keys.sh          # creates 5 demo accounts, prints a gnodev command
# run the printed gnodev command, then in another terminal:
bash scripts/demo-scenario.sh      # plays a full story: honest bet, a lie caught by judges, an open challenge
# open http://localhost:8888/r/g1sgp0eyezdescdtzd32n2vdktazva4nyt9ppmcx/tavernwagers
```

## Tests

`wagers_test.gno` covers an agreed result, a liar losing their bond, a draw where both players lied, an expired vote, a no-show escalation, cancellation and input validation, a table with no possible judges, nicknames and page rendering. Every settlement test checks that the coins paid out equal the coins paid in.

## Limits (honest ones)

- Judges can collude. The bond makes lying expensive, but a table full of bad friends can still out-vote you. Tavern Wagers makes trust between friends fair and permanent; it doesn't replace it.
- The realm can't see the real world. Results come from players and judges, never from an outside data feed.
