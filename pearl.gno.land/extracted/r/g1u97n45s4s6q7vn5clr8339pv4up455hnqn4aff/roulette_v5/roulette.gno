// Package roulette — American Provably Fair Live Casino (38 pockets) + DeFi LP.
//
// v5: Multiplayer high-throughput table
//  - Many simultaneous bets per open round (bets []Bet)
//  - Shared table result: sha256(serverSeed+roundID) % 38
//  - Vault balances: wins credited in-contract; WithdrawWinnings() to wallet
//  - EmergencyReset unlocks stuck rounds (refunds to vault)
//
// Straight Up ×36. Outside (RED/BLACK/EVEN/ODD/LOW/HIGH) ×2; lose on 0 / 00.
// Allowed stakes: 0.5 / 1 / 2 / 5 / 10 GNOT only.
package roulette_v5

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

const (
	denom         = "ugnot"
	wheelSize     = 38 // 0..37 (37 == "00")
	payoutNumber  = 36
	payoutOutside = 2
	maxHistory    = 80
	maxBetsRound  = 5000 // gas / DoS bound per ResolveRound
	statusIdle    = "idle"
	statusOpen    = "open"
	minLPDeposit  = int64(1_000_000) // 1 GNOT
	defaultWindow = int64(12)        // seconds if StartRound closesAt unset
)

const (
	chip05 = int64(500_000)
	chip1  = int64(1_000_000)
	chip2  = int64(2_000_000)
	chip5  = int64(5_000_000)
	chip10 = int64(10_000_000)
)

const (
	BetNumber = "NUMBER"
	BetRed    = "RED"
	BetBlack  = "BLACK"
	BetEven   = "EVEN"
	BetOdd    = "ODD"
	BetLow    = "LOW"
	BetHigh   = "HIGH"
)

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

// Bet is one wager on the open multiplayer round.
type Bet struct {
	Player     address
	BetType    string
	BetValue   int
	ClientSeed string
	Amount     int64
	Nonce      int
}

// RoundRecord stores a resolved outcome for Render / audit.
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

type LP struct {
	Address address
	Shares  int64
	Deposit int64
}

var (
	admin            address
	bankroll         int64
	reservedLiability int64 // max net payout still owed on open bets
	status           = statusIdle
	serverSeedHash   string
	bets             []Bet
	roundID          int
	nonceCounter     int
	lastResult       = -1
	history          []RoundRecord
	bettingClosesAt  int64 // unix seconds (block time)
	balances         = map[address]int64{}

	lps               []LP
	totalShares       int64
	totalDeposits     int64
	accumulatedProfit int64
)

// ---------------------------------------------------------------------------
// Admin bankroll
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
	available := bankroll - reservedLiability
	if amount > available {
		panic("roulette: insufficient free bankroll for withdrawal")
	}
	bankroll -= amount
	sendUgnot(cur, cur.Previous().Address(), amount)
}

// ---------------------------------------------------------------------------
// Commit–Reveal (multiplayer)
// ---------------------------------------------------------------------------

// StartRound opens betting. closesAt is unix seconds (block time); if <= now,
// defaults to now + 12s so the croupier clock stays synchronized for clients.
func StartRound(cur realm, hash string, closesAt int64) {
	claimOrAssertAdmin(cur.Previous().Address())
	if status == statusOpen {
		panic("roulette: a round is already open")
	}
	if hash == "" {
		panic("roulette: serverSeedHash is empty")
	}
	if len(bets) != 0 {
		panic("roulette: inconsistent state (bets not cleared)")
	}
	roundID++
	serverSeedHash = strings.ToLower(hash)
	status = statusOpen
	now := time.Now().Unix()
	if closesAt <= now {
		bettingClosesAt = now + defaultWindow
	} else {
		bettingClosesAt = closesAt
	}
}

// PlaceBet appends a wager for the open round. Many players / many bets OK.
func PlaceBet(cur realm, betType string, betValue int, clientSeed string) {
	requireUserCall(cur)
	if status != statusOpen {
		panic("roulette: no open round (call StartRound first)")
	}
	if time.Now().Unix() > bettingClosesAt {
		panic("roulette: betting window closed")
	}
	if len(bets) >= maxBetsRound {
		panic("roulette: round bet capacity reached")
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

	exposure := amount * (payoutFor(bt) - 1)
	if bankroll-reservedLiability < exposure {
		panic("roulette: insufficient bankroll to cover potential payout")
	}

	bankroll += amount
	reservedLiability += exposure
	nonceCounter++
	bets = append(bets, Bet{
		Player:     cur.Previous().Address(),
		BetType:    bt,
		BetValue:   betValue,
		ClientSeed: clientSeed,
		Amount:     amount,
		Nonce:      nonceCounter,
	})
}

// ResolveRound settles EVERY open bet against one shared table result
// (VerifyFairnessRound). Winners are credited to the vault — no per-winner sends.
func ResolveRound(cur realm, serverSeed string) {
	claimOrAssertAdmin(cur.Previous().Address())
	if status != statusOpen {
		panic("roulette: no open round to resolve")
	}
	if serverSeed == "" {
		panic("roulette: serverSeed is empty")
	}
	actualHash := hashHex(serverSeed)
	if actualHash != serverSeedHash {
		panic("roulette: serverSeed does not match commit (possible cheat attempt)")
	}

	if len(bets) == 0 {
		resolveRoundNoBet(serverSeed)
		return
	}

	result := VerifyFairnessRound(serverSeed, roundID)
	lastResult = result

	for i := range bets {
		bet := bets[i]
		exposure := bet.Amount * (payoutFor(bet.BetType) - 1)
		reservedLiability -= exposure
		if reservedLiability < 0 {
			reservedLiability = 0
		}

		won := betWins(bet.BetType, bet.BetValue, result)
		payout := int64(0)
		if won {
			payout = bet.Amount * payoutFor(bet.BetType)
			if bankroll < payout {
				panic("roulette: insufficient bankroll to credit winnings")
			}
			bankroll -= payout
			balances[bet.Player] += payout
		} else {
			accumulatedProfit += bet.Amount
		}

		appendRoundRecord(RoundRecord{
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
	}

	bets = nil
	serverSeedHash = ""
	bettingClosesAt = 0
	status = statusIdle
}

// WithdrawWinnings sends the caller's full vault balance to their wallet.
func WithdrawWinnings(cur realm) {
	requireUserCall(cur)
	caller := cur.Previous().Address()
	amount := balances[caller]
	if amount <= 0 {
		panic("roulette: no vault balance to withdraw")
	}
	balances[caller] = 0
	sendUgnot(cur, caller, amount)
}

// EmergencyReset unlocks a stuck round. Open stakes are refunded to the vault.
func EmergencyReset(cur realm) string {
	claimOrAssertAdmin(cur.Previous().Address())

	if status == statusOpen {
		for i := range bets {
			bet := bets[i]
			exposure := bet.Amount * (payoutFor(bet.BetType) - 1)
			reservedLiability -= exposure
			if reservedLiability < 0 {
				reservedLiability = 0
			}
			if bankroll < bet.Amount {
				panic("roulette: insufficient bankroll to refund bet")
			}
			bankroll -= bet.Amount
			balances[bet.Player] += bet.Amount
			appendRoundRecord(RoundRecord{
				RoundID:        roundID,
				ServerSeedHash: serverSeedHash,
				Result:         -1,
				Player:         bet.Player,
				BetType:        bet.BetType,
				BetValue:       bet.BetValue,
				BetAmount:      bet.Amount,
				Won:            false,
				Payout:         0,
			})
		}
		if len(bets) == 0 {
			appendRoundRecord(RoundRecord{
				RoundID:        roundID,
				ServerSeedHash: serverSeedHash,
				Result:         -1,
			})
		}
	}

	bets = nil
	reservedLiability = 0
	serverSeedHash = ""
	bettingClosesAt = 0
	status = statusIdle
	lastResult = -1
	return "Round emergency reset successful"
}

func resolveRoundNoBet(serverSeed string) {
	result := VerifyFairnessRound(serverSeed, roundID)
	lastResult = result
	appendRoundRecord(RoundRecord{
		RoundID:        roundID,
		ServerSeedHash: serverSeedHash,
		ServerSeed:     serverSeed,
		Result:         result,
	})
	bets = nil
	serverSeedHash = ""
	bettingClosesAt = 0
	status = statusIdle
}

func appendRoundRecord(rec RoundRecord) {
	history = append(history, rec)
	if len(history) > maxHistory {
		history = history[len(history)-maxHistory:]
	}
}

func VerifyFairness(serverSeed, clientSeed string, nonce int) int {
	payload := serverSeed + clientSeed + strconv.Itoa(nonce)
	sum := sha256.Sum256([]byte(payload))
	n := binary.BigEndian.Uint64(sum[:8])
	return int(n % uint64(wheelSize))
}

func VerifyFairnessRound(serverSeed string, roundNum int) int {
	payload := serverSeed + strconv.Itoa(roundNum)
	sum := sha256.Sum256([]byte(payload))
	n := binary.BigEndian.Uint64(sum[:8])
	return int(n % uint64(wheelSize))
}

// ---------------------------------------------------------------------------
// DeFi Liquidity Pool
// ---------------------------------------------------------------------------

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

	for i := range lps {
		if lps[i].Address == caller {
			lps[i].Shares += shares
			lps[i].Deposit += amount
			return
		}
	}
	lps = append(lps, LP{Address: caller, Shares: shares, Deposit: amount})
}

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
	available := bankroll - reservedLiability
	if payout > available {
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
	lps = append(lps[:idx], lps[idx+1:]...)
	sendUgnot(cur, caller, payout)
}

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

func GetAdmin() address           { return admin }
func GetBankroll() int64          { return bankroll }
func GetReservedLiability() int64 { return reservedLiability }
func GetStatus() string           { return status }
func GetLastResult() int          { return lastResult }
func GetRoundID() int             { return roundID }
func GetServerSeedHash() string   { return serverSeedHash }
func GetHistory() []RoundRecord   { return history }
func IsRed(n int) bool            { return reds[n] }
func GetTotalShares() int64       { return totalShares }
func GetTotalDeposits() int64     { return totalDeposits }
func GetAccumulatedProfit() int64 { return accumulatedProfit }
func GetLPCount() int             { return len(lps) }
func GetBetCount() int            { return len(bets) }
func GetBettingClosesAt() int64   { return bettingClosesAt }
func HasCurrentBet() bool         { return len(bets) > 0 }

func GetVaultBalance(addr string) int64 {
	return balances[address(addr)]
}

func GetCurrentBetPlayer() string {
	if len(bets) == 0 {
		return ""
	}
	return bets[0].Player.String()
}

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
	b.WriteString("# American Roulette 38 — Live Multiplayer (v5)\n\n")
	b.WriteString("Shared table result: `sha256(serverSeed+roundID) % 38`. ")
	b.WriteString("Wins credit an internal vault — call `WithdrawWinnings`.\n\n")

	b.WriteString("## Status\n\n")
	b.WriteString("- **State**: `" + status + "`\n")
	b.WriteString("- **Casino Bankroll**: `" + strconv.FormatInt(bankroll, 10) + denom + "`\n")
	b.WriteString("- **Reserved liability**: `" + strconv.FormatInt(reservedLiability, 10) + denom + "`\n")
	b.WriteString("- **Round**: `" + strconv.Itoa(roundID) + "`\n")
	if lastResult >= 0 {
		b.WriteString("- **Last number**: `" + DisplayLabel(lastResult) + "` (" + colorName(lastResult) + ")\n")
	}
	if status == statusOpen {
		b.WriteString("- **Commit**: `" + serverSeedHash + "`\n")
		b.WriteString("- **Betting closes at**: `" + strconv.FormatInt(bettingClosesAt, 10) + "`\n")
		b.WriteString("- **Open bets**: `" + strconv.Itoa(len(bets)) + "`\n")
	}

	b.WriteString("\n## Liquidity Pool\n\n")
	b.WriteString("- **Total deposits**: `" + strconv.FormatInt(totalDeposits, 10) + denom + "`\n")
	b.WriteString("- **Total shares**: `" + strconv.FormatInt(totalShares, 10) + "`\n")
	b.WriteString("- **Accumulated profit**: `" + strconv.FormatInt(accumulatedProfit, 10) + denom + "`\n")
	b.WriteString("- **Active LPs**: `" + strconv.Itoa(len(lps)) + "`\n")

	b.WriteString("\n## History\n\n")
	if len(history) == 0 {
		b.WriteString("_No rounds yet._\n\n")
	} else {
		shown := 0
		for i := len(history) - 1; i >= 0 && shown < 30; i-- {
			h := history[i]
			shown++
			if h.Result < 0 {
				b.WriteString("- #" + strconv.Itoa(h.RoundID) + " → _aborted/refund_")
				if h.BetAmount > 0 {
					b.WriteString(" `" + strconv.FormatInt(h.BetAmount, 10) + denom + "`")
				}
				b.WriteString("\n")
				continue
			}
			if h.BetAmount == 0 {
				b.WriteString("- #" + strconv.Itoa(h.RoundID) + " → **" + DisplayLabel(h.Result) +
					"** | _no bets_\n")
				continue
			}
			out := "LOSS"
			if h.Won {
				out = "WIN +" + strconv.FormatInt(h.Payout, 10) + denom + " (vault)"
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
	b.WriteString("Live table: `sha256(serverSeed + roundID) % 38`. ")
	b.WriteString("Result `37` displays as **00**. Outside bets lose on **0** and **00**.\n")
	return b.String()
}

// ---------------------------------------------------------------------------
// Helpers
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
