// Package questboard is a tavern notice board for Gno.land: anyone can pin a
// quest with a GNOT reward locked in the realm, anyone can chip in to grow the
// reward, hunters hand in their work, and the poster pays one or several
// hunters straight from escrow. If a poster disappears, anyone can expire the
// quest after a grace period and every backer gets their share back.
//
// Every state change is public and every payout is enforced by this realm, so
// the board doubles as an on-chain reputation record for hunters (quests won,
// GNOT earned) and posters (how often they actually pay).
package questboard

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"math/bits"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	denom = "ugnot"

	// MinReward is the smallest reward a quest can be pinned with (0.1 GNOT).
	MinReward int64 = 100_000
	// MinChipIn is the smallest amount accepted by Fund (0.01 GNOT).
	MinChipIn int64 = 10_000

	MinDays = 1
	MaxDays = 90

	// GracePeriod is how long a poster has after the deadline to settle
	// before anyone may call Expire and refund the backers.
	GracePeriod = 7 * 24 * time.Hour

	MaxTitleLen    = 80
	MaxDetailsLen  = 2000
	MaxProofLen    = 280
	MaxNoteLen     = 140
	MaxBackers     = 50
	MaxSubmissions = 100
)

// Status is the lifecycle state of a quest.
type Status int

const (
	StatusOpen      Status = iota
	StatusCompleted        // settled with at least one award
	StatusCancelled        // settled without any award, all funds returned
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusCompleted:
		return "completed"
	case StatusCancelled:
		return "cancelled"
	}
	return "unknown"
}

// Submission is a hunter's hand-in for a quest.
type Submission struct {
	Hunter  address
	Proof   string
	At      time.Time
	Awarded int64
}

// Payout is one payout made from a quest's escrow.
type Payout struct {
	Hunter address
	Amount int64
	Note   string
	At     time.Time
}

// Quest is a pinned task with an escrowed reward.
type Quest struct {
	ID        int
	Poster    address
	Title     string
	Details   string
	CreatedAt time.Time
	Deadline  time.Time
	ClosedAt  time.Time
	Status    Status
	Expired   bool // settled through Expire rather than by the poster

	Pool     int64 // everything ever funded
	Paid     int64 // everything awarded to hunters
	Refunded int64 // everything returned to backers

	backers  []address // in order of first contribution
	contribs avl.Tree  // address -> int64
	hunters  []address // in order of first hand-in
	subs     avl.Tree  // address -> *Submission
	Awards   []Payout
}

// Remaining is the GNOT (in ugnot) still held in escrow for the quest.
func (q *Quest) Remaining() int64 {
	return q.Pool - q.Paid - q.Refunded
}

// Profile aggregates what an address has done on the board.
type Profile struct {
	// as hunter
	HandIns int
	Wins    int
	Earned  int64
	// as poster
	Posted    int
	Completed int
	Cancelled int
	Expired   int // quests the poster let expire
	PaidOut   int64
	// as backer
	Backed int64
}

var (
	quests   avl.Tree // padded id -> *Quest
	profiles avl.Tree // address -> *Profile
	lastID   int

	totalPaid    int64
	totalEscrow  int64
	paidHunters  int
	settledCount int
)

// PostQuest pins a new quest. The reward is the ugnot sent with the call and is
// held by the realm until it is awarded or refunded. It returns the quest id.
func PostQuest(cur realm, title, details string, days int) int {
	caller := mustCaller(cur)
	if !cur.Previous().IsUserCall() {
		panic(errIndirectPayment)
	}
	amount := sentUgnot()

	title = strings.TrimSpace(title)
	details = strings.TrimSpace(details)
	if title == "" {
		panic("title is required")
	}
	if len(title) > MaxTitleLen {
		panic(ufmt.Sprintf("title is too long: %d bytes, max %d", len(title), MaxTitleLen))
	}
	if len(details) > MaxDetailsLen {
		panic(ufmt.Sprintf("details are too long: %d bytes, max %d", len(details), MaxDetailsLen))
	}
	if days < MinDays || days > MaxDays {
		panic(ufmt.Sprintf("days must be between %d and %d", MinDays, MaxDays))
	}
	if amount < MinReward {
		panic(ufmt.Sprintf("send at least %s as the reward", formatGNOT(MinReward)))
	}

	lastID++
	now := time.Now()
	q := &Quest{
		ID:        lastID,
		Poster:    caller,
		Title:     title,
		Details:   details,
		CreatedAt: now,
		Deadline:  now.Add(time.Duration(days) * 24 * time.Hour),
		Status:    StatusOpen,
	}
	q.addContribution(caller, amount)
	quests.Set(questKey(q.ID), q)

	p := profileOf(caller)
	p.Posted++
	p.Backed += amount
	totalEscrow += amount

	chain.Emit("QuestPosted",
		"id", strconv.Itoa(q.ID),
		"poster", caller.String(),
		"reward", strconv.FormatInt(amount, 10),
	)
	return q.ID
}

// Fund adds the ugnot sent with the call to an open quest's reward. Anyone can
// chip in; unawarded funds are returned pro rata when the quest is settled.
func Fund(cur realm, id int) {
	caller := mustCaller(cur)
	if !cur.Previous().IsUserCall() {
		panic(errIndirectPayment)
	}
	amount := sentUgnot()
	q := mustOpen(id)

	if !time.Now().Before(q.Deadline) {
		panic("quest deadline has passed")
	}
	if amount < MinChipIn {
		panic(ufmt.Sprintf("send at least %s", formatGNOT(MinChipIn)))
	}
	if !q.contribs.Has(caller.String()) && len(q.backers) >= MaxBackers {
		panic("quest has reached the maximum number of backers")
	}

	q.addContribution(caller, amount)
	profileOf(caller).Backed += amount
	totalEscrow += amount

	chain.Emit("QuestFunded",
		"id", strconv.Itoa(id),
		"backer", caller.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
}

// Submit hands in work for a quest. Proof is a short text or a link. A hunter
// can replace their hand-in until it has been awarded.
func Submit(cur realm, id int, proof string) {
	caller := mustCaller(cur)
	q := mustOpen(id)

	if !time.Now().Before(q.Deadline) {
		panic("quest deadline has passed")
	}
	if caller == q.Poster {
		panic("posters cannot hand in work for their own quest")
	}
	proof = strings.TrimSpace(proof)
	if proof == "" {
		panic("proof is required")
	}
	if len(proof) > MaxProofLen {
		panic(ufmt.Sprintf("proof is too long: %d bytes, max %d", len(proof), MaxProofLen))
	}

	if v, ok := lookup(&q.subs, caller.String()); ok {
		s := v.(*Submission)
		if s.Awarded > 0 {
			panic("your hand-in has already been awarded")
		}
		s.Proof = proof
		s.At = time.Now()
	} else {
		if len(q.hunters) >= MaxSubmissions {
			panic("quest has reached the maximum number of hand-ins")
		}
		q.subs.Set(caller.String(), &Submission{Hunter: caller, Proof: proof, At: time.Now()})
		q.hunters = append(q.hunters, caller)
		profileOf(caller).HandIns++
	}

	chain.Emit("WorkSubmitted",
		"id", strconv.Itoa(id),
		"hunter", caller.String(),
	)
}

// Award pays amount ugnot from the quest's escrow to a hunter who handed in
// work. Only the poster can award. A quest can be split between several
// hunters; it settles automatically once the escrow is empty.
func Award(cur realm, id int, hunter address, amount int64, note string) {
	caller := mustCaller(cur)
	q := mustOpen(id)

	if caller != q.Poster {
		panic("only the poster can award this quest")
	}
	v, ok := lookup(&q.subs, hunter.String())
	if !ok {
		panic("this address has not handed in work for the quest")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	if amount > q.Remaining() {
		panic(ufmt.Sprintf("only %s left in escrow", formatGNOT(q.Remaining())))
	}
	note = strings.TrimSpace(note)
	if len(note) > MaxNoteLen {
		panic(ufmt.Sprintf("note is too long: %d bytes, max %d", len(note), MaxNoteLen))
	}

	s := v.(*Submission)
	hp := profileOf(hunter)
	if s.Awarded == 0 {
		hp.Wins++
	}
	if hp.Earned == 0 {
		paidHunters++
	}
	s.Awarded += amount
	hp.Earned += amount
	profileOf(q.Poster).PaidOut += amount

	q.Paid += amount
	q.Awards = append(q.Awards, Payout{Hunter: hunter, Amount: amount, Note: note, At: time.Now()})
	totalPaid += amount
	totalEscrow -= amount

	send(cur, hunter, amount)

	chain.Emit("QuestAwarded",
		"id", strconv.Itoa(id),
		"hunter", hunter.String(),
		"amount", strconv.FormatInt(amount, 10),
	)

	if q.Remaining() == 0 {
		settle(cur, q, false)
	}
}

// Close settles a quest early and returns whatever is left in escrow to the
// backers, pro rata. Only the poster can close. Once hunters have handed in
// work, the poster must either award someone first or wait for the deadline.
func Close(cur realm, id int) {
	caller := mustCaller(cur)
	q := mustOpen(id)

	if caller != q.Poster {
		panic("only the poster can close this quest")
	}
	if len(q.hunters) > 0 && q.Paid == 0 && time.Now().Before(q.Deadline) {
		panic("hunters have handed in work: award someone, or wait for the deadline to close")
	}
	settle(cur, q, false)
}

// Expire can be called by anyone once a quest is past its deadline plus the
// grace period without being settled. It refunds every backer pro rata, so
// funds can never be stuck because a poster went missing.
func Expire(cur realm, id int) {
	mustCaller(cur)
	q := mustOpen(id)

	if time.Now().Before(q.Deadline.Add(GracePeriod)) {
		panic("quest can only be expired " + GracePeriod.String() + " after its deadline")
	}
	settle(cur, q, true)
}

// settle refunds the escrow left in q to its backers and closes it.
func settle(cur realm, q *Quest, expired bool) {
	refundRemaining(cur, q)

	q.ClosedAt = time.Now()
	q.Expired = expired
	pp := profileOf(q.Poster)
	if q.Paid > 0 {
		q.Status = StatusCompleted
		pp.Completed++
	} else {
		q.Status = StatusCancelled
		pp.Cancelled++
	}
	if expired {
		pp.Expired++
	}
	settledCount++

	chain.Emit("QuestSettled",
		"id", strconv.Itoa(q.ID),
		"status", q.Status.String(),
		"paid", strconv.FormatInt(q.Paid, 10),
	)
}

// refundRemaining returns q's remaining escrow to its backers in proportion
// to what each contributed. Rounding dust goes to the poster.
func refundRemaining(cur realm, q *Quest) {
	left := q.Remaining()
	if left == 0 {
		return
	}
	shares := splitProRata(left, q.Pool, q.backers, &q.contribs)
	for i, b := range q.backers {
		if shares[i] > 0 {
			send(cur, b, shares[i])
		}
	}
	q.Refunded += left
	totalEscrow -= left
}

// splitProRata divides amount among backers in proportion to their
// contribution out of total. The first backer (the poster) absorbs rounding
// dust, so the shares always add up to amount exactly.
func splitProRata(amount, total int64, backers []address, contribs *avl.Tree) []int64 {
	shares := make([]int64, len(backers))
	var given int64
	for i, b := range backers {
		v, _ := lookup(contribs, b.String())
		shares[i] = mulDiv(amount, v.(int64), total)
		given += shares[i]
	}
	if len(shares) > 0 {
		shares[0] += amount - given
	}
	return shares
}

// mulDiv returns a*b/c for non-negative a, b and positive c with a*b/c
// fitting in int64, computing the product in 128 bits so it cannot overflow.
func mulDiv(a, b, c int64) int64 {
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	q, _ := bits.Div64(hi, lo, uint64(c))
	return int64(q)
}

func (q *Quest) addContribution(addr address, amount int64) {
	key := addr.String()
	prev := int64(0)
	if v, ok := lookup(&q.contribs, key); ok {
		prev = v.(int64)
	} else {
		q.backers = append(q.backers, addr)
	}
	q.contribs.Set(key, prev+amount)
	q.Pool += amount
}

// send pays amount ugnot from the realm to addr.
func send(cur realm, to address, amount int64) {
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), to, chain.Coins{{denom, amount}})
}

// mustCaller returns the address of the direct caller of a crossing function.
func mustCaller(cur realm) address {
	if !cur.IsCurrent() {
		panic("unauthorized realm")
	}
	return cur.Previous().Address()
}

// errIndirectPayment guards every function that accepts coins. Payments are
// only accepted from a direct user call (gnokey maketx call or a wallet):
// code realms and maketx run scripts could spend the send envelope before
// reaching this realm, so OriginSend would not describe coins we received.
const errIndirectPayment = "rewards must be sent with a direct call (gnokey maketx call or a wallet)"

// sentUgnot returns the ugnot attached to the call. Callers must first check
// cur.Previous().IsUserCall().
func sentUgnot() int64 {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom {
		panic("send ugnot only")
	}
	return sent[0].Amount
}

func mustOpen(id int) *Quest {
	q := getQuest(id)
	if q == nil {
		panic("quest not found")
	}
	if q.Status != StatusOpen {
		panic("quest is " + q.Status.String())
	}
	return q
}

func getQuest(id int) *Quest {
	v, ok := lookup(&quests, questKey(id))
	if !ok {
		return nil
	}
	return v.(*Quest)
}

func profileOf(addr address) *Profile {
	if v, ok := lookup(&profiles, addr.String()); ok {
		return v.(*Profile)
	}
	p := &Profile{}
	profiles.Set(addr.String(), p)
	return p
}

// questKey zero-pads ids so the avl tree iterates them in numeric order.
func questKey(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

// ----------------------------------------------------------------------------
// Read-only getters for wallets, bots and other realms. They return copies of
// plain values, never pointers into realm state.

// QuestCount returns how many quests have ever been pinned.
func QuestCount() int { return lastID }

// QuestStatus returns the status, escrow left and deadline of a quest.
func QuestStatus(id int) (status string, remaining int64, deadline time.Time) {
	q := getQuest(id)
	if q == nil {
		panic("quest not found")
	}
	return q.Status.String(), q.Remaining(), q.Deadline
}

// HunterStats returns how many quests a hunter has won and what they earned.
func HunterStats(addr address) (wins int, earned int64) {
	v, ok := lookup(&profiles, addr.String())
	if !ok {
		return 0, 0
	}
	p := v.(*Profile)
	return p.Wins, p.Earned
}

// PosterStats returns how many quests a poster has pinned, completed with a
// payout, and let expire.
func PosterStats(addr address) (posted, completed, expired int) {
	v, ok := lookup(&profiles, addr.String())
	if !ok {
		return 0, 0, 0
	}
	p := v.(*Profile)
	return p.Posted, p.Completed, p.Expired
}

// Totals returns board-wide figures in ugnot.
func Totals() (escrow, paid int64, hunters int) {
	return totalEscrow, totalPaid, paidHunters
}

// lookup reads key from t, reporting whether it was present.
func lookup(t *avl.Tree, key string) (any, bool) {
	if !t.Has(key) {
		return nil, false
	}
	return t.Get(key), true
}
