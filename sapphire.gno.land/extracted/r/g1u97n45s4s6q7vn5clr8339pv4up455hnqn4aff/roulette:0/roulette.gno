// Package roulette implements a custom 35-pocket Provably Fair roulette (0–34).
//
// Round flow:
//  1. StartRound(serverSeedHash) — admin commit
//  2. PlaceBet(betType, betValue, clientSeed) — player wager in ugnot (-send)
//  3. ResolveRound(serverSeed) — reveal; result =
//     BigEndian(sha256(serverSeed+clientSeed+nonce)[:8]) % 35
//
// Straight-up NUMBER wins pay ×35. Outside bets (RED/BLACK/EVEN/ODD/LOW/HIGH) pay ×2.
// If the result is 0, all outside bets lose.
package roulette

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
	wheelSize     = 35 // 0–34
	payoutNumber  = 35
	payoutOutside = 2
	maxHistory    = 20
	statusIdle    = "idle"
	statusOpen    = "open"
)

// Accepted bet types.
const (
	BetNumber = "NUMBER" // straight up (0–34), pays 35x
	BetRed    = "RED"
	BetBlack  = "BLACK"
	BetEven   = "EVEN"
	BetOdd    = "ODD"
	BetLow    = "LOW"  // 1–17
	BetHigh   = "HIGH" // 18–34
)

// Red pockets (17). Black pockets are the remaining 1–34. Zero is green.
var reds = map[int]bool{
	1: true, 3: true, 5: true, 7: true, 9: true, 12: true, 14: true, 16: true,
	18: true, 19: true, 21: true, 23: true, 25: true, 27: true, 30: true, 32: true, 34: true,
}

// Bet is a single wager for the open round.
type Bet struct {
	Player     address
	BetType    string
	BetValue   int // pocket number when NUMBER, otherwise 0
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
	Result         int
	Player         address
	BetType        string
	BetValue       int
	BetAmount      int64
	Won            bool
	Payout         int64
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
)

// ---------------------------------------------------------------------------
// Bankroll & admin
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
// betValue: 0–34 when NUMBER, otherwise 0.
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
	mult := payoutFor(bt)
	// Coverage: after crediting the stake, bankroll >= amount * mult
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

// VerifyFairness is pure: sha256(serverSeed+clientSeed+nonce) → BE uint64 % 35
func VerifyFairness(serverSeed, clientSeed string, nonce int) int {
	payload := serverSeed + clientSeed + strconv.Itoa(nonce)
	sum := sha256.Sum256([]byte(payload))
	n := binary.BigEndian.Uint64(sum[:8])
	return int(n % uint64(wheelSize))
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

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Roulette 35 — Provably Fair\n\n")
	b.WriteString("Custom wheel **0–34** (0 green, 17 red, 17 black).\n\n")

	b.WriteString("## Status\n\n")
	b.WriteString("- **State**: `" + status + "`\n")
	b.WriteString("- **Casino Bankroll**: `" + strconv.FormatInt(bankroll, 10) + denom + "`\n")
	b.WriteString("- **Round**: `" + strconv.Itoa(roundID) + "`\n")
	if lastResult >= 0 {
		b.WriteString("- **Last number**: `" + strconv.Itoa(lastResult) + "` (" + colorName(lastResult) + ")\n")
	}
	if status == statusOpen {
		b.WriteString("- **Commit**: `" + serverSeedHash + "`\n")
		if currentBet != nil {
			b.WriteString("- **Bet**: `" + currentBet.BetType)
			if currentBet.BetType == BetNumber {
				b.WriteString(" " + strconv.Itoa(currentBet.BetValue))
			}
			b.WriteString("` · `" + strconv.FormatInt(currentBet.Amount, 10) + denom +
				"` · nonce `" + strconv.Itoa(currentBet.Nonce) + "`\n")
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
			b.WriteString("- #" + strconv.Itoa(h.RoundID) + " → **" + strconv.Itoa(h.Result) +
				"** | " + h.BetType)
			if h.BetType == BetNumber {
				b.WriteString("(" + strconv.Itoa(h.BetValue) + ")")
			}
			b.WriteString(" " + strconv.FormatInt(h.BetAmount, 10) + denom + " | " + out + "\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## Provably Fair\n\n")
	b.WriteString("The roll result is computed deterministically using SHA-256: ")
	b.WriteString("`sha256(serverSeed + clientSeed + nonce) % 35`. ")
	b.WriteString("You can independently verify that the outcome was not altered by the casino.\n\n")
	b.WriteString("Payouts: Straight Up (NUMBER) ×35 · RED/BLACK/EVEN/ODD/LOW/HIGH ×2 · ")
	b.WriteString("**0** loses all outside bets.\n")
	return b.String()
}

// ---------------------------------------------------------------------------
// Settlement logic
// ---------------------------------------------------------------------------

func validateBet(bt string, betValue int) {
	switch bt {
	case BetNumber:
		if betValue < 0 || betValue >= wheelSize {
			panic("roulette: betValue must be between 0 and 34 for NUMBER")
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

// betWins — zero loses every outside bet; NUMBER(0) can still win.
func betWins(bt string, betValue, result int) bool {
	switch bt {
	case BetNumber:
		return betValue == result
	case BetRed:
		return result != 0 && reds[result]
	case BetBlack:
		return result != 0 && !reds[result]
	case BetEven:
		return result != 0 && result%2 == 0
	case BetOdd:
		return result != 0 && result%2 == 1
	case BetLow:
		return result >= 1 && result <= 17
	case BetHigh:
		return result >= 18 && result <= 34
	default:
		return false
	}
}

func colorName(n int) string {
	if n == 0 {
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
