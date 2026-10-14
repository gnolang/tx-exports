// Package hlroute is the state a bridge route realm keeps (bridge/PLAN.md §5.2–§5.5, §5.9), shared by r/hlgnot and
// r/hlbubble: the lock's counters and the supply identity, the claims in per-recipient queues, the two meters that
// rate-limit what is paid, the sweep queue, the send records a successor refunds by id, and GovDAO's decisions on
// the route's settings. It holds no coins and makes no call: the realm that owns a State moves the asset through
// the Env callbacks and asks hlmailbox what only the realm can ask. Every clock here is unix time, passed in.
package hlroute

import (
	"encoding/hex"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/decisions/v0"
)

const (
	Day = decisions.Day
	// MaxClaims is the most claims one Claim call pays (§5.4: n ≤ 20).
	MaxClaims = 20
	// MaxIDs is the most message ids one void, restore, credit or refund names.
	MaxIDs = 256
	// PageLines is how many waiting claims, and how many sweep entries, the route's page lists; the rest are
	// counted there and read by hundreds at claims/<from> and sweeps/<from>, so a flood of dust can never make
	// the page a member reads exceed a query's gas.
	PageLines = 100
	// PullPage is how many records one Pull hands to a successor (R13): the migration moves the claims, the sweep
	// entries and the sends a page at a time, so no page outgrows a block however long the route ran.
	PullPage = 500
	// MaxRangeClaims is the most credits (claims and sweep entries, voidable or not, R23) a range void's scan may
	// visit when it is made (R14): at ≈0.4M gas a credit on chain a thousand is ≈0.4B, inside a block with room;
	// GovDAO splits a bigger range by heights, from the last height a decision's note says it voided. The range is
	// closed at the height the proposal is made, so what it covers never grows after.
	MaxRangeClaims = 1000
	// guardianSeats are seats 1–4 (hlmailbox's numbering); a void's unpause option vacates at most maxGuardianSeats
	// of them (§5.3: two guardians at most per proposal).
	guardianSeats    = 4
	maxGuardianSeats = 2

	// Claim states.
	Open     = "open"     // credited, unpaid or paying
	Withheld = "withheld" // voided as withheld: the remainder stays booked, restorable at once
	Forged   = "forged"   // voided as forged: the remainder dropped, the paid part lost; restorable after 7 days
	Done     = "done"     // paid in full

	// Who credited a claim.
	BySigners = "signers" // the verifier (the signers until Proposal 2)
	ByVote    = "vote"    // GovDAO's credit by id

	// Decision kinds.
	KindCapFloor = "set cap floor"
	KindMaximum  = "set maximum"
	KindFee      = "set fee and minimum"
	KindFeeFloor = "set fee floor"
	KindRouter   = "set router"
	KindVoid     = "void"
	KindRestore  = "restore"
	KindCredit   = "credit"
	KindSweep    = "sweep"
	KindRefund   = "refund"
	// KindApplyRefund is GovDAO's own at-once apply of a queued refund decision (AT2): a refund is never Execute's.
	KindApplyRefund = "apply refund"
	KindWriteOff    = "write off"
	KindMigrate     = "migrate"
	KindCancel      = "cancel"

	one = int64(1_000_000) // 6 decimals on both sides

	maxInt64  = int64(1<<63 - 1)
	maxHeight = int64(9_999_999_999_999_999) // the height index's keys are 16 digits
)

// Launch are a route's compiled launch values.
type Launch struct {
	Symbol   string // "GNOT" or "BUBBLE"
	Fee      int64  // the flat fee on every send and the first installment of every claim
	Minimum  int64  // the least a send may carry
	FeeFloor int64  // the fee and the minimum never go below it
	CapFloor int64  // the day cap is max(CapFloor, 10% of the lock)
	Maximum  int64  // the most a send may carry
	Domain   uint32 // the destination's domain
	Router   [32]byte
	Now      int64 // deploy time: the meters start empty here
}

// Claim is one IOU the route owes a recipient (§5.4).
type Claim struct {
	ID     string // the message id, lowercase hex
	To     address
	Amount int64
	Paid   int64 // fee included
	At     int64 // credited at (unix time)
	Height int64 // credited at (block height): what a range names
	By     string
	State  string
	Seq    int64 // its place in the recipient's queue
	// QueueNext is set in a migration page only (R20): the predecessor's final counter for the recipient's queue, so
	// the successor's own credits land above every place a later page can claim. It is 0 on a stored claim.
	QueueNext int64
}

// Range names claims by when they were credited rather than by id: every claim credited at a block height from
// From to To inclusive, or — Since — every claim the verifier credited at a height at or above From, open above
// while a flag stands (the verifier's later credits are covered too) and closed by a void at the height it
// executes (claims credited after the vote were not decided on). Written "heights:<from>-<to>" or
// "since:<from>"; a guardian's payouts flag and the void builder take one in place of a list of ids, so one flag
// and one closure cover a flood larger than a list.
type Range struct {
	From, To int64
	Since    bool
}

// ParseRange reads a range; ok is false when s is not one (a list of ids, then). A malformed range panics.
func ParseRange(s string) (r Range, ok bool) {
	s = strings.TrimSpace(s)
	switch {
	case strings.HasPrefix(s, "heights:"):
		body := s[len("heights:"):]
		i := strings.Index(body, "-")
		if i < 0 {
			panic("hlroute: a height range is heights:<from>-<to>, not " + s)
		}
		from, to := parseHeight(body[:i]), parseHeight(body[i+1:])
		if to < from {
			panic("hlroute: the range runs from the lower height to the higher")
		}
		return Range{From: from, To: to}, true
	case strings.HasPrefix(s, "since:"):
		return Range{From: parseHeight(s[len("since:"):]), Since: true}, true
	}
	return Range{}, false
}

func parseHeight(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil || n < 1 || n > maxHeight {
		panic("hlroute: not a block height: " + s)
	}
	return n
}

// Covers is whether a claim credited at height — by the verifier, or not — is in the range.
func (r Range) Covers(height int64, verifier bool) bool {
	if r.Since {
		return verifier && height >= r.From && (r.To == 0 || height <= r.To)
	}
	return height >= r.From && height <= r.To
}

// String says the range in words.
func (r Range) String() string {
	if r.Since {
		s := "the verifier's credits since height " + itoa(r.From)
		if r.To != 0 {
			s += " up to height " + itoa(r.To)
		}
		return s
	}
	return "claims credited at heights " + itoa(r.From) + "-" + itoa(r.To)
}

// closed is the range as a void takes it at height: a Since range, or one reaching past height, ends there.
func (r Range) closed(height int64) Range {
	if r.Since && (r.To == 0 || r.To > height) || !r.Since && r.To > height {
		r.To = height
	}
	return r
}

// Remaining is what the claim still owes.
func (c *Claim) Remaining() int64 { return c.Amount - c.Paid }

// Meter is §5.4's bucket: a level that refills at a rate per day up to a ceiling, emptied at every payouts epoch.
// Frac carries the refill's remainder (in base units × seconds, below a day), so refills in any pieces sum to
// exactly rate a day.
type Meter struct {
	Level int64
	At    int64 // last refill
	Epoch int64 // the payouts epoch it last saw
	Frac  int64
}

// refill brings the meter up to now at rate a day, never above ceil; a new epoch empties it as of epochAt first.
// rate and ceil are at most a few billion tokens (2^63 base units over a day would overflow nothing here, as the
// elapsed seconds are capped at a day and rate%Day × Day < 2^33).
func (m *Meter) refill(now, rate, ceil, epoch, epochAt int64) {
	if m.Epoch != epoch {
		m.Level, m.At, m.Epoch, m.Frac = 0, epochAt, epoch, 0
	}
	if now <= m.At {
		return
	}
	el := now - m.At
	if el > Day {
		el = Day
		m.Frac = 0
	}
	num := (rate%Day)*el + m.Frac
	m.Level += (rate/Day)*el + num/Day
	m.Frac = num % Day
	if m.Level > ceil {
		m.Level, m.Frac = ceil, 0
	}
	m.At = now
}

// Queue is one recipient's claims, oldest first, and that recipient's own meter (a quarter of the bridge's).
type Queue struct {
	items    avl.Tree // seqKey(seq) → claim id: the open claims only (a voided or paid claim leaves the queue, R12)
	meter    Meter
	next     int64
	base     int64 // an import places a predecessor's claim at base + its old seq, so the pages keep the queue's order
	imported bool
}

// Send is one outgoing transfer's record, kept so a successor can refund it by id if it was never delivered.
type Send struct {
	From       address
	Amount     int64
	At         int64
	Refunded   int64 // when it was refunded, 0 if not
	WrittenOff int64 // when it was written off as delivered on Solana after its refund (AR1), 0 if not
	Imported   bool  // brought by a predecessor's page (AQ2): the only sends a refund may name
}

// SweepEntry is one entry of the sweep queue (§5.4): a credit that pays nobody until GovDAO directs it — a burn
// below the fee, to a realm or non-gno recipient, or above the lock — kept by id with the height it was credited
// at and who credited it, so a void names it by id or by range like a claim (R11): a forged entry is voided as
// forged (Voided: its amount leaves the sweep queue's balance and what is owed, so the identity closes) and
// restored after 7 days; a credit by id to its owner replaces it with a claim.
type SweepEntry struct {
	ID     string
	Amount int64
	Height int64
	By     string
	Voided bool
}

// Env is what the realm does for the state: the calls only a realm can make. Every field is set.
type Env struct {
	Flagged    func(id string, height int64, verifier bool) bool // a guardian's standing payouts flag on this route names the claim: by id, or by a range covering the height it was credited at (and whether the verifier credited it)
	ClearFlags func(fn string) bool                              // clears every key's flag for fn on this route (the void's unpause option)
	RemoveSeat func(seat int, holder address) bool               // vacates a guardian or watch-key seat if holder still has it (the void's unpause option); false, nothing done, if the occupant changed (R17)
	Delivered  func(id string) bool                              // hlmailbox marked the id done
	MarkDone   func(id string)                                   // marks an id done in hlmailbox (credit by vote)
	Epoch      func() int64                                      // hlmailbox's payouts epoch for this route now (a queue made by a decision starts there)
	Height     func() int64                                      // the block height now (a claim credited by a decision is credited at it; a range void closes at it)
	Pay        func(to address, amount int64)
	PayFee     func(amount int64)
	AddRoute     func(path string)        // registers a successor route with hlmailbox
	AnnouncedFor func(path string) string // the route ("GNOT" or "BUBBLE") a realm at this pkgpath announced itself to hlmailbox as a successor of (R25, AQ5), "" if it never did: a migrate names only a path announced for this route
	Predecessor  func() string            // the route whose migrate registered this realm with hlmailbox (hlmailbox.Predecessor of this realm's own path), "" for a launch route or a realm not registered yet (R31): a successor migrates on only once its own import has ended
	IsRoute      func(path string) bool   // whether hlmailbox registers a route at this pkgpath (R31): a migrate never names one
	Enrolled     func() (height, at int64) // the block height and time r/hlgov last dispatched a kind 6 enrolling this realm as the token's router on Solana, as it noted with hlmailbox (hlmailbox.Enrolled of this realm's own path); 0, 0 if never, or cleared by r/hlgov's cancel (AR1, R37): a refund waits 14 days after it, and a successor sends nothing before it (AT7)
}

// The three functions of a route a flag can pause (hlmailbox's names).
const (
	FnSends   = "sends"
	FnCredits = "credits"
	FnPayouts = "payouts"
)

// State is a route's whole state but the asset itself.
type State struct {
	Symbol string
	Domain uint32

	Fee, Minimum, FeeFloor, CapFloor, Maximum int64
	LaunchMinimum, LaunchCapFloor             int64 // the compiled floors no builder goes below

	Router   [32]byte
	OldRouter [32]byte
	OldUntil int64 // the old router's messages are accepted until this time (7 days after a swap)

	// The identity (§5.9): Lock = SentTotal − PaidTotal = supply + Owed + Voided − Lost, up to in-flight messages.
	SentTotal int64 // locked by sends (fees excluded)
	PaidTotal int64 // paid out of claims, fees included, and sweep payments
	Owed      int64 // credited, unpaid; the sweep queue included
	Voided    int64 // the unpaid remainder of claims voided as withheld
	Lost      int64 // the paid part of claims voided as forged, and the sends delivered on Solana after their refund, written off (AR1)
	Lock      int64
	Sweep     int64 // the sweep queue's balance, part of Owed

	claims   avl.Tree // id → *Claim, every claim ever credited
	credits  avl.Tree // heightKey(height, id) → id: the claims and the sweep entries by the height they were credited at, what a range walks
	queues   avl.Tree // recipient → *Queue
	waiting  avl.Tree // recipient → true while its queue holds an open claim — exact (set at a credit or a restore, dropped with the last open claim, R12): the cursor's ring and the page's walk
	cursor   string   // the last recipient served
	meter    Meter    // the bridge's meter
	sweeps   avl.Tree // id → *SweepEntry
	sends    avl.Tree // id → *Send
	refunds  avl.Tree // id → true: the sends refunded here, what refunds/<from> pages (AQ2)
	nRefunded     int64 // sends refunded here (the records held here: a refunded send goes with its page, R33)
	refundedTotal int64 // what they summed to
	nWrittenOff     int64 // sends written off as delivered on Solana after their refund (AR1), held here
	writtenOffTotal int64 // what they summed to
	nClaims  int64    // claims ever credited
	nOpen    int64    // claims open now
	exported int      // pages handed to the successor by Export (R13)
	imported int      // pages taken from a predecessor by Import, in order (R20)
	importing bool    // between a predecessor's first page and its last (AP4): Credit refuses, so no credit of this route's own can collide with a place a page still to come claims

	Ledger     decisions.Ledger
	MigratedTo string // the successor realm, once a migrate decision applied; every function then refuses
	MigratedAt int64
	LaunchSeen int64 // the launch time the meters were last emptied for
}

// New is a route's state with its launch values, the meters empty as of l.Now.
func New(l Launch) *State {
	s := &State{Symbol: l.Symbol, Domain: l.Domain, Fee: l.Fee, Minimum: l.Minimum, FeeFloor: l.FeeFloor, CapFloor: l.CapFloor,
		Maximum: l.Maximum, LaunchMinimum: l.Minimum, LaunchCapFloor: l.CapFloor, Router: l.Router}
	s.meter.At = l.Now
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func seqKey(n int64) string {
	s := itoa(n)
	return strings.Repeat("0", 12-len(s)) + s
}

// heightKey sorts the credits by height, then id.
func heightKey(h int64, id string) string {
	s := itoa(h)
	return strings.Repeat("0", 16-len(s)) + s + "|" + id
}

// Amount writes base units as whole tokens with the symbol: 12,000,000 → "12 GNOT".
func (s *State) Amount(n int64) string {
	neg := ""
	if n < 0 {
		neg, n = "-", -n
	}
	w := itoa(n / one)
	if f := n % one; f != 0 {
		fs := strconv.FormatInt(f+one, 10)[1:]
		w += "." + strings.TrimRight(fs, "0")
	}
	return neg + w + " " + s.Symbol
}

// CleanID is a message id as the state keys it: lowercase hex, no 0x; it errors on anything but 32 bytes.
func CleanID(id string) (string, error) {
	id = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(id)), "0x")
	if b, err := hex.DecodeString(id); err != nil || len(b) != 32 {
		return "", errors.New("not a 32-byte message id in hex: " + id)
	}
	return id, nil
}

func mustID(id string) string {
	c, err := CleanID(id)
	if err != nil {
		panic("hlroute: " + err.Error())
	}
	return c
}

// ParseIDs reads a comma-separated list of message ids, refusing an empty list, a bad id and a repeat.
func ParseIDs(list string) []string {
	parts := strings.Split(list, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if strings.TrimSpace(p) == "" {
			continue
		}
		id := mustID(p)
		for _, x := range out {
			if x == id {
				panic("hlroute: id named twice: " + id)
			}
		}
		out = append(out, id)
	}
	if len(out) == 0 {
		panic("hlroute: no ids")
	}
	if len(out) > MaxIDs {
		panic("hlroute: more than " + strconv.Itoa(MaxIDs) + " ids")
	}
	return out
}

// Cap is the day cap: max(the floor, a tenth of the lock).
func (s *State) Cap() int64 {
	c := s.Lock / 10
	if c < s.CapFloor {
		c = s.CapFloor
	}
	return c
}

// Migrated is whether the lock went to a successor; every function refuses then.
func (s *State) Migrated() bool { return s.MigratedTo != "" }

func (s *State) mustNotBeMigrated() {
	if s.Migrated() {
		panic("hlroute: migrated to " + s.MigratedTo)
	}
}

// mustNotBeImporting refuses what a partial record set would mislead (R28) while a predecessor's pages are still
// arriving: a range void (a page brings claims at their old heights, inside any range closed earlier) and a
// migrate (the pages still at the predecessor could never reach the next route).
func (s *State) mustNotBeImporting(what string) {
	if s.importing {
		panic("hlroute: the predecessor's pages are still arriving (" + strconv.Itoa(s.imported) + " so far): " + what + " waits for the last page")
	}
}

// ---------------------------------------------------------------- sends --

// CheckSend is what a send must satisfy: a positive amount between the minimum and the maximum.
func (s *State) CheckSend(amount int64) {
	s.mustNotBeMigrated()
	if amount <= 0 {
		panic("hlroute: the amount must be positive")
	}
	if amount < s.Minimum {
		panic("hlroute: below the minimum of " + s.Amount(s.Minimum))
	}
	if amount > s.Maximum {
		panic("hlroute: above the per-message maximum of " + s.Amount(s.Maximum))
	}
}

// Send records an outgoing transfer that locked amount.
func (s *State) Send(now int64, id string, from address, amount int64) {
	id = mustID(id)
	if s.sends.Has(id) {
		panic("hlroute: a send with this id exists")
	}
	s.sends.Set(id, &Send{From: from, Amount: amount, At: now})
	s.SentTotal += amount
	s.Lock += amount
}

// SendOf is the record of a send by id, or nil.
func (s *State) SendOf(id string) *Send {
	v := s.sends.Get(mustID(id))
	if v == nil {
		return nil
	}
	return v.(*Send)
}

// Sends is how many sends are recorded.
func (s *State) Sends() int { return s.sends.Size() }

// RouterAccepts is whether a message from this sender is from the route's router: the current one, or the old one
// within the 7 days after a swap.
func (s *State) RouterAccepts(now int64, sender [32]byte) bool {
	if sender == s.Router {
		return true
	}
	return s.OldUntil > now && sender == s.OldRouter && s.OldRouter != ([32]byte{})
}

// -------------------------------------------------------------- credits --

// queue is a recipient's queue, made on first use with its meter empty as of now under the payouts epoch of now:
// a queue made after an epoch's reset never takes that reset (which would fill it from the reset's time, up to a
// whole quarter at once); it starts empty at its first credit, as §5.4 says of every meter.
func (s *State) queue(to address, now, epoch int64) *Queue {
	v := s.queues.Get(string(to))
	if v != nil {
		return v.(*Queue)
	}
	q := &Queue{}
	q.meter.At, q.meter.Epoch = now, epoch
	s.queues.Set(string(to), q)
	return q
}

// ClaimOf is a claim by id, or nil.
func (s *State) ClaimOf(id string) *Claim {
	v := s.claims.Get(mustID(id))
	if v == nil {
		return nil
	}
	return v.(*Claim)
}

// SweptOf is the amount swept under an id (0 if none), voided or not.
func (s *State) SweptOf(id string) int64 {
	if e := s.SweepOf(id); e != nil {
		return e.Amount
	}
	return 0
}

// SweepOf is a sweep entry by id, or nil.
func (s *State) SweepOf(id string) *SweepEntry {
	v := s.sweeps.Get(mustID(id))
	if v == nil {
		return nil
	}
	return v.(*SweepEntry)
}

// Credit books an incoming transfer: a claim in the recipient's queue, or — for a burn below the fee, one to a
// realm address (sweep), or one above the lock — the sweep queue. height is the block height now (what a range
// names the claim by); epoch is hlmailbox's payouts epoch for the route now (a fresh queue's meter starts there).
// It returns whether it was swept.
//
// A burn above the lock cannot be honest (a mint needs a lock and a burn needs supply, so the supply is never
// above the lock): it is swept, owed and paying nobody until GovDAO directs it, which also bounds every claim by
// the lock. An amount that would overflow what is owed is refused outright (the message stays undelivered), and so
// is every credit while a predecessor's pages are still arriving (AP4): the relayer brings the message again once
// the last page is in.
func (s *State) Credit(now, height, epoch int64, id string, to address, amount int64, by string, sweep bool) bool {
	s.mustNotBeMigrated()
	if s.importing {
		panic("hlroute: importing a predecessor's pages (" + strconv.Itoa(s.imported) + " so far): credits are refused until the last page has arrived")
	}
	id = mustID(id)
	if s.claims.Has(id) || s.sweeps.Has(id) {
		panic("hlroute: credited already: " + id)
	}
	if amount < 0 {
		panic("hlroute: a negative amount")
	}
	if amount > maxInt64-s.Owed {
		panic("hlroute: the amount would overflow what is owed")
	}
	if sweep || amount < s.Fee || amount > s.Lock {
		s.sweepIn(height, id, amount, by)
		return true
	}
	s.enqueue(now, height, epoch, id, to, amount, by)
	return false
}

// sweepIn books a credit in the sweep queue: owed, paying nobody, indexed by its credit height like a claim.
func (s *State) sweepIn(height int64, id string, amount int64, by string) {
	if height < 0 || height > maxHeight {
		panic("hlroute: not a block height")
	}
	s.sweeps.Set(id, &SweepEntry{ID: id, Amount: amount, Height: height, By: by})
	s.credits.Set(heightKey(height, id), id)
	s.Sweep += amount
	s.Owed += amount
}

func (s *State) enqueue(now, height, epoch int64, id string, to address, amount int64, by string) *Claim {
	if height < 0 || height > maxHeight {
		panic("hlroute: not a block height")
	}
	q := s.queue(to, now, epoch)
	q.next++
	c := &Claim{ID: id, To: to, Amount: amount, At: now, Height: height, By: by, State: Open, Seq: q.next}
	s.claims.Set(id, c)
	s.credits.Set(heightKey(height, id), id)
	q.items.Set(seqKey(c.Seq), id)
	s.waiting.Set(string(to), true)
	s.Owed += amount
	s.nClaims++
	s.nOpen++
	return c
}

// oldestOpen is the first open claim in a queue, or nil.
func (s *State) oldestOpen(q *Queue) *Claim {
	var found *Claim
	q.items.Iterate("", "", func(_ string, v any) bool {
		c := s.claims.Get(v.(string)).(*Claim)
		if c.State == Open {
			found = c
			return true
		}
		return false
	})
	return found
}

// nextRecipient is the recipient after the cursor in the ring, wrapping.
func (s *State) nextRecipient() string {
	next := ""
	s.waiting.Iterate(s.cursor+"\x00", "", func(k string, _ any) bool {
		next = k
		return true
	})
	if next == "" {
		s.waiting.Iterate("", "", func(k string, _ any) bool {
			next = k
			return true
		})
	}
	return next
}

// ResetMeters empties both meters as of now (the launch).
func (s *State) ResetMeters(now int64) {
	s.meter.Level, s.meter.At, s.meter.Frac = 0, now, 0
	s.queues.Iterate("", "", func(_ string, v any) bool {
		q := v.(*Queue)
		q.meter.Level, q.meter.At, q.meter.Frac = 0, now, 0
		return false
	})
}

// MeterLevels is the bridge meter's level now and a recipient's, after refilling under the given epoch.
func (s *State) MeterLevels(now int64, to address, epoch, epochAt int64) (bridge, recipient int64) {
	c := s.Cap()
	s.meter.refill(now, c, c, epoch, epochAt)
	bridge = s.meter.Level
	if v := s.queues.Get(string(to)); v != nil {
		q := v.(*Queue)
		q.meter.refill(now, c/4, c/4, epoch, epochAt)
		recipient = q.meter.Level
	}
	return bridge, recipient
}

// Claim pays up to n claims (n ≤ 20) taking recipients in turns: the oldest open claim of each recipient with
// something waiting, as much of it as both meters allow, the fee as its first installment, skipping a recipient
// whose meter is dry. epoch and epochAt are hlmailbox's payouts epoch for this route. It returns how many claims
// it paid something on; the payments went through env.PayFee and env.Pay.
func (s *State) Claim(now int64, n int, epoch, epochAt int64, env Env) int {
	s.mustNotBeMigrated()
	if n < 1 {
		panic("hlroute: n must be positive")
	}
	if n > MaxClaims {
		n = MaxClaims
	}
	paid := 0
	for visits := 0; paid < n && visits < 4*n && s.waiting.Size() > 0; visits++ {
		addr := s.nextRecipient()
		s.cursor = addr
		q := s.queues.Get(addr).(*Queue)
		c := s.oldestOpen(q)
		if c == nil {
			s.waiting.Remove(addr)
			continue
		}
		dayCap := s.Cap()
		s.meter.refill(now, dayCap, dayCap, epoch, epochAt)
		q.meter.refill(now, dayCap/4, dayCap/4, epoch, epochAt)
		avail := s.meter.Level
		if q.meter.Level < avail {
			avail = q.meter.Level
		}
		// never more than the lock holds (R26): a claim left standing above the lock — honest claims after a
		// forgery drained part of it, or a hand credit — is paid what the lock holds, and a dry lock is a skip, not
		// a payment the realm's SendCoins would revert, the cursor with it, for every recipient behind
		if avail > s.Lock {
			avail = s.Lock
		}
		fee := int64(0)
		if c.Paid == 0 {
			fee = s.Fee
			if fee > c.Amount {
				fee = c.Amount
			}
			if avail < fee || avail <= 0 {
				continue // dry: the fee is the first installment, whole
			}
		} else if avail <= 0 {
			continue
		}
		pay := c.Remaining() - fee
		if pay > avail-fee {
			pay = avail - fee
		}
		if fee > 0 {
			env.PayFee(fee)
		}
		if pay > 0 {
			env.Pay(c.To, pay)
		}
		total := fee + pay
		c.Paid += total
		s.meter.Level -= total
		q.meter.Level -= total
		s.PaidTotal += total
		s.Owed -= total
		s.Lock -= total
		if c.Remaining() == 0 {
			s.finish(c, q)
		}
		paid++
	}
	return paid
}

// finish takes a claim paid in full out of its queue; the record stays, as done.
func (s *State) finish(c *Claim, q *Queue) {
	c.State = Done
	s.dequeue(c, q)
	s.nOpen--
}

// dequeue takes a claim out of its queue; a queue left with no open claim leaves the ring (R12: nothing but
// open claims ever sits in a queue, so a flood of voided claims never stands ahead of the open ones).
func (s *State) dequeue(c *Claim, q *Queue) {
	q.items.Remove(seqKey(c.Seq))
	if q.items.Size() == 0 {
		s.waiting.Remove(string(c.To))
	}
}

// ------------------------------------------------------------ the void --

// void applies one void to a claim: withheld keeps the remainder booked; forged drops it and books the paid part
// as lost. A withheld claim may be re-voided as forged; a claim paid in full may be voided as forged (its paid
// part becomes lost), not as withheld. An open claim voided leaves its queue (R12).
func (s *State) void(c *Claim, forged bool) {
	rem := c.Remaining()
	switch c.State {
	case Open:
		s.Owed -= rem
		s.nOpen--
		s.dequeue(c, s.queues.Get(string(c.To)).(*Queue))
		if forged {
			s.Lost += c.Paid
			c.State = Forged
		} else {
			s.Voided += rem
			c.State = Withheld
		}
	case Withheld:
		if !forged {
			panic("hlroute: " + c.ID + " is withheld already")
		}
		s.Voided -= rem
		s.Lost += c.Paid
		c.State = Forged
	case Done:
		if !forged {
			panic("hlroute: " + c.ID + " is paid in full; only a void as forged books it")
		}
		s.Lost += c.Paid
		c.State = Forged
	default:
		panic("hlroute: " + c.ID + " is forged already")
	}
}

// voidable is whether a void as forged, or as withheld, can take the claim as it stands: an open claim either way,
// a withheld or a paid one as forged only. The list form refuses such ids when the proposal is made; the range
// form skips them.
func voidable(c *Claim, forged bool) bool {
	switch c.State {
	case Open:
		return true
	case Withheld, Done:
		return forged
	}
	return false
}

// voidSweep voids a sweep entry as forged (R11): its amount leaves the sweep queue's balance and what is owed, so
// a forged entry no longer holds the identity open; nothing was paid, so nothing is lost. The balance is the sum of
// the live entries (the queue is settled by id, R19), so an entry above it is a broken invariant, refused.
func (s *State) voidSweep(e *SweepEntry) {
	if e.Voided {
		panic("hlroute: " + e.ID + " is voided already")
	}
	if e.Amount > s.Sweep {
		panic("hlroute: " + e.ID + "'s " + s.Amount(e.Amount) + " exceeds the sweep queue's balance of " + s.Amount(s.Sweep))
	}
	e.Voided = true
	s.Sweep -= e.Amount
	s.Owed -= e.Amount
}

// restoreSweep is the inverse of voidSweep.
func (s *State) restoreSweep(e *SweepEntry) {
	if !e.Voided {
		panic("hlroute: " + e.ID + " is not voided")
	}
	e.Voided = false
	s.Sweep += e.Amount
	s.Owed += e.Amount
}

// sweepVoidable is whether a void can take a sweep entry as it stands: as forged only (an entry is withheld by
// nature — owed, paying nobody — so a void as withheld has nothing to do), and once.
func sweepVoidable(e *SweepEntry, forged bool) bool { return forged && !e.Voided }

// mustFitRange counts the credits a range covers now, voidable or not, and refuses above MaxRangeClaims (R28): the
// range was under the cap when the proposal was made (DraftVoid), but a predecessor's pages bring claims at their
// old heights — inside a range closed before they arrived — so the walk that voids it, at once or after the delay,
// is counted again before it voids anything; one above the cap holds the decision for GovDAO's cancel, who splits
// the range by heights.
func (s *State) mustFitRange(r Range) {
	n := 0
	s.eachInRange(r, func(*Claim) bool {
		n++
		return n > MaxRangeClaims
	}, func(*SweepEntry) bool {
		n++
		return n > MaxRangeClaims
	})
	if n > MaxRangeClaims {
		panic("hlroute: more than " + strconv.Itoa(MaxRangeClaims) + " credits in " + r.String() + " now (a predecessor's pages brought more since the proposal was made): cancel it and split the range by heights")
	}
}

// eachInRange walks the credits a range covers — the claims and the sweep entries, by height then id — until a
// callback returns true. A Since range still open (To 0) runs to the newest credit and covers the verifier's
// credits only.
func (s *State) eachInRange(r Range, fn func(c *Claim) bool, sfn func(e *SweepEntry) bool) {
	end := "~"
	if r.To != 0 {
		end = heightKey(r.To+1, "")
	}
	s.credits.Iterate(heightKey(r.From, ""), end, func(_ string, v any) bool {
		id := v.(string)
		if cv := s.claims.Get(id); cv != nil {
			c := cv.(*Claim)
			if r.Since && c.By != BySigners {
				return false
			}
			return fn(c)
		}
		e := s.sweeps.Get(id).(*SweepEntry)
		if r.Since && e.By != BySigners {
			return false
		}
		return sfn(e)
	})
}

// restore is the full inverse of either void; a claim with a remainder goes back into its queue at its place
// (R12). now and epoch make the recipient's queue if it has none (a successor restoring an imported claim).
func (s *State) restore(c *Claim, now, epoch int64) {
	rem := c.Remaining()
	switch c.State {
	case Withheld:
		s.Voided -= rem
		s.Owed += rem
	case Forged:
		s.Lost -= c.Paid
		s.Owed += rem
	default:
		panic("hlroute: " + c.ID + " is not voided")
	}
	if rem == 0 {
		c.State = Done
		return
	}
	c.State = Open
	s.nOpen++
	q := s.queue(c.To, now, epoch)
	q.items.Set(seqKey(c.Seq), c.ID)
	s.waiting.Set(string(c.To), true)
}

// ------------------------------------------------------------- drafts --

// Draft is a builder's checked parameters: what a proposal carries, decided and applied when it executes.
type Draft struct {
	Kind   string
	Text   string
	Params any
}

type (
	capFloorParams struct{ n int64 }
	maximumParams  struct{ n int64 }
	feeParams      struct{ fee, minimum int64 }
	feeFloorParams struct{ n int64 }
	routerParams   struct{ router [32]byte }
	// VoidParams are a void's: the ids left to void (the at-once ones are gone from the list once applied) or,
	// Ranged, the range of credits to void (closed at the height the proposal executed), and the unpause option's
	// parameters — the functions whose flags to clear and the seats to vacate — applied in the executing
	// transaction.
	VoidParams struct {
		IDs         []string
		Ranged      bool
		Range       Range
		Forged      bool
		UnpauseFns  []string
		RemoveSeats []int
		RemoveAddrs []address // the seats' holders when the proposal was made: a seat whose occupant changed is skipped (R17)
	}
	restoreParams struct{ ids []string }
	creditParams  struct {
		id     string
		to     address
		amount int64
	}
	sweepParams struct {
		ids []string // the entries to pay, by id (R19): their sum goes to `to` and they are dropped
		to  address
	}
	refundParams      struct{ ids []string }
	applyRefundParams struct{ id int64 } // the queued refund decision GovDAO applies at once (AT2)
	writeOffParams    struct{ ids []string }
	migrateParams     struct{ to string }
	cancelParams      struct{ id int64 }
)

// DraftCapFloor: the day cap's floor; never below the compiled launch floor, and its quarter never below the fee
// (a recipient's meter holds a quarter of the cap at most and the fee is a claim's first installment, whole: a
// quarter under the fee would stall every new recipient's first payment, with no flag and no alarm).
func (s *State) DraftCapFloor(n int64) Draft {
	s.mustNotBeMigrated()
	if n < s.LaunchCapFloor {
		panic("hlroute: the cap floor never goes below the launch floor of " + s.Amount(s.LaunchCapFloor))
	}
	if n/4 < s.Fee {
		panic("hlroute: the cap floor's quarter never goes below the fee of " + s.Amount(s.Fee) + " (a recipient's meter must hold the fee, the first installment)")
	}
	if n == s.CapFloor {
		panic("hlroute: the cap floor is " + s.Amount(n) + " already")
	}
	return Draft{KindCapFloor, "set cap floor to " + s.Amount(n) + " (now " + s.Amount(s.CapFloor) + ")", capFloorParams{n}}
}

// DraftMaximum: the per-message maximum; never below the minimum. The description reminds GovDAO of the order a
// raise takes (R15): the pausable ISM's per-message maximum on Solana (r/hlgov's kind 12) is raised first, since a
// send above it leaves gno.land and is refused at delivery for good — stranded until a refund by id.
func (s *State) DraftMaximum(n int64) Draft {
	s.mustNotBeMigrated()
	if n < s.Minimum || n < s.LaunchMinimum {
		panic("hlroute: the maximum never goes below the minimum of " + s.Amount(s.Minimum))
	}
	if n == s.Maximum {
		panic("hlroute: the maximum is " + s.Amount(n) + " already")
	}
	return Draft{KindMaximum, "set maximum to " + s.Amount(n) + " (now " + s.Amount(s.Maximum) + "); raise the Solana limit (kind 12) first; a send above the Solana maximum strands", maximumParams{n}}
}

// DraftFee: the fee and the minimum together; the fee not below the fee floor and not above a quarter of the cap
// floor (the most a recipient's meter can hold, and the fee is the first installment, whole), the minimum positive
// and not above the maximum.
func (s *State) DraftFee(fee, minimum int64) Draft {
	s.mustNotBeMigrated()
	if fee < s.FeeFloor {
		panic("hlroute: the fee never goes below the fee floor of " + s.Amount(s.FeeFloor))
	}
	if fee > s.CapFloor/4 {
		panic("hlroute: the fee never goes above a quarter of the cap floor (" + s.Amount(s.CapFloor/4) + "): a recipient's meter holds a quarter at most and the fee is the first installment, whole")
	}
	if minimum <= 0 || minimum > s.Maximum {
		panic("hlroute: the minimum must be positive and not above the maximum of " + s.Amount(s.Maximum))
	}
	if fee == s.Fee && minimum == s.Minimum {
		panic("hlroute: nothing changes")
	}
	return Draft{KindFee, "set fee to " + s.Amount(fee) + " and minimum to " + s.Amount(minimum) + " (now " + s.Amount(s.Fee) + " and " + s.Amount(s.Minimum) + ")", feeParams{fee, minimum}}
}

// DraftFeeFloor: the fee floor; not above the fee, not negative.
func (s *State) DraftFeeFloor(n int64) Draft {
	s.mustNotBeMigrated()
	if n < 0 || n > s.Fee {
		panic("hlroute: the fee floor must be between 0 and the fee of " + s.Amount(s.Fee))
	}
	if n == s.FeeFloor {
		panic("hlroute: the fee floor is " + s.Amount(n) + " already")
	}
	return Draft{KindFeeFloor, "set fee floor to " + s.Amount(n) + " (now " + s.Amount(s.FeeFloor) + ")", feeFloorParams{n}}
}

// DraftRouter: the remote router; the old one's messages stay accepted 7 days after the swap applies.
func (s *State) DraftRouter(router [32]byte, text string) Draft {
	s.mustNotBeMigrated()
	if router == ([32]byte{}) {
		panic("hlroute: the router is all zeros")
	}
	if router == s.Router {
		panic("hlroute: that is the router already")
	}
	return Draft{KindRouter, "set router to " + text, routerParams{router}}
}

// ParseFns reads a comma-separated list of the three functions, "" for none; no repeats.
func ParseFns(fns string) []string {
	var out []string
	for _, p := range strings.Split(fns, ",") {
		fn := strings.TrimSpace(p)
		if fn == "" {
			continue
		}
		if fn != FnSends && fn != FnCredits && fn != FnPayouts {
			panic("hlroute: the functions are sends, credits and payouts, not " + fn)
		}
		for _, x := range out {
			if x == fn {
				panic("hlroute: " + fn + " named twice")
			}
		}
		out = append(out, fn)
	}
	return out
}

// ParseSeats reads a comma-separated list of seat numbers (1–6), "" for none; no repeats, and two guardian seats
// (1–4) at most — §5.3's cap on guardian changes per proposal, the same as hlmailbox's rotate seats, so no void
// vacates the four guardians in one stroke.
func ParseSeats(seats string) []int {
	var out []int
	g := 0
	for _, p := range strings.Split(seats, ",") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 6 {
			panic("hlroute: the seat must be 1 to 6, not " + p)
		}
		for _, x := range out {
			if x == n {
				panic("hlroute: seat " + p + " named twice")
			}
		}
		if n <= guardianSeats {
			g++
		}
		out = append(out, n)
	}
	if g > maxGuardianSeats {
		panic("hlroute: two guardian seats at most per proposal")
	}
	return out
}

// seatsText writes seat removals as seat:address pairs.
func seatsText(seats []int, addrs []address) string {
	parts := make([]string, len(seats))
	for i, n := range seats {
		parts[i] = strconv.Itoa(n) + ":" + string(addrs[i])
	}
	return strings.Join(parts, ",")
}

// DraftVoid: void credits by id — a list of up to MaxIDs ids, claims or sweep entries (an entry as forged only),
// or a Range ("heights:<from>-<to>", every credit at those heights; "since:<from>", every credit the verifier made
// at or after it), closed at height — the block height the proposal is made at (R14), so what it covers never
// grows before it executes — and covering at most MaxRangeClaims credits, voidable or not (R23: the walk at
// execution visits them all), else GovDAO splits it by heights — as withheld or forged, with the unpause option —
// the functions whose flags to clear (comma
// separated, "" for none) and the seats to vacate (comma separated, "" for none; seatOf gives each seat's holder
// now, recorded so a seat whose occupant changes before the proposal executes is skipped, R17), applied in the
// same closure as the void so the void and the reopening never execute in the wrong order (§5.3). A range must
// cover a credit the void can take when the proposal is made; one in it the void cannot take as it stands
// (forged already; withheld, paid or a sweep entry, for a void as withheld) is skipped, not refused.
func (s *State) DraftVoid(ids string, forged bool, unpauseFns, removeSeats string, height int64, seatOf func(seat int) address) Draft {
	s.mustNotBeMigrated()
	fns, seats := ParseFns(unpauseFns), ParseSeats(removeSeats)
	addrs := make([]address, len(seats))
	for i, seat := range seats {
		if addrs[i] = seatOf(seat); addrs[i] == "" {
			panic("hlroute: seat " + strconv.Itoa(seat) + " is empty")
		}
	}
	how := "withheld"
	if forged {
		how = "forged"
	}
	p := VoidParams{Forged: forged, UnpauseFns: fns, RemoveSeats: seats, RemoveAddrs: addrs}
	var text string
	if r, ok := ParseRange(ids); ok {
		s.mustNotBeImporting("a range void")
		r = r.closed(height)
		// the cap counts every credit the scan visits, voidable or not (R23): the walk at execution covers them
		// all, so a range over a flood voided already costs as much as the flood; the decision's note names the
		// last height it voided, where the next range starts
		n, v := 0, 0
		s.eachInRange(r, func(c *Claim) bool {
			n++
			if voidable(c, forged) {
				v++
			}
			return n > MaxRangeClaims
		}, func(e *SweepEntry) bool {
			n++
			if sweepVoidable(e, forged) {
				v++
			}
			return n > MaxRangeClaims
		})
		if n > MaxRangeClaims {
			panic("hlroute: more than " + strconv.Itoa(MaxRangeClaims) + " credits in " + r.String() + ", voidable or not: split the range by heights")
		}
		if v == 0 {
			panic("hlroute: no claim to void in " + r.String())
		}
		p.Ranged, p.Range = true, r
		text = "void as " + how + ": " + r.String()
	} else {
		list := ParseIDs(ids)
		for _, id := range list {
			if e := s.SweepOf(id); e != nil {
				switch {
				case !forged:
					panic("hlroute: " + id + " is a sweep entry: voided as forged only")
				case e.Voided:
					panic("hlroute: " + id + " is voided already")
				}
				continue
			}
			c := s.ClaimOf(id)
			if c == nil {
				panic("hlroute: no claim or sweep entry " + id)
			}
			switch {
			case c.State == Forged:
				panic("hlroute: " + id + " is forged already")
			case c.State == Withheld && !forged:
				panic("hlroute: " + id + " is withheld already")
			case c.State == Done && !forged:
				panic("hlroute: " + id + " is paid in full; only a void as forged books it")
			}
		}
		p.IDs = list
		text = "void as " + how + ": " + strings.Join(list, ",")
	}
	if len(fns) > 0 {
		text += ", and unpause " + strings.Join(fns, ",")
	}
	if len(seats) > 0 {
		text += ", removing seats " + seatsText(seats, addrs)
	}
	return Draft{KindVoid, text, p}
}

// DraftRestore: restore voided claims, voided sweep entries, or written-off sends, by id — a write-off's inverse
// (R38): a mistaken write-off (a record two providers showed differently read as delivered, a neighbouring id in
// a list) books lost for the deployment's life, the watch's "mistaken void" alarm stands as long, and a later
// forged credit up to that amount moves the alarm's figure and trips nothing; the restore clears the mark and
// takes the amount back out of lost, after 7 days like a forged claim's restore, since it re-opens the identity.
func (s *State) DraftRestore(ids string) Draft {
	s.mustNotBeMigrated()
	list := ParseIDs(ids)
	for _, id := range list {
		if e := s.SweepOf(id); e != nil {
			if !e.Voided {
				panic("hlroute: " + id + " is not voided")
			}
			continue
		}
		if sd := s.SendOf(id); sd != nil {
			if sd.WrittenOff == 0 {
				panic("hlroute: " + id + " is a send that is not written off: nothing to restore")
			}
			continue
		}
		c := s.ClaimOf(id)
		if c == nil || (c.State != Withheld && c.State != Forged) {
			panic("hlroute: " + id + " is not voided")
		}
	}
	return Draft{KindRestore, "restore: " + strings.Join(list, ","), restoreParams{list}}
}

// DraftCredit: credit a claim by id, by hand (§5.3): refused for an id already done unless its claim stands
// voided, or the id is a sweep entry's (R11) — the credit then replaces the entry with the claim it names, the
// cure for a burn to a realm or non-gno recipient, or a diverted credit. The amount is at most the lock (R26,
// R7's rule for the verifier's credits: a credit above the lock cannot be honest, and a claim above it would ask
// Claim for coins the lock does not hold); the closure asks again.
func (s *State) DraftCredit(id string, to address, amount int64, delivered bool) Draft {
	s.mustNotBeMigrated()
	id = mustID(id)
	if amount <= 0 {
		panic("hlroute: the amount must be positive")
	}
	if amount > s.Lock {
		panic("hlroute: the amount " + s.Amount(amount) + " is above the lock of " + s.Amount(s.Lock) + " (a credit above the lock cannot be honest)")
	}
	text := "credit " + id + " to " + string(to) + " for " + s.Amount(amount)
	if c := s.ClaimOf(id); c != nil {
		if c.State != Withheld && c.State != Forged {
			panic("hlroute: " + id + " is credited already and not voided")
		}
	} else if e := s.SweepOf(id); e != nil {
		text += " (replacing the sweep entry of " + s.Amount(e.Amount) + ")"
	} else if delivered {
		panic("hlroute: " + id + " is done already")
	}
	return Draft{KindCredit, text, creditParams{id, to, amount}}
}

// DraftSweep: pay sweep entries, named by id (comma separated, up to MaxIDs), to an address — their sum, at most
// the lock (R11: a forged entry above the lock is voided, never paid out of coins the lock does not hold). The
// queue is settled by id (R19): a paid entry is dropped with its index, so it never stands to be credited by id or
// voided a second time, and the counters never go negative. A voided entry is restored first; a claim's id is no
// entry's; an entry voided or gone by the time the payment applies is skipped and the note says so.
func (s *State) DraftSweep(ids string, to address) Draft {
	s.mustNotBeMigrated()
	list := ParseIDs(ids)
	sum := int64(0)
	for _, id := range list {
		e := s.SweepOf(id)
		switch {
		case e == nil && s.ClaimOf(id) != nil:
			panic("hlroute: " + id + " is a claim, not a sweep entry")
		case e == nil:
			panic("hlroute: no sweep entry " + id)
		case e.Voided:
			panic("hlroute: " + id + " is voided; restore it first")
		}
		sum += e.Amount
	}
	if sum > s.Lock {
		panic("hlroute: the entries sum to " + s.Amount(sum) + ", above the lock's " + s.Amount(s.Lock))
	}
	return Draft{KindSweep, "pay " + s.Amount(sum) + " of the sweep queue to " + string(to) + ": " + strings.Join(list, ","), sweepParams{list, to}}
}

// DraftRefund: refund sends by id to their senders — a successor's duty, over the sends it imported from its
// predecessor (AQ2, §5.3): a refunded send stays deliverable on Solana, so only a send addressed to a router the
// token no longer enrolls is ever refunded, after kind 6 enrolled this realm — which the realm cannot see, so it
// reads the note r/hlgov leaves with the mailbox when it dispatches a kind 6 for this route (Env.Enrolled) and
// refuses until the note is 14 days old (AR1, R37, mustBeEnrolled; asked again when the refund applies): a refund
// that lands before kind 6 lets one stranger's Reemit and delivery of the refunded send mint it twice, with no
// realm able to refuse the message. Necessary, not sufficient: the member checks hlwatch first, which reads the
// token's enrolled router on Solana and the kind 6's state there, alarms a refund proposal whose successor the
// token has not enrolled and prints DELIVERED beside any id Solana processed — and the apply, after the 7 days,
// is GovDAO's own at-once decision (DraftApplyRefund, AT2), never anyone's Execute, so that check stands between
// the delay and the coins. A live route's own send, stranded or not, is never refunded: it waits for a kind 12
// (§5.4). The sum is at most the lock (R30, the sweep payment's bound: a forgery paid before its void can leave
// the lock short of the sends it imported), checked again when it applies.
func (s *State) DraftRefund(ids string, now int64, env Env) Draft {
	s.mustNotBeMigrated()
	s.mustBeEnrolled(now, env)
	list := ParseIDs(ids)
	sum := int64(0)
	for _, id := range list {
		sd := s.SendOf(id)
		switch {
		case sd == nil || sd.Refunded != 0:
			panic("hlroute: " + id + " is not a send to refund")
		case !sd.Imported:
			panic("hlroute: " + id + " is this route's own send: a stranded send waits for a kind 12 on Solana, never a refund (a refund is a successor's, over the sends it imported)")
		}
		sum += sd.Amount
	}
	if sum > s.Lock {
		panic("hlroute: the sends sum to " + s.Amount(sum) + ", above the lock's " + s.Amount(s.Lock))
	}
	return Draft{KindRefund, "refund " + s.Amount(sum) + " of sends imported from the predecessor (14 days after kind 6's dispatch enrolled this realm) to their senders: " + strings.Join(list, ","), refundParams{list}}
}

// EnrolmentWait is how long a refund waits after r/hlgov's dispatch of the kind 6 enrolling this route (R37, F27):
// two of the 7-day delays — a week for the delivery to Solana and a week for Solana's own clock, since the admin
// program executes a kind 6 7 days after it is recorded there, so a week from the dispatch always ended before
// the enrolment could take effect. A hold defers Solana further, which the realm cannot see: hlwatch and the
// relayer read the token's enrolled router there.
const EnrolmentWait = 2 * decisions.Delay

// mustBeEnrolled refuses a refund until kind 6 has enrolled this route on Solana for 14 days (EnrolmentWait), by
// the note r/hlgov leaves with the mailbox when it dispatches one (AR1, R37) — a cancelled kind 6 clears the note
// (hlmailbox.ClearEnrolled, from r/hlgov's cancel), so the wait restarts with a re-proposal. The latest note
// counts — a later kind 6 for the route restarts the wait; a refund is irreversible and two weeks are cheap.
func (s *State) mustBeEnrolled(now int64, env Env) {
	h, at := env.Enrolled()
	if h == 0 {
		panic("hlroute: no kind 6 has enrolled this route on Solana yet (none dispatched from r/hlgov): a refund waits 14 days after the enrolment, since a refunded send stays deliverable there until the predecessor's router is replaced")
	}
	if now < at+EnrolmentWait {
		panic("hlroute: kind 6 enrolling this route was dispatched at height " + itoa(h) + ", " + itoa(now-at) + " s ago: a refund waits 14 days after it (until " + itoa(at+EnrolmentWait) + "): a week for the delivery and a week for Solana's own clock, which executes a kind 6 7 days after recording it; a hold defers it further, which hlwatch reads there")
	}
}

// DraftApplyRefund: GovDAO's own at-once apply of a queued refund decision whose 7 days have passed (AT2). A refund
// is the one decision whose gate the realm cannot read — Solana's: the token's router there must be this realm and
// the kind 6 executed, which hlwatch reads and alarms NOT ENROLLED ON SOLANA while it is not — and anyone's
// Execute on the note alone let a refunded sender, his id in the proposal's description, apply his refund the day
// it matured while a kind 6 deferred by one flag left the predecessor the router, then deliver his send there
// with the published tool: minted twice, the lock short for good. So Execute refuses the kind, and a refund is
// applied by this builder alone — at once, like an unpause — the member having read hlwatch's gate before the
// vote. The apply is the delay's own (apply's refund branch: mustBeEnrolled's 14-day note asked again, the sum at
// most the lock, a send refunded since skipped), and the realm asks its payouts flag of it as of a sweep payment.
// Refused — when the proposal is made and again when it executes, the proposal surviving for a retry — for a
// decision that is no refund, one not pending (applied, cancelled), one whose delay has not passed, and until the
// note is 14 days old. The description names the refund decision and carries its text, the ids included.
func (s *State) DraftApplyRefund(id, now int64, env Env) Draft {
	s.mustNotBeMigrated()
	d := s.refundToApply(id, now, env)
	return Draft{KindApplyRefund, "apply refund decision " + itoa(id) + " at once (" + d.Text + "), after hlwatch's check that the token's router on Solana is this realm", applyRefundParams{id}}
}

// refundToApply is the queued refund decision an apply names, as it stands now: a refund, pending, its delay
// passed, the enrolment note 14 days old (mustBeEnrolled; asked once more by the refund's own apply).
func (s *State) refundToApply(id, now int64, env Env) *decisions.Decision {
	d := s.Ledger.Get(id)
	if d == nil {
		panic("hlroute: no decision " + itoa(id))
	}
	if d.Kind != KindRefund {
		panic("hlroute: decision " + itoa(id) + " is of kind " + d.Kind + ", not refund: an apply refund names a queued refund decision")
	}
	if !d.Pending() {
		panic("hlroute: refund decision " + itoa(id) + " is " + d.State() + ", not pending")
	}
	if now < d.Due {
		panic("hlroute: refund decision " + itoa(id) + " is queued until " + itoa(d.Due) + " (" + itoa(d.Due-now) + " s more): its 7 days have not passed")
	}
	s.mustBeEnrolled(now, env)
	return d
}

// DraftWriteOff: book refunded sends, by id (comma separated, up to MaxIDs), as lost (AR1) — a refunded send
// delivered on Solana after all, by a stranger's Reemit before kind 6 replaced the predecessor's router or in the
// day a hold's lift leaves, minted a second time against nothing, and no builder but this one closes the
// identity: lock = sentTotal − paidTotal = supply + owed + voided − lost, the amount lost. Only a refunded send,
// once; the realm cannot see Solana, so the member reads hlwatch's DELIVERED line for each id first and the
// description says so. After 7 days; an id written off by another decision since is skipped and counted.
func (s *State) DraftWriteOff(ids string) Draft {
	s.mustNotBeMigrated()
	list := ParseIDs(ids)
	sum := int64(0)
	for _, id := range list {
		sd := s.SendOf(id)
		switch {
		case sd == nil || sd.Refunded == 0:
			panic("hlroute: " + id + " is not a refunded send: only a send delivered on Solana after its refund is written off")
		case sd.WrittenOff != 0:
			panic("hlroute: " + id + " is written off already")
		}
		sum += sd.Amount
	}
	return Draft{KindWriteOff, "write off " + s.Amount(sum) + " of refunded sends delivered on Solana after their refund (hlwatch's DELIVERED line names the id): " + strings.Join(list, ","), writeOffParams{list}}
}

// DraftMigrate: the lock, the claims and the send records go to a successor realm at pkgpath — a deployed
// realm's, never a sub-identity's (`host#subpath`; the mailbox refuses such a route too), never a route the
// mailbox registers already (R31: the mailbox would refuse it when the migration applies, a week on, the vote
// wasted), and one that announced itself to the mailbox from its own code for this route (Env.AnnouncedFor: the
// symbol it named, "" if it never announced itself, R25 and AQ5), so the lock never goes to a path with no realm
// behind it — a typo, or an undeployed path whose namespace owner could deploy anything there and pull it — nor
// to the other token's successor by a slip. A route that succeeds another migrates on only once its own import
// has ended (R28, R31): before page 0 nothing has moved, and its MigratedTo would make its Import refuse, the
// predecessor's Pull revert for ever and the lock sit on the first predecessor, which refuses everything, with no
// decision that reaches it. The same checks are made again when the migration applies (mustMigrate).
func (s *State) DraftMigrate(to, self string, env Env) Draft {
	s.mustAllowMigrate(to)
	if !strings.HasPrefix(to, "gno.land/r/") || strings.Contains(to, "#") || to == self {
		panic("hlroute: the successor is another realm under gno.land/r/")
	}
	s.mustMigrate(to, env)
	return Draft{KindMigrate, "migrate to " + to + " (announced as the " + s.Symbol + " route's successor)", migrateParams{to}}
}

// mustAllowMigrate is a migrated route's one exception to "every function refuses" (AR2): before page 0 nothing has
// moved — the lock and the counters go with the first page — so while the successor named has pulled nothing a
// second migrate re-points the migration to another successor (7 days, like the first; the mailbox replaces the
// registration), the cure for a successor that never pulls or whose driver refuses every caller, which would
// otherwise hold the lock on a predecessor that refuses everything, with no decision that reaches it. The same
// successor is refused (nothing to re-point); once page 0 is pulled the migration is under way and no decision
// re-points it. Asked when the proposal is made, when it executes and when the migration would apply.
func (s *State) mustAllowMigrate(to string) {
	if !s.Migrated() {
		return
	}
	if s.exported > 0 {
		panic("hlroute: migrated to " + s.MigratedTo + ": the successor pulled " + strconv.Itoa(s.exported) + " pages already (the lock moved with page 0); a migration under way is never re-pointed")
	}
	if to == s.MigratedTo {
		panic("hlroute: migrated to " + to + " already (nothing pulled yet): a re-point names another successor")
	}
}

// mustMigrate is every check a migrate to `to` must pass against the live state, when the proposal is made and
// again when the migration would apply (R31): this route's own import, if it succeeds another, ended — page 0 in
// (nothing pulled is "page 0 is not in yet") and the last page too (R28) — the path no route the mailbox registers
// already, and announced for this route (R25, AQ5). A failure when the migration would apply leaves the decision
// pending for a retry or a cancel, never spent.
func (s *State) mustMigrate(to string, env Env) {
	s.mustNotBeImporting("a migrate")
	if pred := env.Predecessor(); pred != "" && s.imported == 0 {
		panic("hlroute: page 0 is not in yet: this route succeeds " + pred + " and has pulled nothing; a migrate waits for the last page of its own import")
	}
	if env.IsRoute(to) {
		panic("hlroute: the successor " + to + " is a route already")
	}
	s.mustBeAnnouncedFor(to, env.AnnouncedFor(to))
}

// mustBeAnnouncedFor refuses a successor that never announced itself, or announced itself for the other route.
func (s *State) mustBeAnnouncedFor(to, announcedFor string) {
	switch announcedFor {
	case "":
		panic("hlroute: the successor " + to + " has not announced itself to the mailbox (hlmailbox.AnnounceSuccessor, from its own code)")
	case s.Symbol:
	default:
		panic("hlroute: the successor " + to + " announced itself as the " + announcedFor + " route's successor, not this " + s.Symbol + " route's")
	}
}

// DraftCancel: cancel a pending decision of this route.
func (s *State) DraftCancel(id int64) Draft {
	d := s.Ledger.Get(id)
	if d == nil || !d.Pending() {
		panic("hlroute: decision " + itoa(id) + " is not pending")
	}
	return Draft{KindCancel, "cancel decision " + itoa(id) + " (" + d.Text + ")", cancelParams{id}}
}

// ------------------------------------------------------------ deciding --

// Decide is what a builder's closure does when its proposal executes: it records the decision and settles the
// at-once test against the live state — a lowering, a cancel, a restore of a withheld claim and the void of ids a
// guardian's standing payouts flag names apply now; everything else waits 7 days for Execute. A migrate is
// checked again here (R31, AR2: the state may have moved since the proposal was made) and a cancel, or a migrate
// that re-points a migration nothing was pulled from, is taken on a migrated route.
func (s *State) Decide(made, now int64, d Draft, env Env) *decisions.Decision {
	if d.Kind != KindCancel && d.Kind != KindMigrate {
		s.mustNotBeMigrated()
	}
	record := func(due int64, params any) *decisions.Decision {
		return s.Ledger.Record(d.Kind, d.Text, params, made, now, due)
	}
	switch p := d.Params.(type) {
	case capFloorParams:
		if p.n <= s.CapFloor {
			dec := record(now, p)
			s.apply(dec, now, env)
			s.Ledger.Apply(dec, now, "at once: a lowering")
			return dec
		}
		return s.queued(record(now+decisions.Delay, p))
	case maximumParams:
		if p.n <= s.Maximum {
			dec := record(now, p)
			s.apply(dec, now, env)
			s.Ledger.Apply(dec, now, "at once: a lowering")
			return dec
		}
		return s.queued(record(now+decisions.Delay, p))
	case feeParams:
		if p.fee <= s.Fee && p.minimum <= s.Minimum {
			dec := record(now, p)
			s.apply(dec, now, env)
			s.Ledger.Apply(dec, now, "at once: a lowering")
			return dec
		}
		return s.queued(record(now+decisions.Delay, p))
	case feeFloorParams:
		if p.n <= s.FeeFloor {
			dec := record(now, p)
			s.apply(dec, now, env)
			s.Ledger.Apply(dec, now, "at once: a lowering")
			return dec
		}
		return s.queued(record(now+decisions.Delay, p))
	case VoidParams:
		// per credit, once, now: a claim or sweep entry some guardian's standing payouts flag names — by id, or by
		// a range covering its credit — is voided at once, the rest wait in the same decision (the list of those
		// left, or the range, closed when the proposal was made); a range skips a credit the void cannot take as
		// it stands
		var later []string
		n, skipped, queued := 0, 0, 0
		last := int64(0) // the last height voided at once (the walk is by height), named in the note (R23)
		rest := VoidParams{Forged: p.Forged}
		if p.Ranged {
			r := p.Range // closed at the height the proposal was made (R14)
			s.mustFitRange(r)
			s.eachInRange(r, func(c *Claim) bool {
				switch {
				case !voidable(c, p.Forged):
					skipped++
				case env.Flagged(c.ID, c.Height, c.By == BySigners):
					s.void(c, p.Forged)
					n++
					last = c.Height
				default:
					queued++
				}
				return false
			}, func(e *SweepEntry) bool {
				switch {
				case !sweepVoidable(e, p.Forged):
					skipped++
				case env.Flagged(e.ID, e.Height, e.By == BySigners):
					s.voidSweep(e)
					n++
					last = e.Height
				default:
					queued++
				}
				return false
			})
			rest.Ranged, rest.Range = true, r
		} else {
			// an id the void cannot take as it stands — voided by another decision since the proposal was made,
			// paid in full under a void as withheld, or gone — is skipped and counted, the range form's rule, never
			// a panic that blocks the whole proposal with its unpause option and seat removals (R22)
			for _, id := range p.IDs {
				if e := s.SweepOf(id); e != nil {
					switch {
					case !sweepVoidable(e, p.Forged):
						skipped++
					case env.Flagged(id, e.Height, e.By == BySigners):
						s.voidSweep(e)
						n++
					default:
						later = append(later, id)
					}
					continue
				}
				c := s.ClaimOf(id)
				switch {
				case c == nil || !voidable(c, p.Forged):
					skipped++
				case env.Flagged(id, c.Height, c.By == BySigners):
					s.void(c, p.Forged)
					n++
				default:
					later = append(later, id)
				}
			}
			rest.IDs, queued = later, len(later)
		}
		for _, fn := range p.UnpauseFns {
			env.ClearFlags(fn)
		}
		// a seat is vacated only while the key the proposal named still holds it (R17): a replacement that landed
		// in between stays, and the note says so
		var vacated, kept []string
		for i, seat := range p.RemoveSeats {
			if env.RemoveSeat(seat, p.RemoveAddrs[i]) {
				vacated = append(vacated, strconv.Itoa(seat))
			} else {
				kept = append(kept, strconv.Itoa(seat))
			}
		}
		note := itoa(int64(n)) + " voided at once (named by a guardian's payouts flag)"
		if p.Ranged {
			note += " of " + rest.Range.String()
		}
		if skipped > 0 {
			note += ", " + itoa(int64(skipped)) + " skipped (not voidable as it stands)"
		}
		if len(p.UnpauseFns) > 0 {
			note += ", unpaused " + strings.Join(p.UnpauseFns, ",")
		}
		if len(vacated) > 0 {
			note += ", seats " + strings.Join(vacated, ",") + " vacated"
		}
		if len(kept) > 0 {
			note += ", seats " + strings.Join(kept, ",") + " skipped (the occupant changed since the proposal was made)"
		}
		lastNote := ""
		if p.Ranged && n > 0 {
			lastNote = ", last voided at height " + itoa(last)
		}
		if queued == 0 {
			dec := record(now, VoidParams{Forged: p.Forged, UnpauseFns: p.UnpauseFns, RemoveSeats: p.RemoveSeats, RemoveAddrs: p.RemoveAddrs})
			s.Ledger.Apply(dec, now, "at once: "+note+lastNote)
			return dec
		}
		dec := record(now+decisions.Delay, rest)
		dec.Note = note + ", " + itoa(int64(queued)) + " queued 7 days" + lastNote
		return dec
	case restoreParams:
		// a withheld claim at once; a forged claim, a voided sweep entry and a written-off send (R38), after 7 days;
		// an id no longer voided (restored by another decision since the proposal was made) or gone is skipped and
		// counted (R22)
		var later []string
		n, skipped := 0, 0
		for _, id := range p.ids {
			if e := s.SweepOf(id); e != nil {
				if !e.Voided {
					skipped++
					continue
				}
				later = append(later, id)
				continue
			}
			if sd := s.SendOf(id); sd != nil {
				if sd.WrittenOff == 0 {
					skipped++
					continue
				}
				later = append(later, id)
				continue
			}
			c := s.ClaimOf(id)
			switch {
			case c == nil:
				skipped++
			case c.State == Withheld:
				s.restore(c, now, env.Epoch())
				n++
			case c.State == Forged:
				later = append(later, id)
			default:
				skipped++
			}
		}
		note := itoa(int64(n)) + " withheld restored at once"
		if skipped > 0 {
			note += ", " + itoa(int64(skipped)) + " skipped (not voided as it stands)"
		}
		if len(later) == 0 {
			dec := record(now, restoreParams{})
			s.Ledger.Apply(dec, now, "at once: "+note)
			return dec
		}
		dec := record(now+decisions.Delay, restoreParams{later})
		dec.Note = note + ", " + itoa(int64(len(later))) + " forged, or written off, queued 7 days"
		return dec
	case cancelParams:
		if _, err := s.Ledger.Cancel(p.id, now); err != nil {
			panic("hlroute: " + err.Error())
		}
		dec := record(now, p)
		s.Ledger.Apply(dec, now, "at once: cancelled")
		return dec
	case migrateParams:
		s.mustAllowMigrate(p.to)
		s.mustMigrate(p.to, env)
		return s.queued(record(now+decisions.Delay, p))
	case refundParams:
		// queued 7 days like a sweep payment, but applied by GovDAO's own at-once decision after (AT2:
		// DraftApplyRefund), never by anyone's Execute — the note says so
		dec := s.queued(record(now+decisions.Delay, p))
		dec.Note += ": applied by GovDAO's own apply refund decision after, never by Execute"
		return dec
	case applyRefundParams:
		// GovDAO's own at-once apply of a queued refund (AT2): the refund decision is asked again as it stands — a
		// refund, pending, its delay passed, the note 14 days old — and applied as the delay would have applied it,
		// before anything is recorded (a refusal is a panic that leaves no record, so the proposal survives a retry
		// until its deadline); then both decisions are noted, each naming the other
		rd := s.refundToApply(p.id, now, env)
		note := s.apply(rd, now, env)
		dec := record(now, p)
		s.Ledger.Apply(rd, now, "applied by GovDAO's apply refund decision "+itoa(dec.ID)+note)
		s.Ledger.Apply(dec, now, "at once: refund decision "+itoa(p.id)+" applied"+note)
		return dec
	case routerParams, creditParams, sweepParams, writeOffParams:
		return s.queued(record(now+decisions.Delay, d.Params))
	}
	panic("hlroute: unknown draft " + d.Kind)
}

func (s *State) queued(dec *decisions.Decision) *decisions.Decision {
	dec.Note = "queued 7 days"
	return dec
}

// Execute applies a queued decision whose delay has passed; on a migrated route only a migrate that re-points a
// migration nothing was pulled from (AR2: apply asks). Never a refund (AT2): its apply is GovDAO's own at-once
// decision (DraftApplyRefund), made after hlwatch's check that the token's router on Solana is this realm — a check
// the realm cannot make and anyone's Execute would skip.
func (s *State) Execute(now, id int64, env Env) *decisions.Decision {
	if d := s.Ledger.Get(id); d != nil && d.Kind == KindRefund {
		panic("hlroute: decision " + itoa(id) + " is a refund: a refund is applied by GovDAO's own at-once decision (apply refund) after hlwatch's Solana check, never by Execute")
	}
	dec, err := s.Ledger.Due(id, now)
	if err != nil {
		panic("hlroute: " + err.Error())
	}
	if dec.Kind != KindMigrate {
		s.mustNotBeMigrated()
	}
	note := s.apply(dec, now, env)
	s.Ledger.Apply(dec, now, "applied after the delay"+note)
	return dec
}

// apply is a decision's effect, the same at once and after the delay; the checks a builder made are made again
// against the live state. It returns what the note should add ("" for nothing): what a list or a range skipped,
// what a sweep payment paid.
func (s *State) apply(dec *decisions.Decision, now int64, env Env) (note string) {
	switch p := dec.Params.(type) {
	case capFloorParams:
		if p.n < s.LaunchCapFloor || p.n/4 < s.Fee {
			panic("hlroute: below the launch floor, or a quarter below the fee, now")
		}
		s.CapFloor = p.n
	case maximumParams:
		if p.n < s.Minimum {
			panic("hlroute: the maximum never goes below the minimum")
		}
		s.Maximum = p.n
	case feeParams:
		if p.fee < s.FeeFloor || p.fee > s.CapFloor/4 || p.minimum <= 0 || p.minimum > s.Maximum {
			panic("hlroute: the fee is under the fee floor or above a quarter of the cap floor, or the minimum is out of range, now")
		}
		s.Fee, s.Minimum = p.fee, p.minimum
	case feeFloorParams:
		if p.n > s.Fee {
			panic("hlroute: the fee floor is above the fee now")
		}
		s.FeeFloor = p.n
	case routerParams:
		s.OldRouter, s.OldUntil = s.Router, now+decisions.Delay
		s.Router = p.router
	case VoidParams:
		// every credit the void can still take as it stands is voided; one it cannot — voided at once when the
		// proposal executed, or by another decision since, paid in full under a void as withheld, or gone — is
		// skipped and counted, the list form like the range form (R22)
		n, skipped := 0, 0
		last := int64(0)
		if p.Ranged {
			// the range as closed when the proposal was made, counted again against the cap (R28); the last height
			// voided goes into the note (R23)
			s.mustFitRange(p.Range)
			s.eachInRange(p.Range, func(c *Claim) bool {
				if voidable(c, p.Forged) {
					s.void(c, p.Forged)
					n++
					last = c.Height
				} else {
					skipped++
				}
				return false
			}, func(e *SweepEntry) bool {
				if sweepVoidable(e, p.Forged) {
					s.voidSweep(e)
					n++
					last = e.Height
				} else {
					skipped++
				}
				return false
			})
		} else {
			for _, id := range p.IDs {
				if e := s.SweepOf(id); e != nil {
					if sweepVoidable(e, p.Forged) {
						s.voidSweep(e)
						n++
					} else {
						skipped++
					}
					continue
				}
				if c := s.ClaimOf(id); c != nil && voidable(c, p.Forged) {
					s.void(c, p.Forged)
					n++
				} else {
					skipped++
				}
			}
		}
		note = "; " + strconv.Itoa(n) + " voided"
		if skipped > 0 {
			note += ", " + strconv.Itoa(skipped) + " skipped (not voidable as it stands)"
		}
		if p.Ranged && n > 0 {
			note += ", last voided at height " + itoa(last)
		}
	case restoreParams:
		// an id no longer voided (restored by another decision since) or gone is skipped and counted (R22); a
		// written-off send is lost no more (R38)
		n, skipped, undone := 0, 0, 0
		for _, id := range p.ids {
			if e := s.SweepOf(id); e != nil {
				if e.Voided {
					s.restoreSweep(e)
					n++
				} else {
					skipped++
				}
				continue
			}
			if sd := s.SendOf(id); sd != nil {
				if sd.WrittenOff != 0 {
					s.restoreWriteOff(sd)
					n++
					undone++
				} else {
					skipped++
				}
				continue
			}
			if c := s.ClaimOf(id); c != nil && (c.State == Withheld || c.State == Forged) {
				s.restore(c, now, env.Epoch())
				n++
			} else {
				skipped++
			}
		}
		note = "; " + strconv.Itoa(n) + " restored"
		switch undone {
		case 0:
		case 1:
			note += " (1 write-off undone: the send is lost no more)"
		default:
			note += " (" + strconv.Itoa(undone) + " write-offs undone: the sends are lost no more)"
		}
		if skipped > 0 {
			note += ", " + strconv.Itoa(skipped) + " skipped (not voided as it stands)"
		}
	case creditParams:
		s.creditByVote(now, p, env)
	case sweepParams:
		// the entries still live are paid as one sum and dropped (R19); one voided or gone since the proposal was
		// made is skipped; a sum the lock no longer covers waits
		sum, paid, skipped := int64(0), 0, 0
		for _, id := range p.ids {
			if e := s.SweepOf(id); e != nil && !e.Voided {
				sum += e.Amount
				paid++
			} else {
				skipped++
			}
		}
		if sum > s.Sweep {
			panic("hlroute: the entries sum to " + s.Amount(sum) + ", more than the sweep queue's balance of " + s.Amount(s.Sweep))
		}
		if sum > s.Lock {
			panic("hlroute: the lock (" + s.Amount(s.Lock) + ") holds less than the entries' " + s.Amount(sum) + " now")
		}
		for _, id := range p.ids {
			if e := s.SweepOf(id); e != nil && !e.Voided {
				s.sweeps.Remove(id)
				s.credits.Remove(heightKey(e.Height, e.ID))
			}
		}
		s.Sweep -= sum
		s.Owed -= sum
		s.PaidTotal += sum
		s.Lock -= sum
		if sum > 0 {
			env.Pay(p.to, sum)
		}
		note = "; " + strconv.Itoa(paid) + " entries paid (" + s.Amount(sum) + ")"
		if skipped > 0 {
			note += ", " + strconv.Itoa(skipped) + " skipped (voided or gone since the proposal was made)"
		}
	case refundParams:
		// kind 6's enrolment of this route is asked again (AR1: a later kind 6 restarts the wait); then the sends a
		// predecessor's page brought (AQ2) and still unrefunded are summed first: a sum the lock no longer covers
		// waits (R30), as a sweep payment's does; one refunded by another decision since the proposal was made, or
		// gone, is skipped and counted (R22)
		s.mustBeEnrolled(now, env)
		sum, n, skipped := int64(0), 0, 0
		for _, id := range p.ids {
			if sd := s.SendOf(id); sd != nil && sd.Imported && sd.Refunded == 0 {
				sum += sd.Amount
				n++
			} else {
				skipped++
			}
		}
		if sum > s.Lock {
			panic("hlroute: the lock (" + s.Amount(s.Lock) + ") holds less than the sends' " + s.Amount(sum) + " now")
		}
		for _, id := range p.ids {
			sd := s.SendOf(id)
			if sd == nil || !sd.Imported || sd.Refunded != 0 {
				continue
			}
			s.refund(id, sd, now)
			env.Pay(sd.From, sd.Amount)
		}
		note = "; " + strconv.Itoa(n) + " refunded"
		if skipped > 0 {
			note += ", " + strconv.Itoa(skipped) + " skipped (refunded already, or gone)"
		}
	case writeOffParams:
		// a refunded send still unmarked is written off, its amount lost and the identity closed by that much (AR1);
		// one written off by another decision since the proposal was made, never refunded, or gone is skipped (R22)
		sum, n, skipped := int64(0), 0, 0
		for _, id := range p.ids {
			if sd := s.SendOf(id); sd != nil && sd.Refunded != 0 && sd.WrittenOff == 0 {
				s.writeOff(sd, now)
				sum += sd.Amount
				n++
			} else {
				skipped++
			}
		}
		note = "; " + strconv.Itoa(n) + " written off (" + s.Amount(sum) + ")"
		if skipped > 0 {
			note += ", " + strconv.Itoa(skipped) + " skipped (written off already, never refunded, or gone)"
		}
	case migrateParams:
		// a re-point (AR2) passes the same checks as a first migrate; the mailbox replaces the registration
		s.mustAllowMigrate(p.to)
		s.mustMigrate(p.to, env)
		s.MigratedTo, s.MigratedAt = p.to, now
		env.AddRoute(p.to)
	default:
		panic("hlroute: decision " + itoa(dec.ID) + " has nothing to apply")
	}
	return note
}

// refund marks a send refunded now and takes its amount out of sentTotal and the lock (the realm pays it back): the
// mark is what send/<id>, refunds/<from> and the json's refunded count show, so the monitors drop the send from what
// is in flight (AQ2).
func (s *State) refund(id string, sd *Send, now int64) {
	sd.Refunded = now
	s.SentTotal -= sd.Amount
	s.Lock -= sd.Amount
	s.refunds.Set(id, true)
	s.nRefunded++
	s.refundedTotal += sd.Amount
}

// writeOff marks a refunded send delivered on Solana after its refund and books its amount as lost (AR1): the
// mark is what send/<id> and the json's writtenOff count show.
func (s *State) writeOff(sd *Send, now int64) {
	sd.WrittenOff = now
	s.Lost += sd.Amount
	s.nWrittenOff++
	s.writtenOffTotal += sd.Amount
}

// restoreWriteOff is writeOff's inverse (R38): the mark cleared, the amount back out of lost and the counters down,
// so the identity closes on the supply as it was before the mistaken write-off; the refund mark stays, and the
// send may be written off again.
func (s *State) restoreWriteOff(sd *Send) {
	sd.WrittenOff = 0
	s.Lost -= sd.Amount
	s.nWrittenOff--
	s.writtenOffTotal -= sd.Amount
}

// creditByVote credits an id by hand: a new claim for an id never done (marked done now); for an id whose claim
// stands voided, the voided record replaced by the recipient and amount GovDAO names at the back of that
// recipient's queue (what stood voided or lost for it is undone; what is owed moves by the new amount); for a
// sweep entry's id (R11), the entry dropped — its amount out of the sweep queue and of what is owed, unless a
// void took it already — and the claim queued in its place. The amount is at most the lock as it stands (R26).
func (s *State) creditByVote(now int64, p creditParams, env Env) {
	if p.amount > s.Lock {
		panic("hlroute: the amount " + s.Amount(p.amount) + " is above the lock of " + s.Amount(s.Lock) + " now")
	}
	if c := s.ClaimOf(p.id); c != nil {
		switch c.State {
		case Withheld:
			s.Voided -= c.Remaining()
		case Forged:
			s.Lost -= c.Paid
		default:
			panic("hlroute: " + p.id + " is credited already and not voided")
		}
		s.claims.Remove(p.id)
		s.credits.Remove(heightKey(c.Height, c.ID))
		s.nClaims--
		s.enqueue(now, env.Height(), env.Epoch(), p.id, p.to, p.amount, ByVote)
		return
	}
	if e := s.SweepOf(p.id); e != nil {
		if !e.Voided {
			if e.Amount > s.Sweep {
				panic("hlroute: " + e.ID + "'s " + s.Amount(e.Amount) + " exceeds the sweep queue's balance of " + s.Amount(s.Sweep))
			}
			s.Sweep -= e.Amount
			s.Owed -= e.Amount
		}
		s.sweeps.Remove(p.id)
		s.credits.Remove(heightKey(e.Height, e.ID))
		s.enqueue(now, env.Height(), env.Epoch(), p.id, p.to, p.amount, ByVote)
		return
	}
	if env.Delivered(p.id) {
		panic("hlroute: " + p.id + " is done already")
	}
	env.MarkDone(p.id)
	s.enqueue(now, env.Height(), env.Epoch(), p.id, p.to, p.amount, ByVote)
}

// -------------------------------------------------------------- migrate --

// Snapshot is one page of what a successor takes over: plain values it copies into its own state. Page 0 carries
// the counters; every page up to the page size of records.
type Snapshot struct {
	Page                                                int
	More                                                bool // records remain for the next page
	Lock, SentTotal, PaidTotal, Owed, Voided, Lost, Sweep int64
	Claims                                              []Claim
	Sweeps                                              []SweepItem
	Sends                                               []SendItem
}

type SweepItem struct {
	ID     string
	Amount int64
	Height int64
	By     string
	Voided bool
}

type SendItem struct {
	ID       string
	From     address
	Amount   int64
	At       int64
	Refunded   int64 // when it was refunded, 0 if not (R33): the mark goes with the record, so some realm always answers it
	WrittenOff int64 // when it was written off (AR1), 0 if not: the same
}

// Exported is how many pages went to the successor so far: the next Pull takes that page number.
func (s *State) Exported() int { return s.exported }

// Imported is how many of a predecessor's pages this route took in: 0 for a route that succeeded none.
func (s *State) Imported() int { return s.imported }

// MustHaveImported is the gate on a message the router addressed to this route's predecessor (AQ1): hlmailbox lets
// a successor take such a message — the burns name the predecessor until kind 6 enrolls the successor — and this
// route credits it only once the predecessor's last page is in: before page 0 the lock is not here (the credit
// would be swept as one above the lock), and between pages Credit refuses anyway. The message waits undelivered
// meanwhile and the relayer brings it again; after the last page it is an ordinary credit, done once in the shared
// mailbox. A route that succeeded none refuses such a message for good.
func (s *State) MustHaveImported() {
	if s.imported == 0 || s.importing {
		panic("hlroute: addressed to another realm: a successor takes its predecessor's messages once the last page of the migration is in (" + strconv.Itoa(s.imported) + " pages so far)")
	}
}

// MustTake is the gate on every incoming message, asked by the realm's Process before the mailbox is: toSelf is
// whether the message names this realm as its recipient, predecessor the route whose migrate registered this one
// (hlmailbox.Predecessor of the realm's own path, "" for a launch route). A route that succeeds another credits
// nothing before its predecessor's last page is in — a message addressed to itself included (R32, AR3): before
// page 0 the lock is not here, so an honest burn to the successor, which kind 6 may enroll the day the migrate
// applies, would be swept as one above the lock, owed and paying nobody until a sweep payment by vote — so every
// message waits undelivered meanwhile and the relayer brings it again. A message addressed to another realm is a
// predecessor's (MustHaveImported): taken once the last page is in, refused for good by a route that succeeded
// none. A launch route takes its own as it always did.
func (s *State) MustTake(toSelf bool, predecessor string) {
	if !toSelf {
		s.MustHaveImported()
		return
	}
	if predecessor != "" && (s.imported == 0 || s.importing) {
		panic("hlroute: this route succeeds " + predecessor + ": nothing is credited before the last page of the migration is in (" + strconv.Itoa(s.imported) + " pages so far)")
	}
}

// MustSend is the gate on a send, asked by the realm's TransferRemote before anything moves (R35, F28; AT7): a route
// that succeeds another takes no send before its predecessor's last page is in — the mirror of MustTake — nor
// before r/hlgov has dispatched the kind 6 enrolling it as the token's router on Solana (Env.Enrolled: the note
// the kind-6 closure leaves with the mailbox, cleared by a cancel). Before page 0 nothing has moved, so the
// migration may still be re-pointed (AR2) and this realm dropped: a send through it would lock the sender's coins
// in a realm Solana never enrols (kind 6 waits for page 0), which cannot refund them (its own send, never a
// refund's) and cannot migrate (a route no more) — stranded for good. Between pages the lock is only partly here
// and Credit refuses anyway; a send waits for the last page as a credit does. After the last page and before the
// kind 6, the token program refuses a sender that is not its enrolled router, so every send would park on Solana
// until a kind 6 lands — weeks under a hold, never if GovDAO cancels it — unrefundable as the route's own (§5.3:
// a live route's stranded send waits for a kind 12, since a refund voids nothing on Solana); with the note in, a
// send parks a week at most (the kind 6's own clock there; a hold defers it, the guardians' sends flag the brake).
// A launch route sends as it always did: the setup step enrolled it, and no kind 6 ever notes it.
func (s *State) MustSend(predecessor string, env Env) {
	if predecessor == "" {
		return
	}
	if s.imported == 0 || s.importing {
		panic("hlroute: this route succeeds " + predecessor + ": nothing is sent before the last page of the migration is in (" + strconv.Itoa(s.imported) + " pages so far)")
	}
	if h, _ := env.Enrolled(); h == 0 {
		panic("hlroute: this route succeeds " + predecessor + ": nothing is sent before r/hlgov has dispatched the kind 6 enrolling this realm as the token's router on Solana (no enrolment note yet): a send before it would park there until a kind 6 lands, unrefundable as the route's own")
	}
}

// Importing is whether a predecessor's pages are still arriving: from page 0's import until the page that says no
// more follows (AP4). A successor's adopt loop reads it to know when it is done.
func (s *State) Importing() bool { return s.importing }

// Export hands the state to the successor a page at a time (R13): page 0 carries the counters (the realm pays the
// lock with it) and every page up to size records — the claims first, every claim ever credited (open, voided and
// paid, so a void or a restore reaches them on the successor, R12), then the sweep entries, then the sends, a
// refunded one with its mark (R33: the monitors drop a refunded send from what is in flight by the realm that
// answers send/<id> for it, so the record is never dropped; the refund counters follow it) — each leaving this
// state as it goes, so a page outgrows no block however long the route ran. The pages go in order; a page handed
// over already exports nothing (and the realm pays nothing). Only after a migrate decision applied.
func (s *State) Export(page, size int) *Snapshot {
	if !s.Migrated() {
		panic("hlroute: no migrate decision applied")
	}
	if page < 0 || page > s.exported {
		panic("hlroute: page " + strconv.Itoa(s.exported) + " is the next to pull, not " + strconv.Itoa(page))
	}
	snap := &Snapshot{Page: page}
	if page < s.exported {
		return snap
	}
	if size < 1 {
		panic("hlroute: a page holds at least one record")
	}
	if page == 0 {
		snap.Lock, snap.SentTotal, snap.PaidTotal, snap.Owed, snap.Voided, snap.Lost, snap.Sweep = s.Lock, s.SentTotal, s.PaidTotal, s.Owed, s.Voided, s.Lost, s.Sweep
		s.Lock, s.SentTotal, s.PaidTotal, s.Owed, s.Voided, s.Lost, s.Sweep = 0, 0, 0, 0, 0, 0, 0
	}
	n := 0
	var keys []string
	s.claims.Iterate("", "", func(k string, v any) bool {
		c := *v.(*Claim)
		// the recipient's counter is final (nothing credits here after the migrate decision): the successor raises
		// its own to it on first seeing the recipient (R20)
		c.QueueNext = s.queues.Get(string(c.To)).(*Queue).next
		snap.Claims = append(snap.Claims, c)
		keys = append(keys, k)
		n++
		return n >= size
	})
	for _, k := range keys {
		c := s.claims.Get(k).(*Claim)
		if c.State == Open {
			s.dequeue(c, s.queues.Get(string(c.To)).(*Queue))
			s.nOpen--
		}
		s.claims.Remove(k)
		s.credits.Remove(heightKey(c.Height, c.ID))
		s.nClaims--
	}
	keys = nil
	if n < size {
		s.sweeps.Iterate("", "", func(k string, v any) bool {
			e := v.(*SweepEntry)
			snap.Sweeps = append(snap.Sweeps, SweepItem{e.ID, e.Amount, e.Height, e.By, e.Voided})
			keys = append(keys, k)
			n++
			return n >= size
		})
		for _, k := range keys {
			e := s.sweeps.Get(k).(*SweepEntry)
			s.sweeps.Remove(k)
			s.credits.Remove(heightKey(e.Height, e.ID))
		}
		keys = nil
	}
	if n < size {
		s.sends.Iterate("", "", func(k string, v any) bool {
			sd := v.(*Send)
			snap.Sends = append(snap.Sends, SendItem{ID: k, From: sd.From, Amount: sd.Amount, At: sd.At, Refunded: sd.Refunded, WrittenOff: sd.WrittenOff})
			keys = append(keys, k)
			n++
			return n >= size
		})
		for _, k := range keys {
			sd := s.sends.Get(k).(*Send)
			if sd.Refunded != 0 {
				s.nRefunded--
				s.refundedTotal -= sd.Amount
			}
			if sd.WrittenOff != 0 {
				s.nWrittenOff--
				s.writtenOffTotal -= sd.Amount
			}
			s.sends.Remove(k)
			s.refunds.Remove(k)
		}
	}
	snap.More = s.claims.Size() > 0 || s.sweeps.Size() > 0 || s.sends.Size() > 0
	if n > 0 || page == 0 {
		s.exported++
	}
	return snap
}

// Import takes a page of a predecessor's snapshot into this state: the counters add (page 0 carries them), the
// claims keep their ids, states and order — a recipient's queue places every imported claim at a base plus its
// old seq, and its counter is raised to the predecessor's final one on first seeing the recipient (R20), so this
// route's own credits land above every place a later page can claim — the open ones queued, the voided and paid
// ones kept as records, the sweep entries and the sends as they were, a refunded send with its mark, in the
// refunds index and counted (R33). The pages go in order, each once; from the first to the one that says no
// more follows, Credit refuses (AP4). epoch is this route's payouts epoch now: the queues it makes start there.
// Page 0 empties the bridge meter and every quarter as of now and takes launchedAt — hlmailbox's launch time —
// as the launch the meters were last emptied for (R34): a successor starts with empty meters, as a launch route
// does at Launch and every route after an unpause, and its first Claim applies no launch reset, which rewound
// every meter to the launch, months back, and filled them all at once — a third cap in the 24 hours the
// predecessor closed. The queues a later page makes start empty at their first claim, as every queue does.
func (s *State) Import(now, epoch, launchedAt int64, snap *Snapshot) {
	s.mustNotBeMigrated()
	if snap.Page != s.imported {
		panic("hlroute: page " + strconv.Itoa(s.imported) + " is the next to import, not " + strconv.Itoa(snap.Page))
	}
	if snap.Page == 0 {
		s.ResetMeters(now)
		s.LaunchSeen = launchedAt
	}
	s.imported++
	s.importing = snap.More
	s.Lock += snap.Lock
	s.SentTotal += snap.SentTotal
	s.PaidTotal += snap.PaidTotal
	s.Owed += snap.Owed
	s.Voided += snap.Voided
	s.Lost += snap.Lost
	s.Sweep += snap.Sweep
	for _, c := range snap.Claims {
		if s.claims.Has(c.ID) {
			panic("hlroute: a claim with id " + c.ID + " exists")
		}
		q := s.queue(c.To, now, epoch)
		if !q.imported {
			q.imported, q.base = true, q.next
			if top := q.base + c.QueueNext; top > q.next {
				q.next = top
			}
		}
		nc := &Claim{ID: c.ID, To: c.To, Amount: c.Amount, Paid: c.Paid, At: c.At, Height: c.Height, By: c.By, State: c.State, Seq: q.base + c.Seq}
		if nc.Seq > q.next {
			q.next = nc.Seq
		}
		s.claims.Set(c.ID, nc)
		s.credits.Set(heightKey(c.Height, c.ID), c.ID)
		s.nClaims++
		if c.State == Open {
			if q.items.Has(seqKey(nc.Seq)) {
				panic("hlroute: a claim at place " + itoa(nc.Seq) + " of " + string(c.To) + "'s queue exists")
			}
			q.items.Set(seqKey(nc.Seq), c.ID)
			s.nOpen++
			s.waiting.Set(string(c.To), true)
		}
	}
	for _, it := range snap.Sweeps {
		if s.sweeps.Has(it.ID) {
			panic("hlroute: a sweep entry with id " + it.ID + " exists")
		}
		s.sweeps.Set(it.ID, &SweepEntry{ID: it.ID, Amount: it.Amount, Height: it.Height, By: it.By, Voided: it.Voided})
		s.credits.Set(heightKey(it.Height, it.ID), it.ID)
	}
	for _, it := range snap.Sends {
		if s.sends.Has(it.ID) {
			panic("hlroute: a send with id " + it.ID + " exists")
		}
		s.sends.Set(it.ID, &Send{From: it.From, Amount: it.Amount, At: it.At, Refunded: it.Refunded, WrittenOff: it.WrittenOff, Imported: true})
		if it.Refunded != 0 {
			s.refunds.Set(it.ID, true)
			s.nRefunded++
			s.refundedTotal += it.Amount
		}
		if it.WrittenOff != 0 {
			s.nWrittenOff++
			s.writtenOffTotal += it.Amount
		}
	}
}

// ---------------------------------------------------------------- pages --

// meterView is the bridge meter as a reader sees it now: a copy, refilled, with the launch reset the next Claim
// will apply (§5.4: the meters start empty at Launch; launchedAt is hlmailbox's, 0 before the launch) applied
// first, so the page and hlwatch never show a full meter that Claim would then empty (K22).
func (s *State) meterView(now, epoch, epochAt, launchedAt int64) Meter {
	m := s.meter
	if launchedAt != 0 && launchedAt != s.LaunchSeen {
		m.Level, m.At, m.Frac = 0, launchedAt, 0
	}
	dayCap := s.Cap()
	m.refill(now, dayCap, dayCap, epoch, epochAt)
	return m
}

// Figures is the realm's page body: the settings, the identity and the queues. launchedAt is hlmailbox's launch
// time (the meter is shown as the launch reset leaves it until the first Claim applies the reset).
func (s *State) Figures(now int64, epoch, epochAt, launchedAt int64, paused string) string {
	var b strings.Builder
	dayCap := s.Cap()
	m := s.meterView(now, epoch, epochAt, launchedAt)
	b.WriteString("- lock: " + s.Amount(s.Lock) + " (sent " + s.Amount(s.SentTotal) + ", paid " + s.Amount(s.PaidTotal) + ")\n")
	b.WriteString("- owed: " + s.Amount(s.Owed) + " in " + itoa(s.nOpen) + " open claims (the sweep queue " + s.Amount(s.Sweep) + " included); voided " + s.Amount(s.Voided) + "; lost " + s.Amount(s.Lost) + "\n")
	b.WriteString("- identity: lock = sentTotal − paidTotal = supply + owed + voided − lost, so the supply on Solana should be " + s.Amount(s.Lock-s.Owed-s.Voided+s.Lost) + " up to messages in flight\n")
	b.WriteString("- day cap: " + s.Amount(dayCap) + " (floor " + s.Amount(s.CapFloor) + ", a tenth of the lock otherwise); the bridge meter holds " + s.Amount(m.Level) + " now; a recipient's meter holds a quarter at most\n")
	b.WriteString("- fee " + s.Amount(s.Fee) + " (floor " + s.Amount(s.FeeFloor) + "); minimum " + s.Amount(s.Minimum) + "; per-message maximum " + s.Amount(s.Maximum) + "\n")
	b.WriteString("- " + decisions.Clocks() + "; the old router's window after a swap is the 7-day delay\n")
	b.WriteString("- router on domain " + strconv.FormatUint(uint64(s.Domain), 10) + ": `" + hex.EncodeToString(s.Router[:]) + "`")
	if s.OldUntil > now {
		b.WriteString(" (the old router `" + hex.EncodeToString(s.OldRouter[:]) + "` accepted until " + itoa(s.OldUntil) + ")")
	}
	b.WriteString("\n")
	if paused != "" {
		b.WriteString("- **paused**: " + paused + "\n")
	}
	if s.Migrated() {
		b.WriteString("- **migrated** to `" + s.MigratedTo + "` at " + itoa(s.MigratedAt) + ": every function refuses\n")
	}
	if s.importing {
		b.WriteString("- **importing**: a predecessor's pages are arriving (" + strconv.Itoa(s.imported) + " so far); credits are refused until the last page is in\n")
	}
	writtenOff := ""
	if s.nWrittenOff > 0 {
		writtenOff = ", written off " + itoa(s.nWrittenOff) + " (" + s.Amount(s.writtenOffTotal) + ")"
	}
	b.WriteString("- claims ever: " + itoa(s.nClaims) + "; sends recorded: " + itoa(int64(s.sends.Size())) + ", refunded " + itoa(s.nRefunded) + " (" + s.Amount(s.refundedTotal) + ")" + writtenOff + "; decisions: " + itoa(s.Ledger.Last()) + "\n")
	// the count is the counter, never a walk of every waiting recipient (R24): the page stays within a query's gas
	// under a flood of claims to fresh addresses; nOpen and the walk agree (R12)
	if total := int(s.nOpen); total > 0 {
		b.WriteString("\n## Waiting claims\n\n")
		listed := 0
		s.eachWaiting(func(to string, pos int, c *Claim) bool {
			b.WriteString("- " + to + " #" + strconv.Itoa(pos) + ": " + s.Amount(c.Remaining()) + " of " + s.Amount(c.Amount) + " " + c.State + " (" + c.By + ") at height " + itoa(c.Height) + " `" + c.ID + "`\n")
			listed++
			return listed >= PageLines
		})
		if rest := total - listed; rest > 0 {
			b.WriteString("- … and " + strconv.Itoa(rest) + " more (" + strconv.Itoa(total) + " waiting): the whole list, by hundreds, at claims/0, claims/" + strconv.Itoa(PageLines) + ", …\n")
		}
	}
	if total := s.sweeps.Size(); total > 0 {
		b.WriteString("\n## Sweep queue\n\n")
		s.sweeps.IterateByOffset(0, PageLines, func(_ string, v any) bool {
			b.WriteString("- " + s.sweepLine(v.(*SweepEntry)) + "\n")
			return false
		})
		if rest := total - PageLines; rest > 0 {
			b.WriteString("- … and " + strconv.Itoa(rest) + " more (" + strconv.Itoa(total) + " entries): the whole queue, by hundreds, at sweeps/0, sweeps/" + strconv.Itoa(PageLines) + ", …\n")
		}
	}
	return b.String()
}

// sweepLine is one sweep entry on the page.
func (s *State) sweepLine(e *SweepEntry) string {
	line := s.Amount(e.Amount) + " `" + e.ID + "` (" + e.By + ") at height " + itoa(e.Height)
	if e.Voided {
		line += ", voided as forged"
	}
	return line
}

// eachWaiting walks every open claim in the queues in the page's order (recipients by address, each queue oldest
// first) until fn returns true; pos is the claim's place in its recipient's queue, from 1. It walks the ring of
// recipients with an open claim, never a queue emptied by payouts or voids (R13).
func (s *State) eachWaiting(fn func(to string, pos int, c *Claim) bool) {
	s.waiting.Iterate("", "", func(k string, _ any) bool {
		q := s.queues.Get(k).(*Queue)
		pos, stop := 0, false
		q.items.Iterate("", "", func(_ string, idv any) bool {
			c := s.claims.Get(idv.(string)).(*Claim)
			pos++
			stop = fn(k, pos, c)
			return stop
		})
		return stop
	})
}

// waitingCount is how many open claims sit in the queues, by a walk of every waiting recipient: the tests' check
// of nOpen (R12's invariant); no page uses it (R24).
func (s *State) waitingCount() int {
	n := 0
	s.waiting.Iterate("", "", func(k string, _ any) bool {
		n += s.queues.Get(k).(*Queue).items.Size()
		return false
	})
	return n
}

// ClaimsPage is up to PageLines waiting claims from the from-th on (from 0), in the page's order, as a JSON array
// of ClaimJSON's objects; "[]" past the end.
func (s *State) ClaimsPage(from int) string {
	var b strings.Builder
	b.WriteString("[")
	i, n := 0, 0
	if from >= 0 {
		s.eachWaiting(func(_ string, _ int, c *Claim) bool {
			if i >= from {
				if n > 0 {
					b.WriteString(",")
				}
				b.WriteString(claimJSON(c))
				n++
			}
			i++
			return n >= PageLines
		})
	}
	b.WriteString("]")
	return b.String()
}

// SweepsPage is up to PageLines sweep entries from the from-th on (from 0), by id, as a JSON array of
// {"id","swept"}; "[]" past the end.
func (s *State) SweepsPage(from int) string {
	var b strings.Builder
	b.WriteString("[")
	n := 0
	if from >= 0 {
		s.sweeps.IterateByOffset(from, PageLines, func(_ string, v any) bool {
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(sweptJSON(v.(*SweepEntry)))
			n++
			return false
		})
	}
	b.WriteString("]")
	return b.String()
}

// JSON is the figures for the agents; launchedAt as Figures takes it.
func (s *State) JSON(now int64, epoch, epochAt, launchedAt int64) string {
	dayCap := s.Cap()
	m := s.meterView(now, epoch, epochAt, launchedAt)
	return "\"symbol\":" + strconv.Quote(s.Symbol) + ",\"domain\":" + strconv.FormatUint(uint64(s.Domain), 10) +
		",\"router\":" + strconv.Quote(hex.EncodeToString(s.Router[:])) + ",\"oldRouter\":" + strconv.Quote(hex.EncodeToString(s.OldRouter[:])) + ",\"oldUntil\":" + itoa(s.OldUntil) +
		",\"lock\":" + itoa(s.Lock) + ",\"sentTotal\":" + itoa(s.SentTotal) + ",\"paidTotal\":" + itoa(s.PaidTotal) +
		",\"owed\":" + itoa(s.Owed) + ",\"voided\":" + itoa(s.Voided) + ",\"lost\":" + itoa(s.Lost) + ",\"sweep\":" + itoa(s.Sweep) +
		",\"cap\":" + itoa(dayCap) + ",\"meter\":" + itoa(m.Level) + ",\"capFloor\":" + itoa(s.CapFloor) +
		",\"fee\":" + itoa(s.Fee) + ",\"feeFloor\":" + itoa(s.FeeFloor) + ",\"minimum\":" + itoa(s.Minimum) + ",\"maximum\":" + itoa(s.Maximum) +
		",\"openClaims\":" + itoa(s.nOpen) + ",\"claims\":" + itoa(s.nClaims) + ",\"sends\":" + itoa(int64(s.sends.Size())) +
		",\"refunded\":" + itoa(s.nRefunded) + ",\"refundedTotal\":" + itoa(s.refundedTotal) +
		",\"writtenOff\":" + itoa(s.nWrittenOff) + ",\"writtenOffTotal\":" + itoa(s.writtenOffTotal) +
		",\"migratedTo\":" + strconv.Quote(s.MigratedTo) + ",\"importing\":" + strconv.FormatBool(s.importing) + ",\"imported\":" + strconv.Itoa(s.imported) +
		",\"clocks\":" + decisions.ClocksJSON() + ",\"decisions\":" + itoa(s.Ledger.Last())
}

// SendJSON is one send by id — {"id","from","amount","at","imported","refunded","writtenOff"}: "refunded" the unix
// time it was, 0 if not, "writtenOff" the unix time it was written off as delivered on Solana after its refund
// (AR1), 0 if not, and "imported" whether a predecessor's page brought it (the only sends a refund may name, AQ2)
// — or "null".
func (s *State) SendJSON(id string) string {
	cid, err := CleanID(id)
	if err != nil {
		return "null"
	}
	sd := s.SendOf(cid)
	if sd == nil {
		return "null"
	}
	return sendJSON(cid, sd)
}

func sendJSON(id string, sd *Send) string {
	return "{\"id\":" + strconv.Quote(id) + ",\"from\":" + strconv.Quote(string(sd.From)) + ",\"amount\":" + itoa(sd.Amount) + ",\"at\":" + itoa(sd.At) +
		",\"imported\":" + strconv.FormatBool(sd.Imported) + ",\"refunded\":" + itoa(sd.Refunded) + ",\"writtenOff\":" + itoa(sd.WrittenOff) + "}"
}

// RefundsPage is up to PageLines sends refunded here from the from-th on (from 0), by id, as a JSON array of
// SendJSON's objects: what the monitors read to drop a refunded send from what is in flight (AQ2); "[]" past the
// end.
func (s *State) RefundsPage(from int) string {
	var b strings.Builder
	b.WriteString("[")
	n := 0
	if from >= 0 {
		s.refunds.IterateByOffset(from, PageLines, func(k string, _ any) bool {
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(sendJSON(k, s.sends.Get(k).(*Send)))
			n++
			return false
		})
	}
	b.WriteString("]")
	return b.String()
}

// ClaimJSON is one claim by id, or the sweep entry under that id, or "null".
func (s *State) ClaimJSON(id string) string {
	cid, err := CleanID(id)
	if err != nil {
		return "null"
	}
	c := s.ClaimOf(cid)
	if c == nil {
		if e := s.SweepOf(cid); e != nil {
			return sweptJSON(e)
		}
		return "null"
	}
	return claimJSON(c)
}

func claimJSON(c *Claim) string {
	return "{\"id\":" + strconv.Quote(c.ID) + ",\"to\":" + strconv.Quote(string(c.To)) + ",\"amount\":" + itoa(c.Amount) + ",\"paid\":" + itoa(c.Paid) +
		",\"state\":" + strconv.Quote(c.State) + ",\"by\":" + strconv.Quote(c.By) + ",\"at\":" + itoa(c.At) + ",\"height\":" + itoa(c.Height) + ",\"seq\":" + itoa(c.Seq) + "}"
}

// sweptJSON is a sweep entry: {"id","swept","height","by","voided"} ("swept" is the amount, as the agents read it).
func sweptJSON(e *SweepEntry) string {
	return "{\"id\":" + strconv.Quote(e.ID) + ",\"swept\":" + itoa(e.Amount) + ",\"height\":" + itoa(e.Height) + ",\"by\":" + strconv.Quote(e.By) + ",\"voided\":" + strconv.FormatBool(e.Voided) + "}"
}
