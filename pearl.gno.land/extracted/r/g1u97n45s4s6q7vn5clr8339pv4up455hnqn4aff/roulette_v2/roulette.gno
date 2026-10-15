// Package roulette — American Provably Fair roulette (38 pockets) + DeFi LP.
//
// Pockets: 0 and 37 ("00") are green; 1–36 are red/black.
// Fairness: BigEndian(sha256(serverSeed+clientSeed+nonce)[:8]) % 38 → 0..37
//
// Straight Up pays ×36. Outside bets (RED/BLACK/EVEN/ODD/LOW/HIGH) pay ×2
// and lose when the result is 0 or 37 (00).
//
// Allowed stakes only: 0.5 / 1 / 2 / 5 / 10 GNOT (ugnot equivalents below).
// Anyone may DepositLiquidity / WithdrawLiquidity as an LP.
package roulette_v2

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"strconv"
	"strings"
)

const (
	denom         = "ugnot"
	wheelSize     = 38 // 0..37 (37 == "00")
	payoutNumber  = 36 // American straight-up
	payoutOutside = 2
	maxHistory    = 20
	statusIdle    = "idle"
	statusOpen    = "open"
	minLPDeposit  = int64(1_000_000) // 1 GNOT
)

// Allowed chip sizes (ugnot).
const (
	chip05  = int64(500_000)    // 0.5 GNOT
	chip1   = int64(1_000_000)  // 1 GNOT
	chip2   = int64(2_000_000)  // 2 GNOT
	chip5   = int64(5_000_000)  // 5 GNOT
	chip10  = int64(10_000_000) // 10 GNOT
)

// Accepted bet types.
const (
	BetNumber = "NUMBER" // straight up: 0, 37("00"), or 1–36 — pays 36x
	BetRed    = "RED"
	BetBlack  = "BLACK"
	BetEven   = "EVEN"
	BetOdd    = "ODD"
	BetLow    = "LOW"  // 1–18
	BetHigh   = "HIGH" // 19–36
)

// American red pockets (18). Blacks are the remaining 1–36.
var reds = map[int]bool{
	1: true, 3: true, 5: true, 7: true, 9: true, 12: true, 14: true, 16: true, 18: true,
	19: true, 21: true, 23: true, 25: true, 27: true, 30: true, 32: true, 34: true, 36: true,
}

var validAmounts = map[int64]bool{
	chip05: true,
	chip1:  true,
	chip2:  true,
	chip5:  true,
	chip10: true,
}

// Bet is a single wager for the open round.
type Bet struct {
	Player     address
	BetType    string
	BetValue   int // 0 / 37 / 1–36 when NUMBER, else 0
	ClientSeed string
	Amount     int64
	Nonce      int
}

// RoundRecord stores a resolved round for Render / audit.
type RoundRecord struct {
	RoundID        int
	ServerSeedHash string
	ServerSeed     string
	ClientSeed     string
	Nonce          int
	Result         int // 0..37
	Player         address
	BetType        string
	BetValue       int
	BetAmount      int64
	Won            bool
	Payout         int64
}

// LP is a liquidity provider position.
type LP struct {
	Address address
	Shares  int64
	Deposit int64
}

var (
	admin          address
	bankroll       int64
	status         = statusIdle
	serverSeedHash string
	currentBet     *Bet
	roundID        int
	nonceCounter   int
	lastResult     = -1
	history        []RoundRecord

	// DeFi liquidity pool
	lps               []LP
	totalShares       int64
	totalDeposits     int64
	accumulatedProfit int64
)

// ---------------------------------------------------------------------------
// Admin bankroll (optional top-up / withdraw by first depositor / admin)
// ---------------------------------------------------------------------------

func DepositBankroll(cur realm) {
	requireUserCall(cur)
	caller := cur.Previous().Address()
	claimOrAssertAdmin(caller)
	bankroll += requireUgnotSend()
}

func WithdrawBankroll(cur realm, amount int64) {
	requireUserCall(cur)
	claimOrAssertAdmin(cur.Previous().Address())
	if amount <= 0 {
		panic("roulette: withdraw amount must be positive")
	}
	if amount > bankroll {
		panic("roulette: insufficient bankroll for withdrawal")
	}
	bankroll -= amount
	sendUgnot(cur, cur.Previous().Address(), amount)
}

// ---------------------------------------------------------------------------
// Commit–Reveal
// ---------------------------------------------------------------------------

func StartRound(cur realm, hash string) {
	claimOrAssertAdmin(cur.Previous().Address())
	if status == statusOpen {
		panic("roulette: a round is already open")
	}
	if hash == "" {
		panic("roulette: serverSeedHash is empty")
	}
	if currentBet != nil {
		panic("roulette: inconsistent state (bet already placed)")
	}
	roundID++
	serverSeedHash = strings.ToLower(hash)
	status = statusOpen
	currentBet = nil
}

// PlaceBet records a wager.
// betType: NUMBER | RED | BLACK | EVEN | ODD | LOW | HIGH
// betValue: 0 / 37 / 1–36 when NUMBER, otherwise 0.
// Send must be exactly 0.5 / 1 / 2 / 5 / 10 GNOT.
func PlaceBet(cur realm, betType string, betValue int, clientSeed string) {
	requireUserCall(cur)
	if status != statusOpen {
		panic("roulette: no open round (call StartRound first)")
	}
	if currentBet != nil {
		panic("roulette: a bet is already placed for this round")
	}
	if clientSeed == "" {
		panic("roulette: clientSeed is empty")
	}

	bt := strings.ToUpper(strings.TrimSpace(betType))
	validateBet(bt, betValue)

	amount := requireUgnotSend()
	if !validAmounts[amount] {
		panic("invalid bet amount: only 0.5, 1, 2, 5, or 10 GNOT allowed")
	}

	mult := payoutFor(bt)
	if bankroll < amount*(mult-1) {
		panic("roulette: insufficient bankroll to cover potential payout")
	}

	bankroll += amount
	nonceCounter++
	currentBet = &Bet{
		Player:     cur.Previous().Address(),
		BetType:    bt,
		BetValue:   betValue,
		ClientSeed: clientSeed,
		Amount:     amount,
		Nonce:      nonceCounter,
	}
}

func ResolveRound(cur realm, serverSeed string) {
	claimOrAssertAdmin(cur.Previous().Address())
	if status != statusOpen {
		panic("roulette: no open round to resolve")
	}
	if currentBet == nil {
		panic("roulette: no bet to resolve")
	}
	if serverSeed == "" {
		panic("roulette: serverSeed is empty")
	}

	actualHash := hashHex(serverSeed)
	if actualHash != serverSeedHash {
		panic("roulette: serverSeed does not match commit (possible cheat attempt)")
	}

	bet := currentBet
	result := VerifyFairness(serverSeed, bet.ClientSeed, bet.Nonce)
	lastResult = result

	won := betWins(bet.BetType, bet.BetValue, result)
	payout := int64(0)
	if won {
		payout = bet.Amount * payoutFor(bet.BetType)
		if bankroll < payout {
			panic("roulette: insufficient bankroll to pay winnings")
		}
		bankroll -= payout
		sendUgnot(cur, bet.Player, payout)
	} else {
		// Player loss stays in bankroll and accrues to LP profit
		accumulatedProfit += bet.Amount
	}

	history = append(history, RoundRecord{
		RoundID:        roundID,
		ServerSeedHash: serverSeedHash,
		ServerSeed:     serverSeed,
		ClientSeed:     bet.ClientSeed,
		Nonce:          bet.Nonce,
		Result:         result,
		Player:         bet.Player,
		BetType:        bet.BetType,
		BetValue:       bet.BetValue,
		BetAmount:      bet.Amount,
		Won:            won,
		Payout:         payout,
	})
	if len(history) > maxHistory {
		history = history[len(history)-maxHistory:]
	}

	currentBet = nil
	serverSeedHash = ""
	status = statusIdle
}

// VerifyFairness — pure: sha256(serverSeed+clientSeed+nonce) → BE uint64 % 38
func VerifyFairness(serverSeed, clientSeed string, nonce int) int {
	payload := serverSeed + clientSeed + strconv.Itoa(nonce)
	sum := sha256.Sum256([]byte(payload))
	n := binary.BigEndian.Uint64(sum[:8])
	return int(n % uint64(wheelSize))
}

// ---------------------------------------------------------------------------
// DeFi Liquidity Pool
// ---------------------------------------------------------------------------

// DepositLiquidity accepts ugnot (-send) and mints proportional LP shares.
// Minimum deposit: 1 GNOT.
func DepositLiquidity(cur realm) {
	requireUserCall(cur)
	caller := cur.Previous().Address()
	amount := requireUgnotSend()
	if amount < minLPDeposit {
		panic("roulette: minimum LP deposit is 1 GNOT")
	}

	var shares int64
	if totalShares == 0 || totalDeposits == 0 {
		shares = amount
	} else {
		shares = (amount * totalShares) / totalDeposits
		if shares <= 0 {
			panic("roulette: deposit too small to mint shares")
		}
	}

	bankroll += amount
	totalShares += shares
	totalDeposits += amount

	// Merge into existing position if same address
	for i := range lps {
		if lps[i].Address == caller {
			lps[i].Shares += shares
			lps[i].Deposit += amount
			return
		}
	}
	lps = append(lps, LP{Address: caller, Shares: shares, Deposit: amount})
}

// WithdrawLiquidity redeems the caller's full LP position (deposit + profit share).
func WithdrawLiquidity(cur realm) {
	requireUserCall(cur)
	caller := cur.Previous().Address()
	idx := findLP(caller)
	if idx < 0 {
		panic("roulette: no LP position for caller")
	}

	lp := lps[idx]
	profit := int64(0)
	if totalShares > 0 && accumulatedProfit > 0 {
		profit = (lp.Shares * accumulatedProfit) / totalShares
	}
	payout := lp.Deposit + profit
	if payout <= 0 {
		panic("roulette: nothing to withdraw")
	}
	if bankroll < payout {
		panic("roulette: insufficient bankroll for LP withdrawal")
	}

	bankroll -= payout
	if accumulatedProfit >= profit {
		accumulatedProfit -= profit
	} else {
		accumulatedProfit = 0
	}
	totalShares -= lp.Shares
	totalDeposits -= lp.Deposit
	if totalShares < 0 {
		totalShares = 0
	}
	if totalDeposits < 0 {
		totalDeposits = 0
	}

	// Remove LP entry
	lps = append(lps[:idx], lps[idx+1:]...)

	sendUgnot(cur, caller, payout)
}

// GetLPInfo returns a human-readable summary for addr.
func GetLPInfo(addr string) string {
	a := address(addr)
	idx := findLP(a)
	if idx < 0 {
		return "no LP position"
	}
	lp := lps[idx]
	profit := int64(0)
	if totalShares > 0 && accumulatedProfit > 0 {
		profit = (lp.Shares * accumulatedProfit) / totalShares
	}
	return "deposit=" + strconv.FormatInt(lp.Deposit, 10) +
		"ugnot shares=" + strconv.FormatInt(lp.Shares, 10) +
		" profit=" + strconv.FormatInt(profit, 10) + "ugnot"
}

// GetPoolStats returns global LP pool statistics.
func GetPoolStats() string {
	return "deposits=" + strconv.FormatInt(totalDeposits, 10) +
		"ugnot shares=" + strconv.FormatInt(totalShares, 10) +
		" profit=" + strconv.FormatInt(accumulatedProfit, 10) +
		"ugnot lps=" + strconv.Itoa(len(lps)) +
		" bankroll=" + strconv.FormatInt(bankroll, 10) + "ugnot"
}

func findLP(addr address) int {
	for i := range lps {
		if lps[i].Address == addr {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Getters
// ---------------------------------------------------------------------------

func GetAdmin() address         { return admin }
func GetBankroll() int64        { return bankroll }
func GetStatus() string         { return status }
func GetLastResult() int        { return lastResult }
func GetRoundID() int           { return roundID }
func GetServerSeedHash() string { return serverSeedHash }
func GetHistory() []RoundRecord { return history }
func IsRed(n int) bool          { return reds[n] }
func GetTotalShares() int64     { return totalShares }
func GetTotalDeposits() int64   { return totalDeposits }
func GetAccumulatedProfit() int64 {
	return accumulatedProfit
}
func GetLPCount() int { return len(lps) }

// DisplayLabel maps internal result 0..37 → "0" / "00" / "1".."36"
func DisplayLabel(n int) string {
	if n == 37 {
		return "00"
	}
	return strconv.Itoa(n)
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# American Roulette 38 — Provably Fair\n\n")
	b.WriteString("Pockets **0**, **00**, and **1–36**. Fairness: `sha256(serverSeed+clientSeed+nonce) % 38`.\n\n")

	b.WriteString("## Status\n\n")
	b.WriteString("- **State**: `" + status + "`\n")
	b.WriteString("- **Casino Bankroll**: `" + strconv.FormatInt(bankroll, 10) + denom + "`\n")
	b.WriteString("- **Round**: `" + strconv.Itoa(roundID) + "`\n")
	if lastResult >= 0 {
		b.WriteString("- **Last number**: `" + DisplayLabel(lastResult) + "` (" + colorName(lastResult) + ")\n")
	}
	if status == statusOpen {
		b.WriteString("- **Commit**: `" + serverSeedHash + "`\n")
		if currentBet != nil {
			b.WriteString("- **Bet**: `" + currentBet.BetType)
			if currentBet.BetType == BetNumber {
				b.WriteString(" " + DisplayLabel(currentBet.BetValue))
			}
			b.WriteString("` · `" + strconv.FormatInt(currentBet.Amount, 10) + denom +
				"` · nonce `" + strconv.Itoa(currentBet.Nonce) + "`\n")
		}
	}

	b.WriteString("\n## Liquidity Pool\n\n")
	b.WriteString("- **Total deposits**: `" + strconv.FormatInt(totalDeposits, 10) + denom + "`\n")
	b.WriteString("- **Total shares**: `" + strconv.FormatInt(totalShares, 10) + "`\n")
	b.WriteString("- **Accumulated profit**: `" + strconv.FormatInt(accumulatedProfit, 10) + denom + "`\n")
	b.WriteString("- **Active LPs**: `" + strconv.Itoa(len(lps)) + "`\n")
	if len(lps) == 0 {
		b.WriteString("_No liquidity providers yet. Call `DepositLiquidity` with ≥ 1 GNOT._\n")
	} else {
		for i := range lps {
			lp := lps[i]
			profit := int64(0)
			if totalShares > 0 && accumulatedProfit > 0 {
				profit = (lp.Shares * accumulatedProfit) / totalShares
			}
			b.WriteString("- `" + lp.Address.String() + "` · deposit `" +
				strconv.FormatInt(lp.Deposit, 10) + "` · shares `" +
				strconv.FormatInt(lp.Shares, 10) + "` · profit `" +
				strconv.FormatInt(profit, 10) + "`\n")
		}
	}

	b.WriteString("\n## History\n\n")
	if len(history) == 0 {
		b.WriteString("_No rounds yet._\n\n")
	} else {
		for i := len(history) - 1; i >= 0; i-- {
			h := history[i]
			out := "LOSS"
			if h.Won {
				out = "WIN +" + strconv.FormatInt(h.Payout, 10) + denom
			}
			b.WriteString("- #" + strconv.Itoa(h.RoundID) + " → **" + DisplayLabel(h.Result) +
				"** | " + h.BetType)
			if h.BetType == BetNumber {
				b.WriteString("(" + DisplayLabel(h.BetValue) + ")")
			}
			b.WriteString(" " + strconv.FormatInt(h.BetAmount, 10) + denom + " | " + out + "\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## Provably Fair\n\n")
	b.WriteString("The roll is deterministic: `sha256(serverSeed + clientSeed + nonce) % 38`. ")
	b.WriteString("Result `37` displays as **00**. Outside bets lose on **0** and **00**.\n\n")
	b.WriteString("Payouts: Straight Up ×36 · RED/BLACK/EVEN/ODD/LOW(1–18)/HIGH(19–36) ×2.\n")
	b.WriteString("Allowed stakes: **0.5 / 1 / 2 / 5 / 10 GNOT** only.\n")
	return b.String()
}

// ---------------------------------------------------------------------------
// Settlement helpers
// ---------------------------------------------------------------------------

func validateBet(bt string, betValue int) {
	switch bt {
	case BetNumber:
		if betValue < 0 || betValue >= wheelSize {
			panic("roulette: betValue must be between 0 and 37 for NUMBER (37 = 00)")
		}
	case BetRed, BetBlack, BetEven, BetOdd, BetLow, BetHigh:
		if betValue != 0 {
			panic("roulette: betValue must be 0 for outside bets")
		}
	default:
		panic("roulette: invalid bet type (NUMBER|RED|BLACK|EVEN|ODD|LOW|HIGH)")
	}
}

func payoutFor(bt string) int64 {
	if bt == BetNumber {
		return payoutNumber
	}
	return payoutOutside
}

// betWins — 0 and 37 (00) lose every outside bet; NUMBER can still hit them.
func betWins(bt string, betValue, result int) bool {
	switch bt {
	case BetNumber:
		return betValue == result
	case BetRed:
		return result != 0 && result != 37 && reds[result]
	case BetBlack:
		return result != 0 && result != 37 && !reds[result]
	case BetEven:
		return result != 0 && result != 37 && result%2 == 0
	case BetOdd:
		return result != 0 && result != 37 && result%2 == 1
	case BetLow:
		return result >= 1 && result <= 18
	case BetHigh:
		return result >= 19 && result <= 36
	default:
		return false
	}
}

func colorName(n int) string {
	if n == 0 || n == 37 {
		return "green"
	}
	if reds[n] {
		return "red"
	}
	return "black"
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func claimOrAssertAdmin(caller address) {
	if admin == "" {
		admin = caller
		return
	}
	if caller != admin {
		panic("roulette: only admin can perform this action")
	}
}

func requireUserCall(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("roulette: only user-call (maketx call) is accepted")
	}
}

func requireUgnotSend() int64 {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom {
		panic("roulette: send ugnot only via -send")
	}
	if sent[0].Amount <= 0 {
		panic("roulette: bet amount must be positive")
	}
	return sent[0].Amount
}

func sendUgnot(cur realm, to address, amount int64) {
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(denom, amount)))
}

func hashHex(seed string) string {
	sum := sha256.Sum256([]byte(seed))
	return hex.EncodeToString(sum[:])
}
