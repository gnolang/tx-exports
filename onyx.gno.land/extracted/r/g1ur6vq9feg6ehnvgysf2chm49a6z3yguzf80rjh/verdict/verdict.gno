// Package verdict is an on-chain prediction market for Gno.land, paid in GNOT.
//
// Two kinds of markets:
//
//   - GovDAO markets: "Will GovDAO proposal #N pass?". Anyone can open one for
//     an active proposal. They settle trustlessly: Settle() reads the proposal
//     status straight from gno.land/r/gov/dao, so no oracle and no admin are
//     involved. Betting closes automatically once voting ends.
//
//   - Community markets: any yes/no question with a close time. The creator
//     resolves it after the close time, and may not bet on their own market.
//     If the creator does not resolve in time, anyone can void the market and
//     every bettor is refunded in full.
//
// Betting is pari-mutuel (see gno.land/p/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/parimutuel): winners split
// the losing side pro rata. A small fee (default 1%) is taken only when a
// market has both winners and losers.
package verdict

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	pm "gno.land/p/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/parimutuel"
)

const (
	denom = "ugnot"

	// MinBet is 0.1 GNOT.
	MinBet int64 = 100_000

	maxQuestionLen = 200
	minCloseHours  = 1
	maxCloseHours  = 24 * 90 // 90 days
	resolveWindow  = 7 * 24 * time.Hour
	govResolveBy   = 60 * 24 * time.Hour
)

// Kind of market.
type Kind int

const (
	KindCommunity Kind = iota
	KindGovDAO
)

// Market is one yes/no question with its betting pool.
type Market struct {
	ID         int
	Kind       Kind
	Question   string
	Creator    address
	ProposalID int64 // only for KindGovDAO
	CreatedAt  time.Time
	CloseAt    time.Time // community markets: betting closes here
	ResolveBy  time.Time // after this, an unresolved market can be voided
	ResolvedAt time.Time
	Note       string // how it was resolved
	Pool       *pm.Pool
}

// Stats tracks a bettor's lifetime record for the leaderboard.
type Stats struct {
	Wagered  int64
	Returned int64
	Bets     int
	Wins     int
}

// Profit returns returned minus wagered on settled positions.
func (s *Stats) Profit() int64 { return s.Returned - s.Wagered }

var (
	markets    avl.Tree // zero-padded id -> *Market
	govMarkets avl.Tree // proposal id -> market id
	stats      avl.Tree // address -> *Stats
	nextID     = 1

	admin        address
	feeRecipient address
	feeBps       int64 = 100 // 1%

	totalVolume int64
)

func init(cur realm) {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
}

// ---------------------------------------------------------------------------
// Market creation

// CreateMarket opens a community market. closeInHours sets when betting
// closes; the creator then has 7 days to resolve it.
func CreateMarket(cur realm, question string, closeInHours int) int {
	assertUser(cur)
	caller := cur.Previous().Address()

	question = strings.TrimSpace(question)
	if question == "" {
		panic("question is required")
	}
	if len(question) > maxQuestionLen {
		panic(ufmt.Sprintf("question too long (max %d chars)", maxQuestionLen))
	}
	if closeInHours < minCloseHours || closeInHours > maxCloseHours {
		panic(ufmt.Sprintf("closeInHours must be between %d and %d", minCloseHours, maxCloseHours))
	}

	now := time.Now()
	closeAt := now.Add(time.Duration(closeInHours) * time.Hour)
	m := &Market{
		ID:        nextID,
		Kind:      KindCommunity,
		Question:  question,
		Creator:   caller,
		CreatedAt: now,
		CloseAt:   closeAt,
		ResolveBy: closeAt.Add(resolveWindow),
		Pool:      pm.New(feeBps),
	}
	saveNew(m)
	chain.Emit("MarketCreated", "id", strconv.Itoa(m.ID), "kind", "community", "creator", caller.String())
	return m.ID
}

// CreateGovDAOMarket opens "Will GovDAO proposal #pid pass?". The proposal
// must currently be open for votes, and there can only be one market per
// proposal.
func CreateGovDAOMarket(cur realm, pid int64) int {
	assertUser(cur)
	caller := cur.Previous().Address()

	key := strconv.FormatInt(pid, 10)
	if govMarkets.Has(key) {
		panic("a market for this proposal already exists: " + mustGetGovMarketID(key))
	}
	status := govStatus(0, cur, pid)
	if status != statusActive {
		panic("proposal #" + key + " is not open for votes (status: " + status + ")")
	}

	title := govTitle(pid)
	q := "Will GovDAO proposal #" + key + " pass?"
	if title != "" {
		q = "Will GovDAO proposal #" + key + " (" + clamp(title, 120) + ") pass?"
	}

	now := time.Now()
	m := &Market{
		ID:         nextID,
		Kind:       KindGovDAO,
		Question:   q,
		Creator:    caller,
		ProposalID: pid,
		CreatedAt:  now,
		ResolveBy:  now.Add(govResolveBy),
		Pool:       pm.New(feeBps),
	}
	saveNew(m)
	govMarkets.Set(key, m.ID)
	chain.Emit("MarketCreated", "id", strconv.Itoa(m.ID), "kind", "govdao", "proposal", key, "creator", caller.String())
	return m.ID
}

// ---------------------------------------------------------------------------
// Betting

// Bet stakes the attached GNOT (-send) on side "yes" or "no".
func Bet(cur realm, id int, side string) {
	assertUser(cur)
	caller := cur.Previous().Address()
	m := mustGet(id)

	s, err := pm.ParseSide(side)
	if err != nil {
		panic(err.Error())
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf(denom)
	if len(sent) != 1 || amount <= 0 {
		panic("attach GNOT only, e.g. -send 1000000ugnot")
	}
	if amount < MinBet {
		panic(ufmt.Sprintf("minimum bet is %s GNOT", fmtGNOT(MinBet)))
	}

	switch m.Kind {
	case KindCommunity:
		if caller == m.Creator {
			panic("the resolver of a community market cannot bet on it")
		}
		if !time.Now().Before(m.CloseAt) {
			panic("betting is closed for this market")
		}
	case KindGovDAO:
		if st := govStatus(0, cur, m.ProposalID); st != statusActive {
			panic("voting has ended for this proposal (status: " + st + "), betting is closed")
		}
	}

	if err := m.Pool.Place(caller, s, amount); err != nil {
		panic(err.Error())
	}

	st := getStats(caller)
	st.Wagered += amount
	st.Bets++
	totalVolume += amount

	chain.Emit("BetPlaced",
		"id", strconv.Itoa(id),
		"side", s.String(),
		"amount", strconv.FormatInt(amount, 10),
		"bettor", caller.String(),
	)
}

// ---------------------------------------------------------------------------
// Resolution

// Settle resolves a GovDAO market from the live proposal status. Anyone can
// call it once the proposal is accepted or denied.
func Settle(cur realm, id int) {
	assertUser(cur)
	m := mustGet(id)
	if m.Kind != KindGovDAO {
		panic("only GovDAO markets settle automatically; the creator resolves community markets")
	}
	assertPending(m)

	st := govStatus(0, cur, m.ProposalID)
	var o pm.Outcome
	switch st {
	case statusAccepted:
		o = pm.Yes
	case statusDenied:
		o = pm.No
	default:
		panic("proposal is still " + st + ", cannot settle yet")
	}
	finalize(cur, m, o, "settled from GovDAO: proposal "+strings.ToLower(st))
}

// Resolve lets the creator of a community market set the outcome
// ("yes", "no" or "void") after betting has closed.
func Resolve(cur realm, id int, outcome string) {
	assertUser(cur)
	caller := cur.Previous().Address()
	m := mustGet(id)
	if m.Kind != KindCommunity {
		panic("GovDAO markets settle from on-chain data: call Settle")
	}
	assertPending(m)
	if caller != m.Creator {
		panic("only the market creator can resolve it")
	}
	now := time.Now()
	if now.Before(m.CloseAt) {
		panic("betting has not closed yet")
	}
	if !now.Before(m.ResolveBy) {
		panic("resolution window has passed; anyone can call VoidExpired")
	}

	var o pm.Outcome
	switch strings.ToLower(strings.TrimSpace(outcome)) {
	case "yes":
		o = pm.Yes
	case "no":
		o = pm.No
	case "void":
		o = pm.Void
	default:
		panic("outcome must be yes, no or void")
	}
	finalize(cur, m, o, "resolved by creator")
}

// VoidExpired refunds everyone when a market was not resolved in time.
func VoidExpired(cur realm, id int) {
	assertUser(cur)
	m := mustGet(id)
	assertPending(m)
	if time.Now().Before(m.ResolveBy) {
		panic("market can still be resolved; void is possible after " + fmtTime(m.ResolveBy))
	}
	finalize(cur, m, pm.Void, "voided: not resolved in time")
}

// AdminVoid lets the admin void an unresolved community market (spam,
// ambiguous or abusive questions). Everyone is refunded in full.
// GovDAO markets cannot be touched by the admin.
func AdminVoid(cur realm, id int, reason string) {
	assertUser(cur)
	assertAdmin(cur)
	m := mustGet(id)
	if m.Kind != KindCommunity {
		panic("GovDAO markets cannot be voided by the admin")
	}
	assertPending(m)
	finalize(cur, m, pm.Void, "voided by admin: "+clamp(reason, 140))
}

func finalize(cur realm, m *Market, o pm.Outcome, note string) {
	final, err := m.Pool.Resolve(o)
	if err != nil {
		panic(err.Error())
	}
	m.ResolvedAt = time.Now()
	m.Note = note
	if final == pm.Void && o != pm.Void {
		m.Note = note + " (winning side was empty, so everyone is refunded)"
	}
	if fee := m.Pool.Fee(); fee > 0 && feeRecipient != "" {
		send(cur, feeRecipient, fee)
	}
	chain.Emit("MarketResolved", "id", strconv.Itoa(m.ID), "outcome", final.String())
}

// ---------------------------------------------------------------------------
// Claiming

// Claim pays out the caller's winnings (or refund) for a resolved market.
func Claim(cur realm, id int) int64 {
	assertUser(cur)
	caller := cur.Previous().Address()
	m := mustGet(id)

	pos := m.Pool.Position(caller)
	amount, err := m.Pool.Claim(caller)
	if err != nil {
		panic(err.Error())
	}
	send(cur, caller, amount)

	st := getStats(caller)
	st.Returned += amount
	if m.Pool.Outcome() != pm.Void && amount > pos.Total() {
		st.Wins++
	}
	if m.Pool.Outcome() == pm.Void {
		// A refund is not a bet: take it out of the record entirely.
		st.Wagered -= pos.Total()
		st.Returned -= amount
	}

	chain.Emit("Claimed", "id", strconv.Itoa(id), "amount", strconv.FormatInt(amount, 10), "bettor", caller.String())
	return amount
}

// ---------------------------------------------------------------------------
// Admin

// SetFee sets the fee for markets created from now on (max 3%).
func SetFee(cur realm, bps int64) {
	assertUser(cur)
	assertAdmin(cur)
	if bps < 0 || bps > 300 {
		panic("fee must be between 0 and 300 bps")
	}
	feeBps = bps
}

// SetFeeRecipient changes where fees are sent.
func SetFeeRecipient(cur realm, addr address) {
	assertUser(cur)
	assertAdmin(cur)
	if !addr.IsValid() {
		panic("invalid address")
	}
	feeRecipient = addr
}

// TransferAdmin hands admin rights to a new address.
func TransferAdmin(cur realm, addr address) {
	assertUser(cur)
	assertAdmin(cur)
	if !addr.IsValid() {
		panic("invalid address")
	}
	admin = addr
}

// ---------------------------------------------------------------------------
// Read-only getters (handy for other realms, bots and frontends)

// MarketCount returns how many markets exist.
func MarketCount() int { return nextID - 1 }

// GetOdds returns the YES share in basis points and the pool sizes.
func GetOdds(id int) (yesBps, yesStake, noStake int64) {
	m := mustGet(id)
	return m.Pool.YesBps(), m.Pool.YesStake(), m.Pool.NoStake()
}

// GetOutcome returns "pending", "yes", "no" or "void".
func GetOutcome(id int) string { return mustGet(id).Pool.Outcome().String() }

// PendingPayout returns what addr could claim right now on market id.
func PendingPayout(id int, addr address) int64 { return mustGet(id).Pool.Payout(addr) }

// MarketForProposal returns the market id for a GovDAO proposal, or 0.
func MarketForProposal(pid int64) int {
	v := govMarkets.Get(strconv.FormatInt(pid, 10))
	if v == nil {
		return 0
	}
	return v.(int)
}

// ---------------------------------------------------------------------------
// helpers

func assertUser(cur realm) {
	// OriginSend only describes a real payment to this realm when the caller
	// is the origin EOA itself (see r/demo/defi/atomicswap for the reasoning).
	if !cur.Previous().IsUserCall() {
		panic("call this function directly (gnokey maketx call / wallet)")
	}
}

func assertAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
}

func assertPending(m *Market) {
	if m.Pool.Outcome() != pm.Pending {
		panic("market is already resolved (" + m.Pool.Outcome().String() + ")")
	}
}

func send(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{{denom, amount}})
}

func saveNew(m *Market) {
	markets.Set(idKey(m.ID), m)
	nextID++
}

func mustGet(id int) *Market {
	v := markets.Get(idKey(id))
	if v == nil {
		panic("market not found: " + strconv.Itoa(id))
	}
	return v.(*Market)
}

func mustGetGovMarketID(key string) string {
	return strconv.Itoa(govMarkets.Get(key).(int))
}

func getStats(addr address) *Stats {
	v := stats.Get(addr.String())
	if v != nil {
		return v.(*Stats)
	}
	s := &Stats{}
	stats.Set(addr.String(), s)
	return s
}

// idKey zero-pads ids so the avl tree iterates in creation order.
func idKey(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func clamp(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
