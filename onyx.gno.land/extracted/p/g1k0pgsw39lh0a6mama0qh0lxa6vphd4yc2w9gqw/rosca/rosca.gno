// Package rosca implements the rules of a rotating savings circle (ROSCA):
// a fixed group of members pays the same contribution every round, and each
// round the whole pot goes to one member, in turn, until everyone has
// received it once. In Turkey this is the "altın günü"; elsewhere it is a
// tanda, susu, chit fund, hui or tontine.
//
// The package holds no coins. It is a pure state machine: callers pass in
// who acted, how much they sent and the current time, and the circle updates
// its books. The realm that embeds it moves the actual coins and must keep
// the coins it holds equal to Circle.Held().
//
// Guarantees, stated precisely:
//
//   - Collateral. Every member locks CollateralRounds contributions when they
//     join. A missed payment is covered from the member's own collateral, so
//     the pot is always whole while collateral lasts.
//   - With CollateralRounds = members-1 no member can ever run out of
//     collateral, so every member is guaranteed the full pot ("fully
//     secured"). With less collateral a member who keeps missing payments
//     can break the circle. The circle then winds down: honest members get
//     their collateral and this round's payment back, and anything the
//     defaulters have not withdrawn yet (usually the pot they received) is
//     used to repay members who paid in more than they received. What a
//     defaulter already withdrew cannot be recovered; the circle says so
//     instead of pretending otherwise.
//   - Nothing is ever paid out without a claim: pots, refunds and collateral
//     are credited to Claimable and withdrawn by their owner.
package rosca

import (
	"errors"
	"math/bits"
	"strings"
)

const (
	MinMembers      = 2
	MaxMembers      = 12
	MinPeriod       = int64(60)                // 1 minute, so a demo fits in a video
	MaxPeriod       = int64(90 * 86400)        // 90 days
	MinJoinWindow   = int64(60)                // 1 minute
	MaxJoinWindow   = int64(30 * 86400)        // 30 days
	MaxContribution = int64(1_000_000_000_000) // 1M GNOT in ugnot
	MaxNameLen      = 48
)

type Status int

const (
	Forming   Status = iota // waiting for every listed member to join
	Active                  // rounds are running
	Completed               // every member received the pot once
	Broken                  // a member missed a payment with no collateral left
	Cancelled               // never started
)

func (s Status) String() string {
	switch s {
	case Forming:
		return "forming"
	case Active:
		return "active"
	case Completed:
		return "completed"
	case Broken:
		return "broken"
	case Cancelled:
		return "cancelled"
	}
	return "unknown"
}

// Mark records how a member's contribution reached a round's pot.
type Mark byte

const (
	Unpaid  Mark = '.' // nothing yet (current round only)
	OnTime  Mark = 'P' // paid before the round was due
	Late    Mark = 'L' // paid after the due time, before anyone settled
	Covered Mark = 'C' // missed; taken from the member's collateral
	Missed  Mark = 'X' // missed with no collateral left: the circle broke
)

var (
	ErrBadName         = errors.New("rosca: name must be 1-48 characters")
	ErrBadContribution = errors.New("rosca: contribution must be between 1 and 1,000,000,000,000 ugnot")
	ErrBadPeriod       = errors.New("rosca: period must be between 60 seconds and 90 days")
	ErrBadJoinWindow   = errors.New("rosca: join window must be between 60 seconds and 30 days")
	ErrBadMemberCount  = errors.New("rosca: a circle needs 2 to 12 members")
	ErrBadMember       = errors.New("rosca: invalid member address")
	ErrDuplicateMember = errors.New("rosca: a member is listed twice")
	ErrBadCollateral   = errors.New("rosca: collateral rounds must be between 0 and members-1")
	ErrOrganizerNotIn  = errors.New("rosca: the organizer must be one of the members")
	ErrOverflow        = errors.New("rosca: amounts too large")
	ErrNotMember       = errors.New("rosca: not a member of this circle")
	ErrWrongStatus     = errors.New("rosca: not possible in the circle's current status")
	ErrAlreadyJoined   = errors.New("rosca: already joined")
	ErrJoinClosed      = errors.New("rosca: the join window has closed")
	ErrWrongAmount     = errors.New("rosca: wrong amount sent")
	ErrAlreadyPaid     = errors.New("rosca: already paid this round")
	ErrNotDue          = errors.New("rosca: the round is not due yet")
	ErrNothingToSettle = errors.New("rosca: everyone has paid; nothing to settle")
	ErrCannotCancel    = errors.New("rosca: only the organizer can cancel before the join window closes")
	ErrBadSwap         = errors.New("rosca: both turns must still be ahead of the current round")
	ErrNoProposal      = errors.New("rosca: no matching swap proposal")
	ErrSelfSwap        = errors.New("rosca: cannot swap with yourself")
	ErrNothingToClaim  = errors.New("rosca: nothing to withdraw")
)

// Config is what an organizer chooses when creating a circle.
type Config struct {
	Name             string
	Contribution     int64     // ugnot each member pays per round
	Period           int64     // seconds per round
	CollateralRounds int       // contributions each member locks on joining
	JoinWindow       int64     // seconds the members have to join
	Members          []address // turn order: Members[0] receives the first pot
}

// Member is one participant's books. All amounts are ugnot.
type Member struct {
	Addr        address
	Joined      bool
	Collateral  int64 // still locked
	PaidIn      int64 // contributions that reached a pot (incl. from collateral)
	Received    int64 // pots received
	Claimable   int64 // credited, not yet withdrawn
	Withdrawn   int64
	Compensated int64 // repaid from the defaulters' pool when a circle broke
	Covered     int   // payments covered from collateral
	Late        int   // payments made after the due time
	Defaulted   bool
	SwapWith    address // pending swap proposal, "" if none
}

// Round is the record of one finished round.
type Round struct {
	Recipient address
	Pot       int64
	ClosedAt  int64
	Marks     string // one Mark per member, in member (not turn) order
}

// Circle is a savings circle. Create it with New.
type Circle struct {
	cfg       Config
	organizer address
	createdAt int64
	joinBy    int64
	status    Status
	startedAt int64
	endedAt   int64
	members   []*Member // fixed order, as listed at creation
	turns     []int     // turns[r] = index into members of round r's recipient
	round     int       // current round, 0-based; == len(members) when completed
	marks     []Mark    // current round's marks, per member
	history   []Round
	note      string // why the circle broke or was cancelled
}

// New validates cfg and creates a circle in the Forming state.
func New(cfg Config, organizer address, now int64) (*Circle, error) {
	name := strings.TrimSpace(cfg.Name)
	if len(name) == 0 || len(name) > MaxNameLen {
		return nil, ErrBadName
	}
	if cfg.Contribution < 1 || cfg.Contribution > MaxContribution {
		return nil, ErrBadContribution
	}
	if cfg.Period < MinPeriod || cfg.Period > MaxPeriod {
		return nil, ErrBadPeriod
	}
	if cfg.JoinWindow < MinJoinWindow || cfg.JoinWindow > MaxJoinWindow {
		return nil, ErrBadJoinWindow
	}
	n := len(cfg.Members)
	if n < MinMembers || n > MaxMembers {
		return nil, ErrBadMemberCount
	}
	if cfg.CollateralRounds < 0 || cfg.CollateralRounds > n-1 {
		return nil, ErrBadCollateral
	}
	// MaxContribution * MaxMembers fits easily in int64; keep the check so the
	// bound stays explicit if the constants ever change.
	if cfg.Contribution > (1<<62)/int64(n) {
		return nil, ErrOverflow
	}
	c := &Circle{
		organizer: organizer,
		createdAt: now,
		joinBy:    now + cfg.JoinWindow,
		status:    Forming,
	}
	orgIn := false
	for i, a := range cfg.Members {
		if !a.IsValid() {
			return nil, ErrBadMember
		}
		for j := 0; j < i; j++ {
			if cfg.Members[j] == a {
				return nil, ErrDuplicateMember
			}
		}
		if a == organizer {
			orgIn = true
		}
		c.members = append(c.members, &Member{Addr: a})
		c.turns = append(c.turns, i)
	}
	if !orgIn {
		return nil, ErrOrganizerNotIn
	}
	cfg.Name = name
	cfg.Members = append([]address{}, cfg.Members...)
	c.cfg = cfg
	c.marks = make([]Mark, n)
	c.resetMarks()
	return c, nil
}

// ---------------------------------------------------------------- actions

// CollateralDue is what each member sends when joining.
func (c *Circle) CollateralDue() int64 {
	return c.cfg.Contribution * int64(c.cfg.CollateralRounds)
}

// Join records that who locked their collateral. The last join starts round 1.
func (c *Circle) Join(who address, sent int64, now int64) error {
	if c.status != Forming {
		return ErrWrongStatus
	}
	if now > c.joinBy {
		return ErrJoinClosed
	}
	m := c.member(who)
	if m == nil {
		return ErrNotMember
	}
	if m.Joined {
		return ErrAlreadyJoined
	}
	if sent != c.CollateralDue() {
		return ErrWrongAmount
	}
	m.Joined = true
	m.Collateral = sent
	for _, x := range c.members {
		if !x.Joined {
			return nil
		}
	}
	c.status = Active
	c.startedAt = now
	return nil
}

// Pay records who's contribution for the current round. When the last
// member pays, the round closes and the pot is credited to the recipient.
// Paying after the due time is allowed until someone settles the round, and
// is recorded as late.
func (c *Circle) Pay(who address, sent int64, now int64) error {
	if c.status != Active {
		return ErrWrongStatus
	}
	i := c.index(who)
	if i < 0 {
		return ErrNotMember
	}
	if c.marks[i] != Unpaid {
		return ErrAlreadyPaid
	}
	if sent != c.cfg.Contribution {
		return ErrWrongAmount
	}
	m := c.members[i]
	m.PaidIn += sent
	if now > c.DueAt() {
		c.marks[i] = Late
		m.Late++
	} else {
		c.marks[i] = OnTime
	}
	if c.allPaid() {
		c.closeRound(now)
	}
	return nil
}

// Settle closes an overdue round. Anyone may call it. Each member who has
// not paid is covered from their collateral; a member without enough
// collateral breaks the circle.
func (c *Circle) Settle(now int64) error {
	if c.status != Active {
		return ErrWrongStatus
	}
	if now <= c.DueAt() {
		return ErrNotDue
	}
	if c.allPaid() {
		// Cannot happen: the last payment closes the round. Kept as a guard.
		return ErrNothingToSettle
	}
	contribution := c.cfg.Contribution
	broke := false
	for i, m := range c.members {
		if c.marks[i] != Unpaid {
			continue
		}
		if m.Collateral >= contribution {
			m.Collateral -= contribution
			m.PaidIn += contribution
			m.Covered++
			c.marks[i] = Covered
			continue
		}
		c.marks[i] = Missed
		m.Defaulted = true
		broke = true
	}
	if broke {
		c.breakCircle(now)
		return nil
	}
	c.closeRound(now)
	return nil
}

// ProposeSwap offers to trade turns with another member. Both turns must
// still be ahead (not the current round). A new proposal replaces the old one.
func (c *Circle) ProposeSwap(who, with address) error {
	if c.status != Forming && c.status != Active {
		return ErrWrongStatus
	}
	if who == with {
		return ErrSelfSwap
	}
	m, o := c.member(who), c.member(with)
	if m == nil || o == nil {
		return ErrNotMember
	}
	if !c.turnAhead(c.index(who)) || !c.turnAhead(c.index(with)) {
		return ErrBadSwap
	}
	m.SwapWith = with
	return nil
}

// AcceptSwap accepts from's pending proposal and swaps the two turns.
func (c *Circle) AcceptSwap(who, from address) error {
	if c.status != Forming && c.status != Active {
		return ErrWrongStatus
	}
	m, f := c.member(who), c.member(from)
	if m == nil || f == nil {
		return ErrNotMember
	}
	if f.SwapWith != who {
		return ErrNoProposal
	}
	a, b := c.turnOf(c.index(from)), c.turnOf(c.index(who))
	if !c.turnAhead(c.index(from)) || !c.turnAhead(c.index(who)) {
		f.SwapWith = ""
		return ErrBadSwap
	}
	c.turns[a], c.turns[b] = c.turns[b], c.turns[a]
	f.SwapWith = ""
	if m.SwapWith == from {
		m.SwapWith = ""
	}
	return nil
}

// Cancel stops a circle that has not started. The organizer can cancel any
// time before it starts; anyone can cancel once the join window has closed.
// Locked collateral becomes claimable.
func (c *Circle) Cancel(who address, now int64) error {
	if c.status != Forming {
		return ErrWrongStatus
	}
	if who != c.organizer && now <= c.joinBy {
		return ErrCannotCancel
	}
	for _, m := range c.members {
		m.Claimable += m.Collateral
		m.Collateral = 0
	}
	c.status = Cancelled
	c.endedAt = now
	if now > c.joinBy {
		c.note = "not every member joined in time"
	} else {
		c.note = "cancelled by the organizer"
	}
	return nil
}

// Withdraw zeroes who's claimable balance and returns the amount the caller
// must send them.
func (c *Circle) Withdraw(who address) (int64, error) {
	m := c.member(who)
	if m == nil {
		return 0, ErrNotMember
	}
	amt := m.Claimable
	if amt <= 0 {
		return 0, ErrNothingToClaim
	}
	m.Claimable = 0
	m.Withdrawn += amt
	return amt, nil
}

// ---------------------------------------------------------------- internals

func (c *Circle) closeRound(now int64) {
	pot := c.cfg.Contribution * int64(len(c.members))
	r := c.members[c.turns[c.round]]
	r.Received += pot
	r.Claimable += pot
	c.history = append(c.history, Round{
		Recipient: r.Addr,
		Pot:       pot,
		ClosedAt:  now,
		Marks:     string(c.marks),
	})
	c.round++
	c.resetMarks()
	// Proposals that involve a turn that is no longer ahead are stale.
	for i, m := range c.members {
		if m.SwapWith != "" && (!c.turnAhead(i) || !c.turnAhead(c.index(m.SwapWith))) {
			m.SwapWith = ""
		}
	}
	if c.round == len(c.members) {
		for _, m := range c.members {
			m.Claimable += m.Collateral
			m.Collateral = 0
		}
		c.status = Completed
		c.endedAt = now
	}
}

// breakCircle winds the circle down after a default:
//
//  1. This round's pot never formed, so payments made this round go back to
//     whoever made them, and covers taken from collateral are undone.
//  2. Honest members get their remaining collateral back.
//  3. Defaulters' unwithdrawn credits (typically a pot they received and
//     have not withdrawn yet) and any collateral they still hold are pooled
//     and used to repay honest members who paid in more than they received,
//     up to that shortfall. Whatever is left goes back to the defaulters.
//
// Collateral is locked in whole contributions and a member only defaults
// when less than one contribution is left, so a defaulter's leftover
// collateral is always zero; the pool is in practice their unwithdrawn pot.
func (c *Circle) breakCircle(now int64) {
	c.history = append(c.history, Round{
		Recipient: c.members[c.turns[c.round]].Addr,
		Pot:       0,
		ClosedAt:  now,
		Marks:     string(c.marks),
	})
	contribution := c.cfg.Contribution
	for i, m := range c.members {
		switch c.marks[i] {
		case OnTime, Late:
			m.PaidIn -= contribution
			m.Claimable += contribution
		case Covered:
			m.PaidIn -= contribution
			m.Collateral += contribution
			m.Covered--
		}
		m.SwapWith = ""
	}
	// Pool what the defaulters still have here.
	pool := int64(0)
	put := make([]int64, len(c.members))
	for i, m := range c.members {
		if !m.Defaulted {
			m.Claimable += m.Collateral
			m.Collateral = 0
			continue
		}
		put[i] = m.Claimable + m.Collateral
		pool += put[i]
		m.Claimable, m.Collateral = 0, 0
	}
	// Repay honest shortfalls from the pool.
	short := int64(0)
	for _, m := range c.members {
		short += m.shortfall()
	}
	if pool > 0 && short > 0 {
		if pool >= short {
			for _, m := range c.members {
				s := m.shortfall()
				m.Claimable += s
				m.Compensated += s
			}
			pool -= short
		} else {
			paid, first := int64(0), -1
			for i, m := range c.members {
				s := m.shortfall()
				if s == 0 {
					continue
				}
				if first < 0 {
					first = i
				}
				share := mulDiv(pool, s, short)
				m.Claimable += share
				m.Compensated += share
				paid += share
			}
			dust := pool - paid
			c.members[first].Claimable += dust
			c.members[first].Compensated += dust
			pool = 0
		}
	}
	// Return what is left to the defaulters, in proportion to what they put in.
	if pool > 0 {
		total := int64(0)
		for _, p := range put {
			total += p
		}
		paid, first := int64(0), -1
		for i, m := range c.members {
			if put[i] == 0 {
				continue
			}
			if first < 0 {
				first = i
			}
			share := mulDiv(pool, put[i], total)
			m.Claimable += share
			paid += share
		}
		c.members[first].Claimable += pool - paid
	}
	c.status = Broken
	c.endedAt = now
	c.note = "a member missed a payment with no collateral left"
	c.resetMarks()
}

// shortfall is what an honest member paid in and has not got back yet.
func (m *Member) shortfall() int64 {
	if m.Defaulted {
		return 0
	}
	s := m.PaidIn - m.Received - m.Compensated
	if s < 0 {
		return 0
	}
	return s
}

// mulDiv returns floor(a*b/c) for non-negative a, b and positive c, using a
// 128-bit intermediate so a*b cannot overflow. The result fits in int64
// because callers guarantee b <= c.
func mulDiv(a, b, c int64) int64 {
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	q, _ := bits.Div64(hi, lo, uint64(c))
	return int64(q)
}

func (c *Circle) resetMarks() {
	for i := range c.marks {
		c.marks[i] = Unpaid
	}
}

func (c *Circle) allPaid() bool {
	for _, mk := range c.marks {
		if mk == Unpaid {
			return false
		}
	}
	return true
}

func (c *Circle) index(a address) int {
	for i, m := range c.members {
		if m.Addr == a {
			return i
		}
	}
	return -1
}

func (c *Circle) member(a address) *Member {
	i := c.index(a)
	if i < 0 {
		return nil
	}
	return c.members[i]
}

// turnOf returns the round in which member i receives the pot.
func (c *Circle) turnOf(i int) int {
	for r, mi := range c.turns {
		if mi == i {
			return r
		}
	}
	return -1
}

// turnAhead reports whether member i's turn is after the current round
// (during Forming every turn is ahead).
func (c *Circle) turnAhead(i int) bool {
	if i < 0 {
		return false
	}
	if c.status == Forming {
		return true
	}
	return c.turnOf(i) > c.round
}

// ---------------------------------------------------------------- views

func (c *Circle) Name() string          { return c.cfg.Name }
func (c *Circle) Organizer() address    { return c.organizer }
func (c *Circle) Contribution() int64   { return c.cfg.Contribution }
func (c *Circle) Period() int64         { return c.cfg.Period }
func (c *Circle) CollateralRounds() int { return c.cfg.CollateralRounds }
func (c *Circle) Size() int             { return len(c.members) }
func (c *Circle) Status() Status        { return c.status }
func (c *Circle) CreatedAt() int64      { return c.createdAt }
func (c *Circle) JoinBy() int64         { return c.joinBy }
func (c *Circle) StartedAt() int64      { return c.startedAt }
func (c *Circle) EndedAt() int64        { return c.endedAt }
func (c *Circle) Round() int            { return c.round }
func (c *Circle) Note() string          { return c.note }
func (c *Circle) Pot() int64            { return c.cfg.Contribution * int64(len(c.members)) }

// FullySecured reports whether collateral alone guarantees every pot.
func (c *Circle) FullySecured() bool { return c.cfg.CollateralRounds == len(c.members)-1 }

// DueAt is when the current round is due (0 unless Active).
func (c *Circle) DueAt() int64 {
	if c.status != Active {
		return 0
	}
	return c.startedAt + int64(c.round+1)*c.cfg.Period
}

// Recipient returns who receives the pot in round r (0-based).
func (c *Circle) Recipient(r int) address {
	if r < 0 || r >= len(c.turns) {
		return ""
	}
	return c.members[c.turns[r]].Addr
}

// MemberAt returns a copy of member i's books.
func (c *Circle) MemberAt(i int) (Member, bool) {
	if i < 0 || i >= len(c.members) {
		return Member{}, false
	}
	return *c.members[i], true
}

// MemberOf returns a copy of a's books.
func (c *Circle) MemberOf(a address) (Member, bool) {
	return c.MemberAt(c.index(a))
}

// TurnOf returns the round (0-based) in which a receives the pot, or -1.
func (c *Circle) TurnOf(a address) int { return c.turnOf(c.index(a)) }

// MarkOf returns a's mark in the current round.
func (c *Circle) MarkOf(a address) Mark {
	i := c.index(a)
	if i < 0 {
		return Unpaid
	}
	return c.marks[i]
}

// History returns a copy of the finished rounds.
func (c *Circle) History() []Round { return append([]Round{}, c.history...) }

// Held is what the embedding realm must be holding for this circle:
// locked collateral, this round's payments and unclaimed credits.
func (c *Circle) Held() int64 {
	held := int64(0)
	for i, m := range c.members {
		held += m.Collateral + m.Claimable
		if c.marks[i] == OnTime || c.marks[i] == Late {
			held += c.cfg.Contribution
		}
	}
	return held
}
