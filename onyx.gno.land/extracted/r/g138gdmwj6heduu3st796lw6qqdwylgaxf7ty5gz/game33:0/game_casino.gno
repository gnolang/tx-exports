package game33

import (
	"crypto/sha256"
	"encoding/hex"
	"math/bits"
	"strconv"
	"strings"
	"time"

	"chain"

	"gno.land/p/nt/avl/v0"
)

// ── Casino: two-sided commit–reveal, settled and paid on chain ──────────────
//
// One round = one bet by one player:
//   1. CommitCasinoSeed(roundId, player, sha256(s))        operator
//        s is 32 fresh random bytes for this round, kept by the server.
//   2. PlaceCasinoBet(roundId, game, coin, amt, choice, sha256(c))   the player
//        c is the player's secret (made and kept by the browser). The stake is
//        debited and the bet's largest possible net win is reserved in the pool.
//   3. RevealCasinoSeed(roundId, s)                        operator
//        s must hash to the commit. The operator still doesn't know c, so it
//        doesn't know the result when it reveals.
//   4. RevealCasinoSecret(roundId, c)                      anyone (a preimage)
//        c must hash to the bet's hash; the realm rolls and settles the bet.
// Timeouts (nobody can profit from withholding):
//   - s not revealed 30 min after the bet → RefundCasinoBet (full stake back).
//   - s revealed but c not revealed within 24 h → ForfeitCasinoBet (anyone):
//     the bet settles as a loss; only the player could have known the result.
//   No refund once s is revealed.
//
// Results (the only rules; the client re-derives and shows them):
//   roll = uint32(sha256(s:c:roundId:game)[0:4]) % 100
//   coin_flip:    0..48 heads, 51..99 tails, 49/50 edge (house)      win pays 2×
//   higher_lower: 51..99 higher, 0..48 lower, 49/50 house              win pays 2×
//   rps:          0..32 player wins (2×), 33..64 push (stake back), 65..99 house
//                 wins; the house move shown is derived from that. RTP 98%.
//   slots:        reels/lines/scatters/Hold & Spin from the stream in game_slots.gno;
//                 free spins and MAJOR/GRAND jackpots in game_casino_bonus.gno.
//
// Pool safety (fixed in code):
//   coin_flip / wheel / rps bet ≤ 0.5% of the free pool; slots bet ≤ 0.004%
//   (its 500× max win then reserves ≤ 2% of the pool); every open bet reserves
//   its largest net win; open reservations ≤ 20% of the pool; net paid today +
//   reservations ≤ 10% of the pool at 00:00 UTC; opens at ≥ 20,000 grin-eq and
//   ≥ 200 units. Coins only move between players and the pool: nothing is
//   minted, and the admin can't withdraw the pool.

var (
	casinoBets     avl.Tree // roundId+":"+addr → *casinoBet
	casinoReserved avl.Tree // coin → largest net payouts of unsettled bets (string)
	casinoDay      avl.Tree // coin → "day:snapshot:paid:received" (UTC day)
)

const (
	casinoWinRange         = uint64(49)       // winning rolls per pick (of 100) for flip/wheel
	rpsWinBelow            = uint64(33)       // rps: roll < 33 player wins
	rpsPushBelow           = uint64(65)       // rps: 33..64 push
	casinoBetWindowSec     = int64(3600)      // a committed round takes its bet within 1 h
	casinoSeedTimeoutSec   = int64(1800)      // refunds open 30 min after the bet if s is never revealed
	casinoSecretTimeoutSec = int64(86400)     // the bet forfeits 24 h after s if c is never revealed
	casinoMaxBetBps        = uint64(50)       // flip / wheel / rps bet ≤ 0.5% of the free pool
	slotsMaxBetPPM         = uint64(40)       // slots bet ≤ 0.004% of the free pool
	casinoOpenBps          = uint64(2000)     // open reservations on a coin ≤ 20% of the pool
	casinoDayBps           = uint64(1000)     // daily net payout ≤ 10% of the day's snapshot
	casinoMinPoolMilli     = uint64(20000000) // ≥ 20,000 grin-equivalent …
	casinoMinPoolUnits     = uint64(200)      // … and ≥ 200 units of the coin
	casinoMaxAmount        = uint64(1000000000)
)

// Reference value per unit by rarity, in milli-grin (same table as the
// exchange plan): only used for the pool's opening threshold.
var casinoRefMilli = [7]uint64{1000, 3200, 11000, 40000, 160000, 720000, 3600000}

type casinoRound struct {
	player      string
	seedHash    string
	serverSeed  string
	status      string // committed | bet | seeded | settled | refunded | closed
	committedAt int64
	betAt       int64
	seededAt    int64
	bets        int
}

type casinoBet struct {
	addr, game, coin, choice string
	clientHash, clientSecret string
	amount, exposure         uint64
	settled, won, refunded   bool
	forfeited                bool
	roll, payout             uint64
	outcome                  string
	// slots only
	grid       string
	lineMult   uint64
	lines      int
	scatters   int
	freeSpin   bool   // a free spin from a grant (no stake)
	capped     bool   // the round's win hit the 500× cap
	fsGranted  uint64 // free spins this spin granted
	hsTiles    string // Hold & Spin tiles ("." separated, 0 = empty)
	hsRespins  int
	hsMult     uint64 // Hold & Spin win in bets (MINI/MINOR included)
	jackpots   string // "major", "grand", "major+grand" or ""
	jackpotWin uint64 // paid from the jackpot pools (outside the cap)
}

// ── roles ────────────────────────────────────────────────────────────────────

// isOperator: the casino operator key commits and reveals server seeds. Once an
// operator is set, only that key can; the admin (treasury) key only stands in
// while no operator has been named yet (bootstrap and tests).
func isOperator(cur realm) bool {
	c := cur.Previous().Address()
	if operator != address("") {
		return c == operator
	}
	return admin != address("") && c == admin
}

// SetOperator lets the admin name the server account that commits and
// reveals casino seeds. It must be its own key, never the admin/treasury key.
// The operator can't move anyone's coins.
func SetOperator(cur realm, addr string) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: admin only")
	}
	a := address(addr)
	if !a.IsValid() {
		panic("invalid address")
	}
	if a == admin {
		panic("the casino operator must be a separate key, not the admin/treasury key")
	}
	operator = a
	chain.Emit("CasinoOperatorSet", "operator", addr)
}

func Operator() string { return operator.String() }

// ── casino accounting (monitoring) ──────────────────────────────────────────
//
// Per coin: pool + MAJOR + GRAND == seeded + staked − paid, always. Per coin and
// game: rounds, staked, paid (free spins and jackpots count as slots pay), so
// realized RTP = paid / staked. Updated on every settlement; read by CasinoStats.

var casinoStats avl.Tree // coin:field or coin:game:field → uint (string)

func casStat(coin, game, field string, add uint64) {
	k := coin + ":" + field
	if game != "" {
		k = coin + ":" + game + ":" + field
	}
	casSet(&casinoStats, k, casAdd(casGet(&casinoStats, k), add))
}

func casRecord(coin, game string, staked, paid uint64) {
	casStat(coin, game, "rounds", 1)
	casStat(coin, game, "staked", staked)
	casStat(coin, game, "paid", paid)
	casStat(coin, "", "staked", staked)
	casStat(coin, "", "paid", paid)
}

// CasinoStats reports a coin's accounting: pool, reserved, jackpots, seeded,
// staked, paid, the conservation check and per-game rounds/staked/paid.
func CasinoStats(coinId string) string {
	pool := casGet(&casinoPool, coinId)
	major := casGet(&casinoJackpot, jpKey(coinId, "major"))
	grand := casGet(&casinoJackpot, jpKey(coinId, "grand"))
	seeded := casGet(&casinoStats, coinId+":seeded")
	staked := casGet(&casinoStats, coinId+":staked")
	paid := casGet(&casinoStats, coinId+":paid")
	fees := casGet(&casinoStats, coinId+":fees") // exchange protocol-fee inflow
	ok := pool+major+grand+paid == seeded+staked+fees
	out := `{"coin":"` + coinId + `","pool":"` + casU(pool) + `","reserved":"` + casU(casGet(&casinoReserved, coinId)) +
		`","major":"` + casU(major) + `","grand":"` + casU(grand) + `","seeded":"` + casU(seeded) +
		`","staked":"` + casU(staked) + `","paid":"` + casU(paid) + `","fees":"` + casU(fees) + `","conserved":` + strconv.FormatBool(ok) +
		`,"freeSpinsOpen":` + strconv.Itoa(casinoGrants.Size()) + `,"games":{`
	for i, g := range []string{"coin_flip", "higher_lower", "rps", "slots"} {
		if i > 0 {
			out += ","
		}
		out += `"` + g + `":{"rounds":` + casU(casGet(&casinoStats, coinId+":"+g+":rounds")) +
			`,"staked":"` + casU(casGet(&casinoStats, coinId+":"+g+":staked")) +
			`","paid":"` + casU(casGet(&casinoStats, coinId+":"+g+":paid")) + `"}`
	}
	return out + `}}`
}

// ── uint helpers (balances and pool values are decimal strings) ─────────────

func casGet(t *avl.Tree, key string) uint64 {
	if !t.Has(key) {
		return 0
	}
	v, _ := strconv.ParseUint(t.Get(key).(string), 10, 64)
	return v
}

func casSet(t *avl.Tree, key string, v uint64) { t.Set(key, strconv.FormatUint(v, 10)) }

func casAdd(a, b uint64) uint64 {
	s, carry := bits.Add64(a, b, 0)
	if carry != 0 {
		panic("math overflow")
	}
	return s
}

func casSub(a, b uint64) uint64 {
	if b > a {
		panic("math underflow")
	}
	return a - b
}

// casMulDiv = floor(a*b/c) with a 128-bit product.
func casMulDiv(a, b, c uint64) uint64 {
	hi, lo := bits.Mul64(a, b)
	if hi >= c {
		panic("math overflow")
	}
	q, _ := bits.Div64(hi, lo, c)
	return q
}

func casMul(a, b uint64) uint64 {
	hi, lo := bits.Mul64(a, b)
	if hi != 0 {
		panic("math overflow")
	}
	return lo
}

func casU(n uint64) string { return strconv.FormatUint(n, 10) }

func casBalOf(addr, coin string) uint64 { return casGet(&balances, addr+":"+coin) }

func casCredit(addr, coin string, amt uint64) {
	if amt > 0 {
		casSet(&balances, addr+":"+coin, casAdd(casBalOf(addr, coin), amt))
	}
}

func casDebit(addr, coin string, amt uint64) {
	have := casBalOf(addr, coin)
	if have < amt {
		panic("insufficient balance: need " + casU(amt) + " " + coin + ", have " + casU(have))
	}
	casSet(&balances, addr+":"+coin, have-amt)
}

func casGrinValueMilli(coin string, amt uint64) uint64 {
	r, ok := coinRarity[coin]
	if !ok || r < 0 || r > 6 {
		return 0
	}
	hi, lo := bits.Mul64(amt, casinoRefMilli[r])
	if hi != 0 {
		return ^uint64(0)
	}
	return lo
}

func casIsHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// casSafe: a short [A-Za-z0-9_.-] token (no quotes, so it is JSON-safe).
func casSafe(s string, maxLen int) bool {
	if s == "" || len(s) > maxLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// ── outcome rules (the only ones; the client just re-derives them) ──────────

// CasinoRoll is the on-chain roll: uint32(sha256(s:c:roundId:game)[0:4]) % 100.
func CasinoRoll(serverSeed, clientSecret, roundId, game string) uint64 {
	h := sha256.Sum256([]byte(serverSeed + ":" + clientSecret + ":" + roundId + ":" + game))
	v := uint64(h[0])<<24 | uint64(h[1])<<16 | uint64(h[2])<<8 | uint64(h[3])
	return v % 100
}

// CasinoOutcome maps a roll to what landed. For rps the outcome is
// "win" | "push" | "lose" (see rpsHouseMove for the move shown).
func CasinoOutcome(game string, roll uint64) string {
	switch game {
	case "coin_flip":
		if roll < casinoWinRange {
			return "heads"
		}
		if roll >= 100-casinoWinRange {
			return "tails"
		}
		return "edge"
	case "higher_lower":
		if roll >= 100-casinoWinRange {
			return "higher"
		}
		if roll < casinoWinRange {
			return "lower"
		}
		return "house"
	case "rps":
		if roll < rpsWinBelow {
			return "win"
		}
		if roll < rpsPushBelow {
			return "push"
		}
		return "lose"
	}
	return ""
}

// rpsHouseMove: the house move that produces the outcome against the player's move.
func rpsHouseMove(choice, outcome string) string {
	beats := map[string]string{"rock": "scissors", "paper": "rock", "scissors": "paper"} // key beats value
	switch outcome {
	case "win":
		return beats[choice]
	case "push":
		return choice
	}
	for k, v := range beats {
		if v == choice {
			return k
		}
	}
	return ""
}

func validCasinoChoice(game, choice string) bool {
	switch game {
	case "coin_flip":
		return choice == "heads" || choice == "tails"
	case "higher_lower":
		return choice == "higher" || choice == "lower"
	case "rps":
		return choice == "rock" || choice == "paper" || choice == "scissors"
	case "slots":
		return casSafe(choice, 32)
	}
	return false
}

// casinoExposure: the largest net amount a bet can take from the pool.
func casinoExposure(game string, amt uint64) uint64 {
	if game == "slots" {
		return casMul(amt, slotsMaxWinMult-1)
	}
	return amt // flip / wheel / rps win pays 2× = net +amt
}

// ── pool ────────────────────────────────────────────────────────────────────

func casDayNow() int64 { return time.Now().Unix() / 86400 }

func casinoDayState(coin string) (int64, uint64, uint64, uint64) {
	day := casDayNow()
	if casinoDay.Has(coin) {
		f := strings.Split(casinoDay.Get(coin).(string), ":")
		d, _ := strconv.ParseInt(f[0], 10, 64)
		if d == day && len(f) == 4 {
			snap, _ := strconv.ParseUint(f[1], 10, 64)
			paid, _ := strconv.ParseUint(f[2], 10, 64)
			recv, _ := strconv.ParseUint(f[3], 10, 64)
			return day, snap, paid, recv
		}
	}
	return day, casGet(&casinoPool, coin), 0, 0 // first touch of the day: snapshot the pool
}

func setCasinoDay(coin string, day int64, snap, paid, recv uint64) {
	casinoDay.Set(coin, strconv.FormatInt(day, 10)+":"+casU(snap)+":"+casU(paid)+":"+casU(recv))
}

func casinoIsOpen(coin string, pool uint64) bool {
	return pool >= casinoMinPoolUnits && casGrinValueMilli(coin, pool) >= casinoMinPoolMilli
}

func casinoMaxBet(game string, free uint64) uint64 {
	if game == "slots" {
		m := casMulDiv(free, slotsMaxBetPPM, 1000000)
		return m - m%slotsBetStep
	}
	return casMulDiv(free, casinoMaxBetBps, 10000)
}

// casinoCheckBet panics unless the pool can pay the bet's largest win in full (read-only).
func casinoCheckBet(coin, game string, amt uint64) {
	pool := casGet(&casinoPool, coin)
	reserved := casGet(&casinoReserved, coin)
	if !casinoIsOpen(coin, pool) {
		panic("casino closed for " + coin + ": the pool needs at least 20,000 grin-equivalent and 200 " + coin)
	}
	if game == "slots" && (amt < slotsBetStep || amt%slotsBetStep != 0) {
		panic("slots bet must be a multiple of 25")
	}
	free := casSub(pool, reserved)
	maxBet := casinoMaxBet(game, free)
	if amt > maxBet {
		if game == "slots" {
			panic("bet too large: slots max is 0.004 percent of the free casino pool (" + casU(maxBet) + " " + coin + ")")
		}
		panic("bet too large: max is 0.5 percent of the free casino pool (" + casU(maxBet) + " " + coin + ")")
	}
	exp := casinoExposure(game, amt)
	if casAdd(reserved, exp) > casMulDiv(pool, casinoOpenBps, 10000) {
		panic("casino busy: open bets on " + coin + " would exceed 20 percent of the pool")
	}
	_, snap, paid, recv := casinoDayState(coin)
	net := uint64(0)
	if paid > recv {
		net = paid - recv
	}
	if casAdd(casAdd(net, reserved), exp) > casMulDiv(snap, casinoDayBps, 10000) {
		panic("casino daily payout limit reached for " + coin)
	}
}

func casinoReserve(coin string, exp uint64) {
	casSet(&casinoReserved, coin, casAdd(casGet(&casinoReserved, coin), exp))
	day, snap, paid, recv := casinoDayState(coin)
	setCasinoDay(coin, day, snap, paid, recv)
}

// casinoSettle releases the reservation and moves coins: the player receives
// `payout` (0 ≤ payout ≤ stake + exposure) and the pool keeps the rest of the
// stake or pays the difference. Returns payout.
func casinoSettle(addr, coin string, amt, exposure, payout uint64) uint64 {
	if payout > casAdd(amt, exposure) {
		panic("payout above the reservation")
	}
	casSet(&casinoReserved, coin, casSub(casGet(&casinoReserved, coin), exposure))
	day, snap, paid, recv := casinoDayState(coin)
	pool := casGet(&casinoPool, coin)
	if payout >= amt {
		win := payout - amt
		casSet(&casinoPool, coin, casSub(pool, win))
		setCasinoDay(coin, day, snap, casAdd(paid, win), recv)
	} else {
		keep := amt - payout
		casSet(&casinoPool, coin, casAdd(pool, keep))
		setCasinoDay(coin, day, snap, paid, casAdd(recv, keep))
	}
	casCredit(addr, coin, payout)
	return payout
}

// SeedCasinoPool moves the ADMIN'S OWN on-chain coins into a casino pool.
// Only ever the admin's own balance; nobody can withdraw a pool back.
func SeedCasinoPool(cur realm, coinId string, amount string) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: admin only")
	}
	if _, ok := coinRarity[coinId]; !ok {
		panic("unknown coin id: " + coinId)
	}
	amt, err := strconv.ParseUint(amount, 10, 64)
	if err != nil || amt == 0 || amt > casinoMaxAmount {
		panic("invalid amount")
	}
	from := admin.String()
	casDebit(from, coinId, amt)
	casSet(&casinoPool, coinId, casAdd(casGet(&casinoPool, coinId), amt))
	casStat(coinId, "", "seeded", amt)
	chain.Emit("CasinoPoolSeeded", "coin", coinId, "from", from, "amount", amount)
}

// CasinoPool reports a coin's pool, reservation, max bets and daily counters.
func CasinoPool(coinId string) string {
	pool := casGet(&casinoPool, coinId)
	reserved := casGet(&casinoReserved, coinId)
	_, snap, paid, recv := casinoDayState(coinId)
	free := uint64(0)
	if pool > reserved {
		free = pool - reserved
	}
	return `{"coin":"` + coinId + `","pool":"` + casU(pool) + `","reserved":"` + casU(reserved) +
		`","maxBet":"` + casU(casinoMaxBet("coin_flip", free)) + `","slotsMaxBet":"` + casU(casinoMaxBet("slots", free)) +
		`","open":` + strconv.FormatBool(casinoIsOpen(coinId, pool)) +
		`,"daySnapshot":"` + casU(snap) + `","paidToday":"` + casU(paid) + `","receivedToday":"` + casU(recv) + `"}`
}

