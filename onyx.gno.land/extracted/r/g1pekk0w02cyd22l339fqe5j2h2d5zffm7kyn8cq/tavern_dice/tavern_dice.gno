// Package tavern-dice implements Tavern Dice, a small on-chain dice game
// on Gno.land.
//
// How it works:
//   - Anyone funds the bankroll with Fund() (native ugnot, testnet only).
//   - Players bet with BetNumber() (pick 1-6, win pays 5x) or BetParity()
//     (pick odd/even, win pays 1.9x). The bet is sent with the transaction
//     (-send <amount>ugnot); winnings are paid out in the same transaction.
//   - The roll is derived from public chain data (block height, block time,
//     roll sequence, caller address, previous roll hash) hashed with SHA-256.
//     It is unpredictable to a player before their transaction lands, but a
//     block proposer could theoretically influence it. This is demo-grade
//     randomness for testnet play money, not for real stakes.
//   - The worst-case payout of any single bet is capped at a quarter of the
//     bankroll, so the house can always pay.
//
// Security notes (see docs/resources/gno-security-guide.md):
//   - Every function that takes payment guards with cur.Previous().IsUserCall()
//     AND checks unsafe.OriginSend() — the pair, never one alone. IsUser()
//     would also accept user-run ephemeral realms (maketx run), which can
//     consume the origin-send envelope before calling us.
//   - Balances are read with banker.GetCoin (single denom), never
//     GetCoins().AmountOf on a caller-supplied address.
//   - No user-supplied free text is ever rendered; only bech32 addresses
//     and numbers appear in Render output.
package tavern_dice

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/binary"
	"strconv"
	"time"

	"gno.land/p/g1pekk0w02cyd22l339fqe5j2h2d5zffm7kyn8cq/dice/v0"
)

// On-chain path of this realm. Used by the read-only view functions to
// resolve the realm's own address.
const pkgPath = "gno.land/r/g1pekk0w02cyd22l339fqe5j2h2d5zffm7kyn8cq/tavern_dice"

const (
	// minBet is the smallest accepted bet, in ugnot (0.001 GNOT).
	minBet int64 = 1000
	// maxHistory is how many recent rolls are kept on chain.
	maxHistory = 20
	// denom is the only accepted coin.
	denom = "ugnot"
)

var (
	// owner is the deployer. Set in init; only the owner can Withdraw.
	owner address
	// rollSeq counts every settled bet; it feeds the roll derivation.
	rollSeq int64
	// prevRollHash chains rolls together so no two rolls share a seed.
	prevRollHash [32]byte

	totalBets    int64
	totalWagered int64
	totalPaidOut int64
	totalWins    int64

	rolls   []rollRecord
	players map[address]*playerStats
	funders map[address]int64
)

// rollRecord is one settled bet, kept for the recent-rolls table.
type rollRecord struct {
	seq    int64
	player address
	kind   string // "number" or "parity"
	choice string // e.g. "4", "odd", "even"
	roll   int
	bet    int64
	payout int64
}

// playerStats aggregates one address's play.
type playerStats struct {
	bets       int64
	wins       int64
	wagered    int64
	biggestWin int64
}

func init(cur realm) {
	// The deployer is the owner. In unit tests init runs under a test
	// realm, so only claim ownership for a direct user call.
	if cur.Previous().IsUserCall() {
		owner = cur.Previous().Address()
	}
	if players == nil {
		players = map[address]*playerStats{}
	}
	if funders == nil {
		funders = map[address]int64{}
	}
}

// Fund adds native ugnot to the bankroll. Anyone can fund; funders are
// recorded for transparency.
func Fund(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("funding must come directly from a user account")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom {
		panic("fund with ugnot only")
	}
	amount := sent[0].Amount
	if amount <= 0 {
		panic("fund amount must be positive")
	}
	caller := cur.Previous().Address()
	funders[caller] += amount
	chain.Emit("BankrollFunded", "funder", caller.String(), "amount", strconv.FormatInt(amount, 10))
}

// BetNumber bets on a single number (1-6). Win pays 5x the stake.
// The bet is the ugnot sent with the transaction (-send <amount>ugnot).
// Returns the roll.
func BetNumber(cur realm, number int) int {
	if number < 1 || number > 6 {
		panic("number must be between 1 and 6")
	}
	bet := betAmount(cur)
	roll, _ := placeBet(cur, "number", strconv.Itoa(number), bet, dice.NumberPayout(bet), func(roll int) bool {
		return roll == number
	})
	return roll
}

// BetParity bets on odd/even. Win pays 1.9x the stake.
// The bet is the ugnot sent with the transaction (-send <amount>ugnot).
// Returns the roll.
func BetParity(cur realm, even bool) int {
	choice := "odd"
	if even {
		choice = "even"
	}
	bet := betAmount(cur)
	roll, _ := placeBet(cur, "parity", choice, bet, dice.ParityPayout(bet), func(roll int) bool {
		return (roll%2 == 0) == even
	})
	return roll
}

// Withdraw moves bankroll funds to the owner (deployer). The owner can
// withdraw any amount up to the current bankroll.
func Withdraw(cur realm, amount int64) {
	caller := cur.Previous().Address()
	if caller != owner {
		panic("only the owner can withdraw")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	bankroll := realmBankroll()
	if amount > bankroll {
		panic("amount exceeds bankroll")
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
		cur.Address(), owner, chain.Coins{{Denom: denom, Amount: amount}},
	)
	chain.Emit("BankrollWithdrawn", "owner", owner.String(), "amount", strconv.FormatInt(amount, 10))
}

// Owner returns the deployer address.
func Owner() address {
	return owner
}

// MinBet returns the smallest accepted bet in ugnot.
func MinBet() int64 {
	return minBet
}

// Bankroll returns the realm's current ugnot balance.
func Bankroll() int64 {
	return banker.NewReadonlyBanker().GetCoin(chain.PackageAddress(pkgPath), denom)
}

// Stats returns total bets, total wagered, total paid out, total wins.
func Stats() (bets, wagered, paidOut, wins int64) {
	return totalBets, totalWagered, totalPaidOut, totalWins
}

// betAmount reads the bet from the origin-send envelope. It does NOT
// trust any function argument for the amount: the coins actually sent
// are the bet. The IsUserCall guard and the OriginSend check belong
// together: without the guard, an intermediate realm could fake the
// envelope; without the amount check, a user could bet nothing.
func betAmount(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("bets must be placed directly by a user account")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom {
		panic("bet must be sent in ugnot only")
	}
	bet := sent[0].Amount
	if bet < minBet {
		panic("bet below minimum")
	}
	return bet
}

// placeBet settles one bet: derives the roll, pays out on a win, and
// records the result. bet is the amount actually sent (validated by the
// caller via betAmount); payoutIfWin is the total payout (stake included)
// the player receives on a win. The solvency check caps the worst-case
// payout at a quarter of the bankroll (which already includes this bet,
// since the sent coins landed before the function ran).
func placeBet(cur realm, kind, choice string, bet, payoutIfWin int64, won func(int) bool) (int, int64) {
	bankroll := realmBankroll()
	if payoutIfWin > bankroll/4 {
		panic("bet too large for the bankroll")
	}
	caller := cur.Previous().Address()
	roll, seedHash := deriveRoll(caller)
	payout := int64(0)
	if won(roll) {
		payout = payoutIfWin
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
			cur.Address(), caller, chain.Coins{{Denom: denom, Amount: payout}},
		)
	}
	recordRoll(caller, kind, choice, roll, bet, payout, seedHash)
	chain.Emit("BetSettled",
		"player", caller.String(),
		"kind", kind,
		"choice", choice,
		"roll", strconv.Itoa(roll),
		"bet", strconv.FormatInt(bet, 10),
		"payout", strconv.FormatInt(payout, 10),
	)
	return roll, payout
}

// deriveRoll derives the next roll from public chain data. It returns the
// roll (1-6) and the seed hash, which chains into the next roll.
func deriveRoll(caller address) (int, [32]byte) {
	var material []byte
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(runtime.ChainHeight()))
	material = append(material, b[:]...)
	binary.BigEndian.PutUint64(b[:], uint64(time.Now().UnixNano()))
	material = append(material, b[:]...)
	binary.BigEndian.PutUint64(b[:], uint64(rollSeq))
	material = append(material, b[:]...)
	material = append(material, []byte(caller.String())...)
	material = append(material, prevRollHash[:]...)
	seed := sha256.Sum256(material)
	return dice.RollFromSeed(seed[:]), sha256.Sum256(seed[:])
}

// recordRoll appends a settled bet to history (capped) and updates stats.
func recordRoll(caller address, kind, choice string, roll int, bet, payout int64, seedHash [32]byte) {
	totalBets++
	totalWagered += bet
	if payout > 0 {
		totalWins++
		totalPaidOut += payout
	}
	st := players[caller]
	if st == nil {
		st = &playerStats{}
		players[caller] = st
	}
	st.bets++
	st.wagered += bet
	if payout > 0 {
		st.wins++
		if payout > st.biggestWin {
			st.biggestWin = payout
		}
	}
	rolls = append(rolls, rollRecord{
		seq: rollSeq, player: caller, kind: kind, choice: choice,
		roll: roll, bet: bet, payout: payout,
	})
	if len(rolls) > maxHistory {
		// Drop the oldest entry; copy so the backing array does not grow.
		kept := make([]rollRecord, 0, maxHistory)
		kept = append(kept, rolls[len(rolls)-maxHistory:]...)
		rolls = kept
	}
	rollSeq++
	prevRollHash = seedHash
}

// realmBankroll reads the realm's own ugnot balance (single denom read).
func realmBankroll() int64 {
	return banker.NewReadonlyBanker().GetCoin(chain.PackageAddress(pkgPath), denom)
}
