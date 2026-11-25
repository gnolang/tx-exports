// Package tavernbets is a mini prediction-market realm for the Gnome Tavern
// Hackathon. Anyone can create a yes/no market, bet test-GNOT on either
// side, and winners claim a pro-rata share of the pool after the creator
// resolves the market.
//
// Flow: CreateMarket -> Bet (YES/NO with ugnot attached) -> Resolve by the
// creator after the deadline -> Claim by each winner.
package tavernbets

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

const (
	// ugnotDenom is the native coin of Gno.land. 1 GNOT = 1_000_000 ugnot.
	ugnotDenom = "ugnot"
	// ugnotPerGNOT converts ugnot amounts to whole GNOT for display.
	ugnotPerGNOT = int64(1_000_000)
	// maxMarketMinutes caps how far ahead a market deadline can be set
	// (525600 minutes = 365 days).
	maxMarketMinutes = int64(525600)
)

// Wager is one bet on one side of a market.
type Wager struct {
	Bettor address
	Amount int64 // ugnot
}

// Market is a yes/no prediction market.
type Market struct {
	ID       int
	Question string
	Creator  address
	Deadline int64 // unix seconds
	YesPool  int64 // ugnot
	NoPool   int64 // ugnot
	YesBets  []Wager
	NoBets   []Wager
	Resolved bool
	Outcome  bool // true = YES won
	Claimed  []address
	Refunded []address
}

// Realm state: every market ever created, and the next market id.
var markets []Market
var nextMarketID = 1

// mustMarket returns the market with the given id, or panics.
func mustMarket(id int) *Market {
	for i := range markets {
		if markets[i].ID == id {
			return &markets[i]
		}
	}
	panic("market not found")
}

// createMarket opens a new market. The deadline must be in the future.
func createMarket(caller address, question string, deadline int64, now int64) int {
	if question == "" {
		panic("question must not be empty")
	}
	if deadline <= now {
		panic("deadline must be in the future")
	}
	id := nextMarketID
	nextMarketID++
	markets = append(markets, Market{
		ID:       id,
		Question: question,
		Creator:  caller,
		Deadline: deadline,
	})
	return id
}

// placeBet records a wager of amount ugnot on one side of a market.
func placeBet(caller address, marketID int, yes bool, amount int64, now int64) {
	if amount <= 0 {
		panic("bet amount must be positive")
	}
	m := mustMarket(marketID)
	if m.Resolved {
		panic("market already resolved")
	}
	if now >= m.Deadline {
		panic("market deadline has passed")
	}
	if yes {
		m.YesPool += amount
		m.YesBets = append(m.YesBets, Wager{Bettor: caller, Amount: amount})
	} else {
		m.NoPool += amount
		m.NoBets = append(m.NoBets, Wager{Bettor: caller, Amount: amount})
	}
}

// resolveMarket settles a market. Only the creator, only after the
// deadline, only once.
func resolveMarket(caller address, marketID int, outcome bool, now int64) {
	m := mustMarket(marketID)
	if m.Creator != caller {
		panic("only the market creator can resolve")
	}
	if m.Resolved {
		panic("market already resolved")
	}
	if now < m.Deadline {
		panic("cannot resolve before the deadline")
	}
	m.Resolved = true
	m.Outcome = outcome
}

// stakeOn returns how much bettor staked on the given side (0 if none).
func stakeOn(m *Market, bettor address, yes bool) int64 {
	var total int64
	bets := m.NoBets
	if yes {
		bets = m.YesBets
	}
	for _, b := range bets {
		if b.Bettor == bettor {
			total += b.Amount
		}
	}
	return total
}

// hasClaimed reports whether bettor already claimed on this market.
func hasClaimed(m *Market, bettor address) bool {
	for _, c := range m.Claimed {
		if c == bettor {
			return true
		}
	}
	return false
}

// hasRefunded reports whether bettor already refunded on this market.
func hasRefunded(m *Market, bettor address) bool {
	for _, r := range m.Refunded {
		if r == bettor {
			return true
		}
	}
	return false
}

// claimWinnings computes the payout for a winner and marks the claim.
// Payout = stake + stake*losingPool/winningPool, in integer math. Any dust
// left by rounding stays in the realm. Panics for losers, double claims,
// unresolved markets, and markets with no winning bets at all.
func claimWinnings(caller address, marketID int) int64 {
	m := mustMarket(marketID)
	if !m.Resolved {
		panic("market not resolved yet")
	}
	if hasClaimed(m, caller) {
		panic("already claimed")
	}
	winningPool := m.YesPool
	losingPool := m.NoPool
	if !m.Outcome {
		winningPool, losingPool = m.NoPool, m.YesPool
	}
	if winningPool <= 0 {
		panic("no winning bets on this market")
	}
	stake := stakeOn(m, caller, m.Outcome)
	if stake <= 0 {
		panic("no winning bet to claim")
	}
	payout := stake + stake*losingPool/winningPool
	m.Claimed = append(m.Claimed, caller)
	return payout
}

// CreateMarket opens a yes/no market that resolves after durationMinutes.
// Minutes (not days) so the full create -> bet -> resolve -> claim loop is
// demoable in one session; a 1-day market is durationMinutes = 1440.
// Returns the new market id.
func CreateMarket(cur realm, question string, durationMinutes int64) int {
	if !cur.Previous().IsUserCall() {
		panic("direct user calls only")
	}
	if durationMinutes < 1 || durationMinutes > maxMarketMinutes {
		panic("duration must be between 1 and 525600 minutes")
	}
	now := time.Now().Unix()
	return createMarket(unsafe.OriginCaller(), question, now+durationMinutes*60, now)
}

// Bet wagers the ugnot attached to this call on one side of a market.
// yes = true bets YES, false bets NO.
func Bet(cur realm, marketID int, yes bool) {
	if !cur.Previous().IsUserCall() {
		panic("direct user calls only")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != ugnotDenom || sent[0].Amount <= 0 {
		panic("attach exactly one ugnot payment")
	}
	placeBet(unsafe.OriginCaller(), marketID, yes, sent[0].Amount, time.Now().Unix())
}

// Resolve settles a market with the final outcome (true = YES won).
func Resolve(cur realm, marketID int, outcome bool) {
	if !cur.Previous().IsUserCall() {
		panic("direct user calls only")
	}
	resolveMarket(unsafe.OriginCaller(), marketID, outcome, time.Now().Unix())
}

// Claim pays the caller their pro-rata share of a resolved market and
// returns the amount paid, in ugnot.
func Claim(cur realm, marketID int) int64 {
	if !cur.Previous().IsUserCall() {
		panic("direct user calls only")
	}
	caller := unsafe.OriginCaller()
	payout := claimWinnings(caller, marketID)
	if payout <= 0 {
		panic("nothing to claim")
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
		cur.Address(), caller, chain.NewCoins(chain.NewCoin(ugnotDenom, payout)))
	return payout
}

// refundBet returns the caller's full stake on a market that resolved with
// no winning bets at all, and marks the refund. This is the fix for the
// locked-funds case: when a market resolves to a side nobody bet on, the
// losing side's funds would otherwise stay in the realm forever. Each
// loser refunds their own stake; the refund is exact (no rounding dust).
// Panics for unresolved markets, markets with winners (use Claim instead),
// callers who staked nothing, and double refunds.
func refundBet(caller address, marketID int) int64 {
	m := mustMarket(marketID)
	if !m.Resolved {
		panic("market not resolved yet")
	}
	winningPool := m.YesPool
	if !m.Outcome {
		winningPool = m.NoPool
	}
	if winningPool > 0 {
		panic("winners exist on this market, use Claim")
	}
	if hasRefunded(m, caller) {
		panic("already refunded")
	}
	stake := stakeOn(m, caller, !m.Outcome)
	if stake <= 0 {
		panic("no bet to refund")
	}
	m.Refunded = append(m.Refunded, caller)
	return stake
}

// Refund returns the caller's full stake on a market that resolved with no
// winning bets (nobody bet on the winning side). If winners exist, use
// Claim instead.
func Refund(cur realm, marketID int) int64 {
	if !cur.Previous().IsUserCall() {
		panic("direct user calls only")
	}
	caller := unsafe.OriginCaller()
	amount := refundBet(caller, marketID)
	if amount <= 0 {
		panic("nothing to refund")
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
		cur.Address(), caller, chain.NewCoins(chain.NewCoin(ugnotDenom, amount)))
	return amount
}

// Render shows all markets as Markdown for gnoweb.
func Render(path string) string {
	var b strings.Builder
	b.WriteString("# Tavern Bets\n\n")
	b.WriteString("Mini prediction market. Create a yes/no question, bet test-GNOT, and winners split the pool pro-rata. 1 GNOT = 1,000,000 ugnot.\n\n")
	if len(markets) == 0 {
		b.WriteString("No markets yet. Create the first one from the Actions tab.\n")
		return b.String()
	}
	for _, m := range markets {
		b.WriteString("## #" + strconv.Itoa(m.ID) + " — " + m.Question + "\n\n")
		b.WriteString("- Creator: `" + m.Creator.String() + "`\n")
		b.WriteString("- Deadline: " + time.Unix(m.Deadline, 0).Format("2006-01-02 15:04 UTC") + "\n")
		b.WriteString("- YES pool: " + formatGNOT(m.YesPool) + " (" + strconv.Itoa(len(m.YesBets)) + " bets)\n")
		b.WriteString("- NO pool: " + formatGNOT(m.NoPool) + " (" + strconv.Itoa(len(m.NoBets)) + " bets)\n")
		if m.Resolved {
			outcome := "NO"
			if m.Outcome {
				outcome = "YES"
			}
			b.WriteString("- Status: **resolved — " + outcome + " won**\n")
			winningPool := m.YesPool
			if !m.Outcome {
				winningPool = m.NoPool
			}
			if winningPool == 0 {
				b.WriteString("- No winners: losing bets can be refunded with Refund.\n")
			}
		} else {
			b.WriteString("- Status: **open**\n")
		}
		b.WriteString("\n")
	}
	return b.String()
}

// formatGNOT renders an ugnot amount as "X.XXXXXX GNOT".
func formatGNOT(ugnot int64) string {
	whole := ugnot / ugnotPerGNOT
	frac := ugnot % ugnotPerGNOT
	return strconv.FormatInt(whole, 10) + "." + pad6(frac) + " GNOT"
}

// pad6 left-pads a number with zeroes to 6 digits.
func pad6(n int64) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < 6 {
		s = "0" + s
	}
	return s
}
