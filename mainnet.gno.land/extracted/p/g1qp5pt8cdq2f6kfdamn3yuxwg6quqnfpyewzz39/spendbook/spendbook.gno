// Package spendbook is a pure allowance primitive for realms that need to
// let one party spend another party's funds, up to a bounded amount, over
// many transactions. It is to *delegated spending* what duebook is to
// *time*: it holds no coins, performs no effects, imports no chain APIs,
// and owns no package-level state. The importing realm owns a *Book,
// supplies the clock, and performs its own effects.
//
// # Why this package exists
//
// The ecosystem's existing allowance primitive,
// gno.land/p/jaekwon/allowancesender/v0, is scoped to a single call and
// says so in its own documentation:
//
//	"Allowance survives across N txs but not N+1 txs." Use a session
//	counter pattern in the granter realm; this package's Close is
//	binary, not deadline-based.
//
// It then declines block-height expiry on the grounds that it "would
// require runtime cooperation". That is true only for a package that reads
// the clock itself. spendbook does not: every operation takes `now` as an
// argument, which makes the window arithmetic a pure function and the
// whole package unit-testable without a chain. Three application realms in
// the searched sources each hand-rolled this mechanism internally rather
// than importing one; see DISCOVERY.md.
//
// # The one idea
//
// An allowance is not a balance. It is a *permission with a ceiling that
// refills*. The owner says "this spender may draw at most PerPeriod per
// window, at most Total ever, until ExpiresAt, and I can revoke it now":
//
//	if err := book.Spend(id, spenderKey, now, amount); err != nil {
//		panic(err) // revoked, expired, over the window cap, over the total
//	}
//	// ... the realm moves the coins here, under its own authority
//
// Spend checks every bound and CONSUMES the allowance in the same call,
// before returning. The realm then acts. Because the realm performs the
// effect itself, no closure, callback, or capability ever crosses a realm
// boundary. spendbook cannot be handed code to run, so it cannot be
// tricked into running the wrong code.
//
// # Windows are anchored, not sliding
//
// A window is derived from a fixed origin — the Anchor set at Open — by
// integer division:
//
//	index(now) = (now - Anchor) / PeriodLength
//
// so the boundaries are the same for everyone and a spender cannot reset a
// window by choosing when to call. A sliding "PerPeriod per trailing N
// blocks" window would let a spender draw the full cap at the end of one
// trailing span and again at the start of the next; anchoring removes the
// choice. The refill is a RESET, not a carry: an unused allowance does not
// accumulate into the next window, because the point of the cap is to bound
// worst-case loss per window, and a carry would unbound it.
//
// PeriodLength == 0 means one window that never rolls: a pure lifetime
// allowance, where PerPeriod is the only cap that matters.
//
// # Amendments cannot enlarge the live window
//
// An owner who could raise PerPeriod mid-window would be able to undo the
// bound a spender is relying on, and — worse in the other direction — an
// owner who drains a relationship and then lowers terms retroactively
// could strand a spender mid-settlement. The rule here is one-sided and
// enforced in Amend:
//
//   - TIGHTER-OR-EQUAL terms apply IMMEDIATELY. Lowering a ceiling can
//     never authorize a draw that was not already authorized, so there is
//     no reason to delay it, and delaying it would make the owner's only
//     fast remedy Revoke.
//   - LOOSER terms are PENDING and take effect at the next window
//     boundary, never inside the current one.
//
// This is the same adversarial problem that r/samcrew/agent_registry_v2
// solves by locking its price while any credit entry exists; the shape
// here is a deferral rather than a lock, so terms can still move.
//
// With PeriodLength == 0 there is no next boundary, so a loosening
// amendment is refused with ErrNoBoundary rather than silently queued
// forever. PeriodLength itself is IMMUTABLE: changing it would move every
// future boundary, which is an enlargement vector wearing a different hat.
//
// # State growth
//
// Revoked allowances are removed, not archived. IDs are allocated
// monotonically and never reused, so a revoked ID can never be resurrected
// and there is nothing to keep. Live allowances are capped per Book at
// construction, so storage is bounded by maxLive regardless of how many
// allowances have ever existed. Audit history belongs in the consuming
// realm's events.
//
// An EXPIRED allowance is not self-removing, and bounded storage is not the
// same as a usable Book: Spend refuses it forever while it still holds a
// slot. Reap exists for exactly that and is permissionless, because an
// expired allowance can authorize nothing and so removing it takes nothing
// from anyone.
//
// What this package does NOT bound is how many of a Book's slots ONE owner
// may hold — maxLive is a single global figure, so any owner permitted to
// Open can exhaust it and lock out the rest. That is a policy question with
// no answer a primitive can pick (per-owner quota? first-come? owner
// whitelist?), so it is left where the authentication already lives: the
// consuming realm decides who may Open, and a Book shared across mutually
// untrusting owners needs its own per-owner cap on top of this one. Named
// here rather than implied, because "bounded" reads like "safe to share".
//
// # Consumer contract (the parts the package cannot enforce)
//
//  1. SUPPLY A REAL CLOCK. spendbook cannot verify that `now` came from
//     runtime.ChainHeight() or time.Now().Unix(). A realm that lets a
//     caller choose `now` has handed the spender the power to roll the
//     window at will, which defeats every cap in this package. Pass the
//     chain's own clock, and use the same units for the life of the Book.
//
//  2. AUTHENTICATE THE SPENDER KEY. spendbook compares the key string it
//     is given against the one recorded at Open. It cannot tell whether
//     that string is the real caller. Derive it from
//     cur.Previous().Address(), never from an argument the caller supplies.
//
//  3. SPEND BEFORE SENDING. Spend consumes the allowance and returns; the
//     realm then moves coins. Doing it in the other order means a failed
//     send leaves the allowance consumed, or a successful send leaves it
//     unconsumed — both are real losses. State first, effect second.
//
//  4. AN ALLOWANCE IS NOT CUSTODY. spendbook authorizing 100 does not mean
//     100 exists. The realm must check its own held balance separately;
//     this package bounds permission, not solvency.
package spendbook

import (
	"errors"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// MaxLiveLimit is the largest maxLive a Book may be constructed with. It
// bounds the worst-case cost of Iterate, which scans the live set.
const MaxLiveLimit = 10000

// MaxKeyLen bounds an owner or spender key. A bech32 gno address is 40
// characters; the headroom exists so a realm may namespace its keys.
const MaxKeyLen = 128

// maxInt64 is the overflow boundary for every accumulation here.
const maxInt64 = int64(1<<63 - 1)

// Errors returned by Book operations.
var (
	ErrInvalidConfig  = errors.New("spendbook: invalid book configuration")
	ErrEmptyOwner     = errors.New("spendbook: empty owner key")
	ErrEmptySpender   = errors.New("spendbook: empty spender key")
	ErrKeyTooLong     = errors.New("spendbook: key exceeds MaxKeyLen")
	ErrInvalidNow     = errors.New("spendbook: now must be non-negative")
	ErrInvalidTerms   = errors.New("spendbook: invalid terms")
	ErrInvalidAmount  = errors.New("spendbook: amount must be positive")
	ErrBookFull       = errors.New("spendbook: live allowance cap reached")
	ErrNotFound       = errors.New("spendbook: no such live allowance")
	ErrNotExpired     = errors.New("spendbook: allowance has not expired")
	ErrNotOwner       = errors.New("spendbook: caller does not own this allowance")
	ErrNotSpender     = errors.New("spendbook: caller is not this allowance's spender")
	ErrExpired        = errors.New("spendbook: allowance has expired")
	ErrNotStarted     = errors.New("spendbook: allowance has not started")
	ErrPeriodExceeded = errors.New("spendbook: amount exceeds the window cap")
	ErrTotalExceeded  = errors.New("spendbook: amount exceeds the lifetime cap")
	ErrNoBoundary     = errors.New("spendbook: no reachable next window boundary")
	ErrOverflow       = errors.New("spendbook: int64 overflow")
	ErrIDExhausted    = errors.New("spendbook: identifier space exhausted")
)

// Terms are the ceilings on an allowance. Zero has a distinct meaning in
// three of the four fields and it is never "zero allowed":
//
//	PerPeriod    > 0 required. The cap per window.
//	PeriodLength 0 means ONE window that never rolls (lifetime).
//	Total        0 means no lifetime cap.
//	ExpiresAt    0 means no expiry.
type Terms struct {
	PerPeriod    int64
	PeriodLength int64
	Total        int64
	ExpiresAt    int64
}

// valid reports whether the terms are self-consistent, given the anchor the
// allowance is (or would be) opened at.
func (t Terms) valid(anchor int64) bool {
	if t.PerPeriod <= 0 || t.PeriodLength < 0 || t.Total < 0 {
		return false
	}
	if t.ExpiresAt < 0 {
		return false
	}
	// An allowance that has already expired at its own anchor can never
	// authorize anything, so accepting it would only create a live entry
	// that every Spend refuses.
	if t.ExpiresAt != 0 && t.ExpiresAt <= anchor {
		return false
	}
	// A Total below PerPeriod is not an error -- it is a narrower lifetime
	// cap, which Spend enforces. A Total of exactly 0 is "unlimited".
	return true
}

// tighterOrEqualTo reports whether t is weakly tighter than u in every
// dimension, i.e. whether t can authorize nothing u would not have. This is
// the predicate that decides whether an amendment applies immediately.
//
// The zero-means-unlimited fields invert the comparison, which is the whole
// subtlety: Total 0 is LOOSER than any positive Total, and ExpiresAt 0 is
// LOOSER than any positive ExpiresAt. Reading those two as "smaller is
// tighter" would let an owner remove a lifetime cap and an expiry
// mid-window and call it a tightening.
func (t Terms) tighterOrEqualTo(u Terms) bool {
	if t.PeriodLength != u.PeriodLength {
		return false // immutable; see the package doc
	}
	if t.PerPeriod > u.PerPeriod {
		return false
	}
	switch {
	case u.Total == 0:
		// u was unlimited; anything is tighter or equal.
	case t.Total == 0 || t.Total > u.Total:
		return false
	}
	switch {
	case u.ExpiresAt == 0:
		// u never expired; any expiry is tighter or equal.
	case t.ExpiresAt == 0 || t.ExpiresAt > u.ExpiresAt:
		return false
	}
	return true
}

// Allowance is one owner's grant to one spender. It is returned BY VALUE:
// holders cannot reach into a Book through it.
type Allowance struct {
	ID        uint64
	Owner     string
	Spender   string
	Terms     Terms
	Anchor    int64 // window origin; also the earliest spendable instant
	CreatedAt int64

	SpentTotal  int64 // over the allowance's whole life
	SpentWindow int64 // within WindowIndex
	WindowIndex int64

	// Pending terms, applied at the next window boundary. Meaningful only
	// when HasPending is true.
	Pending    Terms
	HasPending bool
}

// IsExpired reports whether the allowance is past its expiry at now. An
// allowance with no expiry is never expired.
func (a Allowance) IsExpired(now int64) bool {
	return a.Terms.ExpiresAt != 0 && now >= a.Terms.ExpiresAt
}

// windowIndex returns the anchored window number containing now. A lifetime
// allowance (PeriodLength == 0) is always in window 0.
//
// now < Anchor cannot reach here: every caller rejects it first with
// ErrNotStarted, which keeps this division away from negative numerators
// where Go's truncation-toward-zero would fold two windows into one.
func (a Allowance) windowIndex(now int64) int64 {
	if a.Terms.PeriodLength == 0 {
		return 0
	}
	return (now - a.Anchor) / a.Terms.PeriodLength
}

// nextBoundary returns the instant window idx+1 begins, and whether that
// instant is reachable at all.
//
// Unreachable has three causes and they collapse to the same answer, which is
// why this returns a bool rather than an error: a lifetime allowance has no
// boundary by construction, and an arithmetically unrepresentable boundary
// (PeriodLength so large, or the clock so far along, that Anchor + steps *
// PeriodLength overflows int64) is one no clock will ever reach. Computing it
// unguarded would wrap to a small number and report a boundary in the PAST,
// which is the dangerous direction: Amend would queue a loosening as though
// it were about to take effect.
func (a Allowance) nextBoundary(idx int64) (int64, bool) {
	pl := a.Terms.PeriodLength
	if pl == 0 || idx < 0 || idx == maxInt64 {
		return 0, false
	}
	steps := idx + 1
	if steps > maxInt64/pl {
		return 0, false
	}
	off := steps * pl
	if off > maxInt64-a.Anchor {
		return 0, false
	}
	return a.Anchor + off, true
}

// at computes the allowance's effective state at now WITHOUT mutating it:
// the terms in force, the window it falls in, and how much has been spent
// within that window.
//
// Spend and Remaining BOTH go through this one function. That is deliberate
// -- a read that answered "how much is left" with its own copy of the
// rollover and amendment logic would be a second implementation of the
// rule, free to disagree with the one that enforces it, and the
// disagreement would surface as an allowance that reports more than it
// honors (or honors more than it reports).
func (a Allowance) at(now int64) (Terms, int64, int64) {
	idx := a.windowIndex(now)
	if idx == a.WindowIndex {
		return a.Terms, idx, a.SpentWindow
	}
	// The window has rolled. A pending amendment takes effect exactly here,
	// and the in-window spend resets -- it does not carry.
	terms := a.Terms
	if a.HasPending {
		terms = a.Pending
	}
	return terms, idx, 0
}

// Remaining reports how much the spender may draw right now: the lesser of
// what the current window leaves and what the lifetime cap leaves. It is 0
// for an allowance that is expired, not yet started, or fully drawn.
//
// It is a projection, not a reservation. Nothing is held, and the figure can
// change in the same block if someone else's call advances the clock past a
// boundary.
func (a Allowance) Remaining(now int64) int64 {
	if now < a.Anchor || a.IsExpired(now) {
		return 0
	}
	terms, _, spentWindow := a.at(now)
	left := terms.PerPeriod - spentWindow
	if left < 0 {
		// Reachable: a tightening amendment can drop PerPeriod below what
		// the window already spent. The allowance is drawn, not negative.
		left = 0
	}
	if terms.Total != 0 {
		lifeLeft := terms.Total - a.SpentTotal
		if lifeLeft < 0 {
			lifeLeft = 0
		}
		if lifeLeft < left {
			left = lifeLeft
		}
	}
	return left
}

// Book holds the live allowances of one consuming realm. The zero value is
// not usable; construct with New.
type Book struct {
	maxLive int
	nextID  uint64    // never decreases; IDs are never reused
	live    *avl.Tree // padded id -> Allowance
}

// New returns an empty Book. maxLive caps simultaneously live allowances
// and must be in [1, MaxLiveLimit].
func New(maxLive int) (*Book, error) {
	if maxLive < 1 || maxLive > MaxLiveLimit {
		return nil, ErrInvalidConfig
	}
	return &Book{maxLive: maxLive, nextID: 1, live: avl.NewTree()}, nil
}

// MustNew is New but panics on error.
func MustNew(maxLive int) *Book {
	b, err := New(maxLive)
	if err != nil {
		panic(err)
	}
	return b
}

// MaxLive returns the Book's cap on simultaneously live allowances.
func (b *Book) MaxLive() int { return b.maxLive }

// Count returns the number of live allowances.
func (b *Book) Count() int { return b.live.Size() }

// key pads an id to a fixed width so avl's lexical order matches numeric
// order. 20 digits covers the whole uint64 range.
func key(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func checkKeys(owner, spender string) error {
	if owner == "" {
		return ErrEmptyOwner
	}
	if spender == "" {
		return ErrEmptySpender
	}
	if len(owner) > MaxKeyLen || len(spender) > MaxKeyLen {
		return ErrKeyTooLong
	}
	return nil
}

// Open records a new allowance and returns its id. now becomes the window
// anchor and the earliest instant the spender may draw.
//
// An owner may open several allowances for the same spender; they are
// independent, and the ids are what tell them apart. spendbook does not
// merge or deduplicate them, because "one allowance per pair" is a policy
// some consuming realms want and others do not, and a primitive that
// decided it here could not be talked out of it.
func (b *Book) Open(owner, spender string, now int64, terms Terms) (uint64, error) {
	if err := checkKeys(owner, spender); err != nil {
		return 0, err
	}
	if now < 0 {
		return 0, ErrInvalidNow
	}
	if !terms.valid(now) {
		return 0, ErrInvalidTerms
	}
	if b.live.Size() >= b.maxLive {
		return 0, ErrBookFull
	}
	if b.nextID == 0 {
		return 0, ErrIDExhausted
	}
	id := b.nextID
	b.nextID++
	b.live.Set(key(id), Allowance{
		ID:        id,
		Owner:     owner,
		Spender:   spender,
		Terms:     terms,
		Anchor:    now,
		CreatedAt: now,
	})
	return id, nil
}

// get fetches a live allowance by id.
//
// avl's Get returns a bare `any` with no found flag, so absence is a nil
// value. That is sound here only because nothing nil is ever stored: Set is
// called in exactly three places and all three pass an Allowance value.
func (b *Book) get(id uint64) (Allowance, bool) {
	v := b.live.Get(key(id))
	if v == nil {
		return Allowance{}, false
	}
	a, ok := v.(Allowance)
	if !ok {
		return Allowance{}, false
	}
	return a, true
}

// Get returns a copy of a live allowance.
func (b *Book) Get(id uint64) (Allowance, error) {
	a, ok := b.get(id)
	if !ok {
		return Allowance{}, ErrNotFound
	}
	return a, nil
}

// Remaining reports what the spender of id may draw at now, or 0 if there
// is no such live allowance. A caller that must distinguish "nothing left"
// from "no such allowance" should use Get.
func (b *Book) Remaining(id uint64, now int64) int64 {
	a, ok := b.get(id)
	if !ok {
		return 0
	}
	return a.Remaining(now)
}

// Spend consumes amount from allowance id on behalf of spender and returns
// nil if every bound permits it. The caller then performs its own effect.
//
// On any error NOTHING is consumed. The write happens once, after the last
// check, so a refused Spend leaves the book exactly as it was.
func (b *Book) Spend(id uint64, spender string, now int64, amount int64) error {
	if now < 0 {
		return ErrInvalidNow
	}
	if amount <= 0 {
		return ErrInvalidAmount
	}
	a, ok := b.get(id)
	if !ok {
		return ErrNotFound
	}
	if a.Spender != spender {
		return ErrNotSpender
	}
	if now < a.Anchor {
		return ErrNotStarted
	}
	if a.IsExpired(now) {
		return ErrExpired
	}

	terms, idx, spentWindow := a.at(now)

	// Window cap. Checked as a subtraction so the sum cannot overflow:
	// spentWindow and PerPeriod are both >= 0 and PerPeriod > 0.
	if amount > terms.PerPeriod-spentWindow {
		return ErrPeriodExceeded
	}
	// Lifetime cap.
	if terms.Total != 0 && amount > terms.Total-a.SpentTotal {
		return ErrTotalExceeded
	}
	// SpentTotal is unbounded when Total == 0, so it is the one
	// accumulation that can genuinely reach the int64 ceiling.
	if a.SpentTotal > maxInt64-amount {
		return ErrOverflow
	}

	a.Terms = terms
	if idx != a.WindowIndex {
		a.HasPending = false
		a.Pending = Terms{}
	}
	a.WindowIndex = idx
	a.SpentWindow = spentWindow + amount
	a.SpentTotal += amount
	b.live.Set(key(id), a)
	return nil
}

// Revoke removes an allowance. Only its owner may revoke, and it takes
// effect immediately -- there is no window to wait for, because revocation
// is the owner's remedy and a delayed remedy is not one.
//
// The id is not reused, so a revoked allowance cannot be resurrected: a
// later Spend on it returns ErrNotFound forever.
func (b *Book) Revoke(id uint64, owner string) error {
	a, ok := b.get(id)
	if !ok {
		return ErrNotFound
	}
	if a.Owner != owner {
		return ErrNotOwner
	}
	b.live.Remove(key(id))
	return nil
}

// Amend changes an allowance's terms. Only its owner may amend.
//
// PeriodLength is immutable and must be passed unchanged. Terms that are
// weakly tighter in every dimension apply immediately; anything looser
// becomes pending and takes effect at the next window boundary. A lifetime
// allowance has no next boundary, so a loosening amendment on one is
// refused with ErrNoBoundary.
//
// The returned bool reports whether the amendment applied immediately
// (true) or was queued (false). A caller that ignores it cannot tell
// whether the new ceiling is in force, which is exactly the thing worth
// knowing.
func (b *Book) Amend(id uint64, owner string, now int64, terms Terms) (bool, error) {
	if now < 0 {
		return false, ErrInvalidNow
	}
	a, ok := b.get(id)
	if !ok {
		return false, ErrNotFound
	}
	if a.Owner != owner {
		return false, ErrNotOwner
	}
	if now < a.Anchor {
		return false, ErrNotStarted
	}
	if a.IsExpired(now) {
		return false, ErrExpired
	}
	// Validated against the ANCHOR rather than now, which is the LOOSER of
	// the two and is deliberate. valid() only needs ExpiresAt to be after the
	// window origin; an owner naming an expiry between the anchor and now is
	// tightening the allowance until it is dead, which is their prerogative.
	// Revoke is the cleaner way to say that, and Reap then reclaims the slot.
	if !terms.valid(a.Anchor) {
		return false, ErrInvalidTerms
	}
	if terms.PeriodLength != a.Terms.PeriodLength {
		return false, ErrInvalidTerms
	}

	// Roll the window first if the clock has moved past a boundary, so an
	// amendment made after a quiet stretch is judged against the terms
	// actually in force rather than the ones a stale record still holds.
	cur, idx, spentWindow := a.at(now)
	if idx != a.WindowIndex {
		a.Terms = cur
		a.WindowIndex = idx
		a.SpentWindow = spentWindow
		a.HasPending = false
		a.Pending = Terms{}
	}

	if terms.tighterOrEqualTo(a.Terms) {
		a.Terms = terms
		// A tightening supersedes a queued loosening. Leaving it queued
		// would mean the owner's tightening silently expires at the next
		// boundary and the looser terms they just replaced come back.
		a.HasPending = false
		a.Pending = Terms{}
		b.live.Set(key(id), a)
		return true, nil
	}

	// A loosening is only queueable if the boundary it waits for will arrive
	// while the allowance is still alive. Queueing one that cannot be reached
	// would report "accepted, pending" for terms that never take effect --
	// the owner's amendment silently discarded, which is the failure mode
	// this package is least able to explain after the fact.
	//
	// Two ways it is unreachable. The allowance has no boundary at all
	// (PeriodLength == 0, or an unrepresentable one), or the current terms
	// expire at or before the next boundary. The second is reachable in
	// ordinary use: a tightening of ExpiresAt applies IMMEDIATELY, so an
	// owner can tighten the expiry below the next boundary and then loosen
	// PerPeriod, and without this check the second call would be accepted
	// against a window that never opens.
	nb, ok := a.nextBoundary(a.WindowIndex)
	if !ok {
		return false, ErrNoBoundary
	}
	if a.Terms.ExpiresAt != 0 && nb >= a.Terms.ExpiresAt {
		return false, ErrNoBoundary
	}
	a.Pending = terms
	a.HasPending = true
	b.live.Set(key(id), a)
	return false, nil
}

// Reap removes an allowance that has expired at now, and may be called by
// anyone. It returns ErrNotFound for an unknown id and ErrNotExpired for one
// that is still alive.
//
// Permissionless on purpose, and the reasoning is the whole justification:
// an expired allowance can never authorize another draw, so removing it takes
// nothing from the owner and grants nothing to the caller. Without it an
// expiry is a slow leak against maxLive -- Spend refuses the dead allowance
// forever while it holds a slot, so a Book shared between owners could fill
// with corpses and refuse new Opens, and the only remedy would be the owner
// of each corpse noticing and calling Revoke.
//
// This relies on `now` exactly as much as Spend does. A realm that lets a
// caller choose `now` has already broken consumer contract item 1, and such a
// realm would let a caller reap a LIVE allowance by naming a future instant.
func (b *Book) Reap(id uint64, now int64) error {
	if now < 0 {
		return ErrInvalidNow
	}
	a, ok := b.get(id)
	if !ok {
		return ErrNotFound
	}
	if !a.IsExpired(now) {
		return ErrNotExpired
	}
	b.live.Remove(key(id))
	return nil
}

// Iterate calls fn for every live allowance in id order, stopping early if
// fn returns true. The allowance is passed by value, so fn cannot mutate
// the book through it.
func (b *Book) Iterate(fn func(Allowance) bool) {
	b.live.Iterate("", "", func(_ string, v any) bool {
		return fn(v.(Allowance))
	})
}
