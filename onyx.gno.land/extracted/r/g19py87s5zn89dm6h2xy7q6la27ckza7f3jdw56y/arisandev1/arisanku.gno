// Package arisanku is a trustless arisan (rotating savings circle, ROSCA) on
// Gno.land.
//
// An arisan is how millions of Indonesians save together: a group agrees on a
// fixed contribution (iuran), every round each member pays in, and one member
// who has not won yet takes the whole pot home. After N rounds every one of
// the N members has received the pot exactly once.
//
// Off-chain, an arisan runs on trust in the organiser (bandar) who holds the
// cash and "shakes the jar" (kocok). ArisanKu replaces the bandar with a realm:
//
//   - the realm holds each round's pot and pays the winner in the same tx
//     that decides the round, so nobody can run away with it;
//   - the winner is chosen by a public rule: Giliran (fixed turns by join
//     order) or Kocok (a draw from entropy mixed by every payment);
//   - a member who misses a payment does not stall the circle: after the
//     deadline the round is decided anyway, the missed contribution becomes a
//     public debt (utang) owed directly to that round's winner, and the
//     debtor cannot win until it is settled;
//   - every member builds a portable reputation (on-time, late, missed,
//     settled) that any circle can read before letting someone in.
//
// Lifecycle: CreateCircle -> Join ... (auto-start when full, or Start) ->
// each round: Pay by every member -> Draw -> ... -> Finished.
package arisandev1

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g19py87s5zn89dm6h2xy7q6la27ckza7f3jdw56y/arisan"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	denom = "ugnot"

	// MinContribution is the smallest iuran per member per round (0.1 GNOT).
	MinContribution int64 = 100_000
	// MaxContribution caps the iuran (1,000,000 GNOT) to keep pots sane.
	MaxContribution int64 = 1_000_000_000_000
	// MinMembers and MaxMembers bound the size of a circle.
	MinMembers = 2
	MaxMembers = 12
	// MinPeriodMinutes / MaxPeriodMinutes bound the length of a round.
	MinPeriodMinutes = 1
	MaxPeriodMinutes = 31 * 24 * 60

	maxNameLen = 40
	maxNickLen = 16
)

// Status of a circle.
type Status int

const (
	StatusOpen      Status = iota // recruiting members
	StatusRunning                 // rounds in progress
	StatusFinished                // every member received the pot once
	StatusCancelled               // cancelled by the creator before start
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusRunning:
		return "running"
	case StatusFinished:
		return "finished"
	case StatusCancelled:
		return "cancelled"
	}
	return "unknown"
}

// Member is one seat in a circle.
type Member struct {
	Addr      address
	Nick      string
	JoinedAt  time.Time
	WonRound  int  // 0 = not won yet
	Paid      bool // paid in the current round
	OpenDebts int  // unsettled debts in this circle
}

// RoundResult is the public record of one decided round.
type RoundResult struct {
	Round    int
	Winner   address // empty when the round was rolled over
	Pot      int64
	Payers   int
	Missed   []address
	Refunded bool // nobody was eligible: payers were refunded, round repeats
	At       time.Time
	Height   int64
}

// Circle is one arisan group.
type Circle struct {
	ID           int
	Name         string
	Creator      address
	Contribution int64 // ugnot per member per round
	Size         int   // target number of members (= number of rounds)
	Period       time.Duration
	Mode         arisan.Mode
	Status       Status
	Members      []*Member
	CreatedAt    time.Time
	Round        int // current round, 1-based, 0 before start
	Deadline     time.Time
	Held         int64 // ugnot paid in for the current round, held by the realm
	Entropy      []byte
	History      []RoundResult
}

// Debt is a missed contribution, owed by Debtor directly to Creditor (the
// winner of the round that was missed).
type Debt struct {
	ID        int
	CircleID  int
	Round     int
	Debtor    address
	Creditor  address
	Amount    int64
	Settled   bool
	SettledBy address
	SettledAt time.Time
}

// Reputation is a member's track record across every circle.
type Reputation struct {
	Circles     int   // circles joined
	OnTime      int   // payments before the deadline
	Late        int   // payments after the deadline (before the draw)
	Missed      int   // rounds decided without their payment
	Settled     int   // debts settled
	Wins        int   // pots received
	Contributed int64 // ugnot paid into pots and debts
	Received    int64 // ugnot received from pots and debts
}

var (
	circles      avl.Tree // padID -> *Circle
	debts        avl.Tree // padID -> *Debt
	reps         avl.Tree // address string -> *Reputation
	memberships  avl.Tree // address string -> []int (circle ids)
	nextCircleID int
	nextDebtID   int
	totalPaidOut int64
	totalRounds  int
)

// ---------------------------------------------------------------------------
// Crossing (transaction) functions

// CreateCircle starts a new arisan and seats the caller as its first member.
//
//   - name: circle name (letters, digits, spaces and - _ . , ' & ! only)
//   - nickname: how you appear on the wheel (optional, same charset)
//   - contribution: iuran per member per round in GNOT, e.g. "1" or "0.5"
//   - members: circle size, 2..12 (also the number of rounds)
//   - periodMinutes: length of each round (1 minute .. 31 days)
//   - mode: "giliran" (fixed turns) or "kocok" (random draw)
//
// It returns the new circle id.
func CreateCircle(cur realm, name, nickname, contribution string, members, periodMinutes int, mode string) int {
	caller := callerOf(cur)

	name = strings.TrimSpace(name)
	mustValidText("name", name, 1, maxNameLen)
	nickname = strings.TrimSpace(nickname)
	mustValidText("nickname", nickname, 0, maxNickLen)
	amount, err := parseGNOT(contribution)
	if err != "" {
		panic("invalid contribution: " + err)
	}
	if amount < MinContribution || amount > MaxContribution {
		panic("contribution must be between " + arisan.FormatGNOT(MinContribution) + " and " + arisan.FormatGNOT(MaxContribution))
	}
	if members < MinMembers || members > MaxMembers {
		panic(ufmt.Sprintf("members must be between %d and %d", MinMembers, MaxMembers))
	}
	if periodMinutes < MinPeriodMinutes || periodMinutes > MaxPeriodMinutes {
		panic(ufmt.Sprintf("periodMinutes must be between %d and %d", MinPeriodMinutes, MaxPeriodMinutes))
	}
	m, ok := arisan.ParseMode(mode)
	if !ok {
		panic(`mode must be "giliran" or "kocok"`)
	}

	nextCircleID++
	now := time.Now()
	c := &Circle{
		ID:           nextCircleID,
		Name:         name,
		Creator:      caller,
		Contribution: amount,
		Size:         members,
		Period:       time.Duration(periodMinutes) * time.Minute,
		Mode:         m,
		Status:       StatusOpen,
		CreatedAt:    now,
	}
	c.Entropy = arisan.MixEntropy(nil, "arisanku", strconv.Itoa(c.ID), caller.String(), strconv.FormatInt(runtime.ChainHeight(), 10))
	circles.Set(padID(c.ID), c)
	c.addMember(caller, nickname, now)

	chain.Emit("CircleCreated", "id", strconv.Itoa(c.ID), "creator", caller.String(), "contribution", strconv.FormatInt(amount, 10), "members", strconv.Itoa(members), "mode", m.String())
	return c.ID
}

// Join takes a seat in an open circle. The circle starts automatically when
// the last seat is taken.
func Join(cur realm, circleID int, nickname string) {
	caller := callerOf(cur)
	c := mustCircle(circleID)
	if c.Status != StatusOpen {
		panic("circle is not open for new members")
	}
	if c.memberIndex(caller) >= 0 {
		panic("you are already a member of this circle")
	}
	if len(c.Members) >= c.Size {
		panic("circle is full")
	}
	nickname = strings.TrimSpace(nickname)
	mustValidText("nickname", nickname, 0, maxNickLen)

	now := time.Now()
	c.addMember(caller, nickname, now)
	c.Entropy = arisan.MixEntropy(c.Entropy, "join", caller.String(), strconv.FormatInt(runtime.ChainHeight(), 10))
	chain.Emit("Joined", "id", strconv.Itoa(c.ID), "member", caller.String())
	if len(c.Members) == c.Size {
		c.start(now)
	}
}

// Leave gives up a seat in a circle that has not started. The creator cannot
// leave; use Cancel instead.
func Leave(cur realm, circleID int) {
	caller := callerOf(cur)
	c := mustCircle(circleID)
	if c.Status != StatusOpen {
		panic("can only leave a circle before it starts")
	}
	if caller == c.Creator {
		panic("the creator cannot leave; cancel the circle instead")
	}
	i := c.memberIndex(caller)
	if i < 0 {
		panic("you are not a member of this circle")
	}
	c.Members = append(c.Members[:i], c.Members[i+1:]...)
	removeMembership(caller, c.ID)
	rep := repOf(caller)
	rep.Circles--
	chain.Emit("Left", "id", strconv.Itoa(c.ID), "member", caller.String())
}

// Start begins a circle early with the members it has (at least 2). Only the
// creator can start it. The circle size shrinks to the current member count.
func Start(cur realm, circleID int) {
	caller := callerOf(cur)
	c := mustCircle(circleID)
	if c.Status != StatusOpen {
		panic("circle is not open")
	}
	if caller != c.Creator {
		panic("only the creator can start the circle")
	}
	if len(c.Members) < MinMembers {
		panic(ufmt.Sprintf("need at least %d members to start", MinMembers))
	}
	c.Size = len(c.Members)
	c.start(time.Now())
}

// Cancel closes an open circle before it starts. No funds are held before
// the start, so nothing needs refunding. Only the creator can cancel.
func Cancel(cur realm, circleID int) {
	caller := callerOf(cur)
	c := mustCircle(circleID)
	if c.Status != StatusOpen {
		panic("only an open circle can be cancelled")
	}
	if caller != c.Creator {
		panic("only the creator can cancel the circle")
	}
	c.Status = StatusCancelled
	chain.Emit("Cancelled", "id", strconv.Itoa(c.ID))
}

// Pay deposits your contribution for the current round. Attach exactly the
// circle's iuran, e.g. `-send 1000000ugnot` for 1 GNOT.
//
// It must be called directly by a user (gnokey maketx call / a wallet): coins
// sent through an intermediate realm or a `maketx run` script are rejected,
// because only then is OriginSend guaranteed to have reached this realm.
func Pay(cur realm, circleID int) {
	// The two guards below are a pair (see docs: effective-gno, "Verifying
	// inbound Coin payments"): IsUserCall guarantees the -send coins landed
	// on this realm, and the amount check verifies how much.
	if !cur.Previous().IsUserCall() {
		panic("Pay must be called directly by a user (maketx call)")
	}
	caller := callerOf(cur)
	c := mustCircle(circleID)
	if c.Status != StatusRunning {
		panic("circle is not running")
	}
	i := c.memberIndex(caller)
	if i < 0 {
		panic("you are not a member of this circle")
	}
	m := c.Members[i]
	if m.Paid {
		panic("you already paid this round")
	}
	mustReceiveExactly(c.Contribution)

	now := time.Now()
	m.Paid = true
	c.Held += c.Contribution
	c.Entropy = arisan.MixEntropy(c.Entropy, "pay", caller.String(), strconv.FormatInt(runtime.ChainHeight(), 10), strconv.FormatInt(now.UnixNano(), 10))
	rep := repOf(caller)
	rep.Contributed += c.Contribution
	late := now.After(c.Deadline)
	if late {
		rep.Late++
	} else {
		rep.OnTime++
	}
	chain.Emit("Paid", "id", strconv.Itoa(c.ID), "round", strconv.Itoa(c.Round), "member", caller.String(), "late", strconv.FormatBool(late))
}

// Draw decides the current round and pays the pot to its winner. Anyone can
// call it once every member has paid, or once the round deadline has passed.
//
// Eligible winners are members who paid this round, have not won before and
// have no unsettled debt in this circle. Members who did not pay get a debt
// owed to the winner. If nobody is eligible, every payer is refunded and the
// round is repeated with a new deadline. It returns the winner's address
// (empty if the round was rolled over).
func Draw(cur realm, circleID int) address {
	callerOf(cur)
	c := mustCircle(circleID)
	if c.Status != StatusRunning {
		panic("circle is not running")
	}
	now := time.Now()
	if !c.allPaid() && !now.After(c.Deadline) {
		panic("round is still open: wait until everyone paid or the deadline passed")
	}

	height := runtime.ChainHeight()
	seed := arisan.MixEntropy(c.Entropy, "draw", strconv.Itoa(c.Round), strconv.FormatInt(height, 10), strconv.FormatInt(now.UnixNano(), 10))
	c.Entropy = seed

	var candidates []int
	var payers []int
	var missed []address
	for i, m := range c.Members {
		if m.Paid {
			payers = append(payers, i)
			if m.WonRound == 0 && m.OpenDebts == 0 {
				candidates = append(candidates, i)
			}
		} else {
			missed = append(missed, m.Addr)
		}
	}

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	self := cur.Address()

	if len(candidates) == 0 {
		// Nobody can take the pot: give everyone their money back and repeat.
		for _, i := range payers {
			bk.SendCoins(self, c.Members[i].Addr, coins(c.Contribution))
			repOf(c.Members[i].Addr).Contributed -= c.Contribution
		}
		for _, a := range missed {
			repOf(a).Missed++
		}
		c.History = append(c.History, RoundResult{Round: c.Round, Pot: c.Held, Payers: len(payers), Missed: missed, Refunded: true, At: now, Height: height})
		c.resetRound(now)
		chain.Emit("RoundRolledOver", "id", strconv.Itoa(c.ID), "round", strconv.Itoa(c.Round))
		return ""
	}

	wi := arisan.PickWinner(c.Mode, candidates, seed)
	winner := c.Members[wi]
	pot := c.Held
	winner.WonRound = c.Round
	bk.SendCoins(self, winner.Addr, coins(pot))
	wrep := repOf(winner.Addr)
	wrep.Wins++
	wrep.Received += pot
	totalPaidOut += pot
	totalRounds++

	for _, a := range missed {
		nextDebtID++
		d := &Debt{ID: nextDebtID, CircleID: c.ID, Round: c.Round, Debtor: a, Creditor: winner.Addr, Amount: c.Contribution}
		debts.Set(padID(d.ID), d)
		c.Members[c.memberIndex(a)].OpenDebts++
		repOf(a).Missed++
		chain.Emit("DebtRecorded", "debt", strconv.Itoa(d.ID), "id", strconv.Itoa(c.ID), "debtor", a.String(), "creditor", winner.Addr.String())
	}

	c.History = append(c.History, RoundResult{Round: c.Round, Winner: winner.Addr, Pot: pot, Payers: len(payers), Missed: missed, At: now, Height: height})
	chain.Emit("Drawn", "id", strconv.Itoa(c.ID), "round", strconv.Itoa(c.Round), "winner", winner.Addr.String(), "pot", strconv.FormatInt(pot, 10))

	if c.winners() == len(c.Members) {
		c.Status = StatusFinished
		c.Held = 0
		for _, m := range c.Members {
			m.Paid = false
		}
		chain.Emit("Finished", "id", strconv.Itoa(c.ID))
		return winner.Addr
	}
	c.Round++
	c.resetRound(now)
	return winner.Addr
}

// PayDebt settles a debt. Attach exactly the debt amount; it is forwarded to
// the creditor in the same transaction. Anyone may settle a debt on the
// debtor's behalf (family often does), the debtor gets the credit.
func PayDebt(cur realm, debtID int) {
	// Paired payment guards, see Pay.
	if !cur.Previous().IsUserCall() {
		panic("PayDebt must be called directly by a user (maketx call)")
	}
	caller := callerOf(cur)
	v := debts.Get(padID(debtID))
	if v == nil {
		panic("debt not found")
	}
	d := v.(*Debt)
	if d.Settled {
		panic("debt already settled")
	}
	mustReceiveExactly(d.Amount)

	d.Settled = true
	d.SettledBy = caller
	d.SettledAt = time.Now()
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), d.Creditor, coins(d.Amount))

	if c := getCircle(d.CircleID); c != nil {
		if i := c.memberIndex(d.Debtor); i >= 0 && c.Members[i].OpenDebts > 0 {
			c.Members[i].OpenDebts--
		}
	}
	drep := repOf(d.Debtor)
	drep.Settled++
	repOf(caller).Contributed += d.Amount
	repOf(d.Creditor).Received += d.Amount
	chain.Emit("DebtSettled", "debt", strconv.Itoa(d.ID), "by", caller.String())
}

// ---------------------------------------------------------------------------
// Read-only helpers (safe to call with vm/qeval; return copies only)

// CircleCount returns how many circles were ever created.
func CircleCount() int { return nextCircleID }

// TotalPaidOut returns the ugnot paid to winners across all circles.
func TotalPaidOut() int64 { return totalPaidOut }

// TrustScore returns a 0..100 score for an address from its track record.
// New members start at 50.
func TrustScore(addr address) int {
	v := reps.Get(addr.String())
	if v == nil {
		return 50
	}
	return scoreOf(v.(*Reputation))
}

// CircleJSON returns a JSON summary of a circle for wallets, bots and
// frontends. It returns "null" if the circle does not exist.
func CircleJSON(circleID int) string {
	c := getCircle(circleID)
	if c == nil {
		return "null"
	}
	var b strings.Builder
	b.WriteString("{")
	b.WriteString(`"id":` + strconv.Itoa(c.ID))
	b.WriteString(`,"name":` + strconv.Quote(c.Name))
	b.WriteString(`,"status":` + strconv.Quote(c.Status.String()))
	b.WriteString(`,"mode":` + strconv.Quote(c.Mode.String()))
	b.WriteString(`,"creator":` + strconv.Quote(c.Creator.String()))
	b.WriteString(`,"contribution_ugnot":` + strconv.FormatInt(c.Contribution, 10))
	b.WriteString(`,"size":` + strconv.Itoa(c.Size))
	b.WriteString(`,"round":` + strconv.Itoa(c.Round))
	b.WriteString(`,"held_ugnot":` + strconv.FormatInt(c.Held, 10))
	b.WriteString(`,"period_seconds":` + strconv.FormatInt(int64(c.Period/time.Second), 10))
	if c.Status == StatusRunning {
		b.WriteString(`,"deadline_unix":` + strconv.FormatInt(c.Deadline.Unix(), 10))
	}
	b.WriteString(`,"members":[`)
	for i, m := range c.Members {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"address":` + strconv.Quote(m.Addr.String()) + `,"nick":` + strconv.Quote(m.Nick) + `,"paid":` + strconv.FormatBool(m.Paid) + `,"won_round":` + strconv.Itoa(m.WonRound) + `,"open_debts":` + strconv.Itoa(m.OpenDebts) + `}`)
	}
	b.WriteString("]}")
	return b.String()
}

// ---------------------------------------------------------------------------
// internals

func callerOf(cur realm) address {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	return cur.Previous().Address()
}

// mustReceiveExactly checks the coins attached to the transaction. Callers
// MUST have asserted cur.Previous().IsUserCall() first.
func mustReceiveExactly(amount int64) {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent.AmountOf(denom) != amount {
		panic("attach exactly " + strconv.FormatInt(amount, 10) + denom + " (" + arisan.FormatGNOT(amount) + "), got " + sent.String())
	}
}

func coins(amount int64) chain.Coins {
	return chain.Coins{chain.NewCoin(denom, amount)}
}

func padID(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func getCircle(id int) *Circle {
	v := circles.Get(padID(id))
	if v == nil {
		return nil
	}
	return v.(*Circle)
}

func mustCircle(id int) *Circle {
	c := getCircle(id)
	if c == nil {
		panic("circle " + strconv.Itoa(id) + " not found")
	}
	return c
}

func repOf(a address) *Reputation {
	v := reps.Get(a.String())
	if v != nil {
		return v.(*Reputation)
	}
	r := &Reputation{}
	reps.Set(a.String(), r)
	return r
}

func scoreOf(r *Reputation) int {
	s := 50 + 5*r.OnTime + 2*r.Late + 4*r.Settled - 15*r.Missed
	if s < 0 {
		s = 0
	}
	if s > 100 {
		s = 100
	}
	return s
}

func addMembership(a address, id int) {
	var ids []int
	if v := memberships.Get(a.String()); v != nil {
		ids = v.([]int)
	}
	ids = append(ids, id)
	memberships.Set(a.String(), ids)
}

func removeMembership(a address, id int) {
	v := memberships.Get(a.String())
	if v == nil {
		return
	}
	ids := v.([]int)
	out := make([]int, 0, len(ids))
	for _, x := range ids {
		if x != id {
			out = append(out, x)
		}
	}
	memberships.Set(a.String(), out)
}

func (c *Circle) addMember(a address, nick string, now time.Time) {
	c.Members = append(c.Members, &Member{Addr: a, Nick: nick, JoinedAt: now})
	addMembership(a, c.ID)
	repOf(a).Circles++
}

func (c *Circle) memberIndex(a address) int {
	for i, m := range c.Members {
		if m.Addr == a {
			return i
		}
	}
	return -1
}

func (c *Circle) start(now time.Time) {
	c.Status = StatusRunning
	c.Round = 1
	c.Deadline = now.Add(c.Period)
	chain.Emit("Started", "id", strconv.Itoa(c.ID), "members", strconv.Itoa(len(c.Members)))
}

func (c *Circle) resetRound(now time.Time) {
	for _, m := range c.Members {
		m.Paid = false
	}
	c.Held = 0
	c.Deadline = now.Add(c.Period)
}

func (c *Circle) allPaid() bool {
	for _, m := range c.Members {
		if !m.Paid {
			return false
		}
	}
	return len(c.Members) > 0
}

func (c *Circle) paidCount() int {
	n := 0
	for _, m := range c.Members {
		if m.Paid {
			n++
		}
	}
	return n
}

func (c *Circle) winners() int {
	n := 0
	for _, m := range c.Members {
		if m.WonRound > 0 {
			n++
		}
	}
	return n
}

// mustValidText keeps user text safe to embed in markdown and SVG: a short
// whitelist instead of escaping every renderer's syntax.
func mustValidText(field, s string, min, max int) {
	n := len([]rune(s))
	if n < min || n > max {
		panic(ufmt.Sprintf("%s must be %d to %d characters", field, min, max))
	}
	for _, r := range s {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') ||
			r == ' ' || r == '-' || r == '_' || r == '.' || r == ',' || r == '\'' || r == '&' || r == '!'
		if !ok {
			panic(field + " may only use letters, digits, spaces and - _ . , ' & !")
		}
	}
}

// parseGNOT parses a decimal GNOT amount ("1", "0.5", "2.000001") into ugnot.
// It returns a non-empty error string on failure.
func parseGNOT(s string) (int64, string) {
	s = strings.TrimSpace(s)
	s = strings.TrimSuffix(strings.TrimSuffix(s, "GNOT"), "gnot")
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, "empty amount"
	}
	whole, frac := s, ""
	if i := strings.IndexByte(s, '.'); i >= 0 {
		whole, frac = s[:i], s[i+1:]
	}
	if whole == "" {
		whole = "0"
	}
	if len(frac) > 6 {
		return 0, "at most 6 decimals"
	}
	for _, r := range whole + frac {
		if r < '0' || r > '9' {
			return 0, "not a number"
		}
	}
	if len(whole) > 9 {
		return 0, "too large"
	}
	for len(frac) < 6 {
		frac += "0"
	}
	w, _ := strconv.ParseInt(whole, 10, 64)
	f, _ := strconv.ParseInt(frac, 10, 64)
	return w*1_000_000 + f, ""
}
