package mandate

import (
	"chain"
	"strconv"
)

// fanout is the number of entries per chunk, and of chunks per super-chunk.
const fanout = 32

// fixedList is an append-only list of strings of one fixed width, in two
// levels of chunks. It holds values, never pointers to shared objects (on
// chain, rewriting an array costs about 0.37M gas for every pointer to a
// shared object it holds; docs/notes.md), and no array in it grows with the
// list's length except supers, by one entry per fanout*fanout appends:
//   - tail: the newest N % fanout entries, inside the owner object;
//   - when tail is full it becomes a chunk, appended to the last
//     super-chunk (at most fanout chunks each);
//   - supers: the list of super-chunks.
//
// So an append rewrites the owner and its tail; every fanout appends it also
// creates a chunk and rewrites one super-chunk (at most fanout pointers to
// objects that only it holds); every fanout*fanout appends it rewrites
// supers. set replaces an entry in place with one of the same width, so it
// never changes the storage size. Appends happen only in transactions signed
// with someone's own key (Subscribe, Offer), never under a session budget.
type fixedList struct {
	N      int
	tail   []string      // the newest N % fanout entries
	supers []*superChunk // full chunks, fanout per super-chunk, oldest first
}

type superChunk struct {
	chunks []*strChunk
}

type strChunk struct {
	items []string
}

func (l *fixedList) add(s string) {
	l.tail = append(l.tail, s)
	l.N++
	if len(l.tail) < fanout {
		return
	}
	c := &strChunk{items: l.tail}
	l.tail = nil
	if n := len(l.supers); n == 0 || len(l.supers[n-1].chunks) == fanout {
		l.supers = append(l.supers, &superChunk{chunks: []*strChunk{c}})
		return
	}
	sc := l.supers[len(l.supers)-1]
	sc.chunks = append(sc.chunks, c)
}

// at returns entry i (0 = oldest).
func (l *fixedList) at(i int) string {
	c := i / fanout
	if c < l.N/fanout {
		return l.supers[c/fanout].chunks[c%fanout].items[i%fanout]
	}
	return l.tail[i%fanout]
}

// set replaces entry i with s, which must have the same width.
func (l *fixedList) set(i int, s string) {
	c := i / fanout
	if c < l.N/fanout {
		l.supers[c/fanout].chunks[c%fanout].items[i%fanout] = s
		return
	}
	l.tail[i%fanout] = s
}

// Supporter entries: the payer's 40-character address, the mandate id
// padded to 10 digits, and one status character. Pull flips '0' to '1' at
// a mandate's first payment and Cancel sets 'x', both in place.
const (
	statusUnpaid    = '0'
	statusPaid      = '1'
	statusCancelled = 'x'
	entryWidth      = 40 + 10 + 1
)

// entry is a decoded supporter entry.
type entry struct {
	Payer  address
	ID     uint64 // mandate id
	Status byte
}

func encodeEntry(payer address, id uint64, status byte) string {
	return payer.String() + pad(id) + string(status)
}

func decodeEntry(s string) entry {
	id, _ := strconv.ParseUint(s[40:50], 10, 64)
	return entry{Payer: address(s[:40]), ID: id, Status: s[50]}
}

// setStatus rewrites the status character of entry i (same width).
func (l *fixedList) setStatus(i int, status byte) {
	s := l.at(i)
	l.set(i, s[:50]+string(status))
}

// activeMandate returns the mandate an entry names if it is still in its
// payer's active list (cancelled and replaced ones are not), or nil. It may
// have expired: callers check isActive.
func activeMandate(e entry) *Mandate {
	if pr := payerOf(e.Payer); pr != nil {
		for _, r := range pr.Active {
			if r.ID == e.ID {
				return r.M
			}
		}
	}
	return nil
}

// MaxActivePerPayer is how many active mandates one payer may hold: the
// chain allows 16 sessions per account (tm2 std.MaxSessionsPerAccount), and
// each active mandate needs its own session key.
const MaxActivePerPayer = MaxSessionsPerWallet

// Payer holds one payer's own lookups and nothing of anyone else's, so no
// address can make another payer's Pull, Subscribe or Cancel read or write
// more than the payer tree's depth.
//   - Active: the payer's current mandates, at most MaxActivePerPayer that
//     are not expired. Cancel removes an entry at once; an expired entry is
//     removed at the payer's next Subscribe. Each entry carries the session
//     address and plan id inline, so finding a mandate reads one small array
//     and loads only the mandate found.
//   - Head: the payer's newest mandate; older ones follow through
//     prevOfPayer (history, walked only by free reads).
//   - Credits: time the payer has paid for on a plan where they no longer
//     have an active mandate (cancelled by either side, or expired and
//     pruned), at most MaxCreditsPerPayer, each still in the future. A new
//     mandate for that plan starts when the credit ends, so paid time is
//     not lost or charged twice, unless 16 credits are already held (see
//     MaxCreditsPerPayer for who can then lose what).
type Payer struct {
	Active  []activeRef
	Head    *Mandate
	Credits []credit
}

// credit is paid time kept for a plan: the payer is covered until Until.
type credit struct {
	PlanID uint64
	Until  int64
}

// MaxCreditsPerPayer bounds a payer's kept credits: 16 plans left while
// each is still paid ahead. At the bound, the payer's own Cancel or expiry
// lets the credit ending soonest give way to a later one (that plan's time
// is lost); a payee's Cancel never evicts: its new credit is not kept.
const MaxCreditsPerPayer = 16

type activeRef struct {
	Session address
	PlanID  uint64
	ID      uint64 // mandate id, so a supporter entry resolves without loading mandates
	M       *Mandate
}

// payerOf returns a copy of the payer's record, or nil. Records are stored
// by value (no heap item, about 400 bytes less per payer); after changing
// one, write it back with save.
func payerOf(a address) *Payer {
	v := payers.Get(a.String())
	if v == nil {
		return nil
	}
	pr := v.(Payer)
	return &pr
}

func (pr *Payer) save(a address) { payers.Set(a.String(), *pr) }

// activeBySession returns the payer's active-list mandate for this session
// key (it may have expired but not been pruned yet), or nil.
func activeBySession(payer, sess address) *Mandate {
	if pr := payerOf(payer); pr != nil {
		for _, r := range pr.Active {
			if r.Session == sess {
				return r.M
			}
		}
	}
	return nil
}

// activeByPlan returns the payer's active-list mandate for the plan, or nil.
func activeByPlan(payer address, planID uint64) *Mandate {
	if pr := payerOf(payer); pr != nil {
		for _, r := range pr.Active {
			if r.PlanID == planID {
				return r.M
			}
		}
	}
	return nil
}

// removeActive drops m's entry from the payer's active list.
func (pr *Payer) removeActive(m *Mandate) {
	out := make([]activeRef, 0, len(pr.Active))
	for _, r := range pr.Active {
		if r.M != m {
			out = append(out, r)
		}
	}
	pr.Active = out
}

// pruneExpired drops expired entries from the active list (payer is the
// record's owner, for events). The paid time of an expired mandate for
// planID, the plan being subscribed to, is returned directly, so nothing in
// the same prune can evict it; every other expired mandate's paid time is
// kept as a credit for its plan.
func (pr *Payer) pruneExpired(payer address, planID uint64, now int64) int64 {
	keep := 0
	for _, r := range pr.Active {
		if r.M.isActive(now) {
			keep++
		}
	}
	if keep == len(pr.Active) {
		return 0
	}
	var own int64
	out := make([]activeRef, 0, keep)
	for _, r := range pr.Active {
		if r.M.isActive(now) {
			out = append(out, r)
			continue
		}
		var kept int64
		if r.PlanID == planID {
			if t := r.M.paidThrough(); t > now {
				own, kept = t, t
			}
		} else {
			kept = pr.keepCredit(payer, r.PlanID, r.M.paidThrough(), now, true)
		}
		chain.Emit("MandatePruned",
			"mandate", utoa(r.ID),
			"plan", utoa(r.PlanID),
			"payer", payer.String(),
			"kept", itoa(kept),
		)
	}
	pr.Active = out
	return own
}

// pruneCredits drops credits that have run out.
func (pr *Payer) pruneCredits(now int64) {
	keep := 0
	for _, c := range pr.Credits {
		if c.Until > now {
			keep++
		}
	}
	if keep == len(pr.Credits) {
		return
	}
	out := make([]credit, 0, keep)
	for _, c := range pr.Credits {
		if c.Until > now {
			out = append(out, c)
		}
	}
	pr.Credits = out
}

// keepCredit records that the payer is paid on the plan until `until`
// (nothing if that is not in the future). One credit per plan, the later
// time wins. At MaxCreditsPerPayer: with evict (the payer's own Cancel, or
// the expiry prune at the payer's own Subscribe), the credit ending soonest
// gives way if this one ends later; without evict (a payee's Cancel), this
// one is not kept, so no third party can remove a credit the payer holds.
//
// It returns the time kept (0 if none) and emits CreditDropped for a credit
// it pushes out.
func (pr *Payer) keepCredit(payer address, planID uint64, until, now int64, evict bool) int64 {
	if until <= now {
		return 0
	}
	pr.pruneCredits(now)
	// A plan has a credit only while the payer has no active mandate for it
	// (Subscribe uses it up), so this is a guard, not a path taken today.
	for i := range pr.Credits {
		if pr.Credits[i].PlanID == planID {
			if until > pr.Credits[i].Until {
				pr.Credits[i] = credit{PlanID: planID, Until: until}
			}
			return pr.Credits[i].Until
		}
	}
	if len(pr.Credits) < MaxCreditsPerPayer {
		pr.Credits = append(pr.Credits, credit{PlanID: planID, Until: until})
		return until
	}
	if !evict {
		return 0
	}
	soonest := 0
	for i := range pr.Credits {
		if pr.Credits[i].Until < pr.Credits[soonest].Until {
			soonest = i
		}
	}
	if until <= pr.Credits[soonest].Until {
		return 0
	}
	chain.Emit("CreditDropped",
		"payer", payer.String(),
		"plan", utoa(pr.Credits[soonest].PlanID),
		"until", itoa(pr.Credits[soonest].Until),
	)
	pr.Credits[soonest] = credit{PlanID: planID, Until: until}
	return until
}

// creditFor returns until when a kept credit covers the payer on the plan,
// or 0. For reads; it changes nothing.
func (pr *Payer) creditFor(planID uint64, now int64) int64 {
	for _, c := range pr.Credits {
		if c.PlanID == planID && c.Until > now {
			return c.Until
		}
	}
	return 0
}

// takeCredit removes the plan's credit and returns until when it covered
// the payer, or 0 if there was none still in the future.
func (pr *Payer) takeCredit(planID uint64, now int64) int64 {
	pr.pruneCredits(now)
	for i, c := range pr.Credits {
		if c.PlanID == planID {
			out := make([]credit, 0, len(pr.Credits)-1)
			out = append(out, pr.Credits[:i]...)
			pr.Credits = append(out, pr.Credits[i+1:]...)
			return c.Until
		}
	}
	return 0
}

// latestBySession returns the payer's newest mandate for this session key,
// active or not, walking the history when it is no longer active. For free
// reads only.
func latestBySession(payer, sess address) *Mandate {
	if m := activeBySession(payer, sess); m != nil {
		return m
	}
	if pr := payerOf(payer); pr != nil {
		for m := pr.Head; m != nil; m = m.prevOfPayer {
			if m.Session == sess {
				return m
			}
		}
	}
	return nil
}

// payerHead returns the payer's newest mandate.
func payerHead(payer address) *Mandate {
	if pr := payerOf(payer); pr != nil {
		return pr.Head
	}
	return nil
}
