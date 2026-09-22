// Package duebook is a pure scheduling primitive for realms that need to
// authorize an action now and perform it later. It is to *time* what
// feeledger is to *money*: it holds no coins, performs no effects, imports
// no chain APIs, and owns no package-level state. The importing realm owns
// a *Book, supplies the clock, and performs its own effects.
//
// # The one idea
//
// A realm does not ask duebook to execute anything — Gno has no autonomous
// execution, so "scheduled" always means "someone sends a transaction
// later". What a realm actually needs is for that later transaction to be
// authorized exactly once. Claim is that step:
//
//	d, err := book.Claim(id, now)
//	if err != nil {
//		panic(err) // not due, expired, cancelled, or already claimed
//	}
//	// ... the realm performs its own effect here, under its own authority
//
// Claim checks due / not-expired / still-open and CONSUMES the deferral in
// the same call, before returning. The realm then acts. Replay is not
// guarded against, it is structurally impossible:
//
//   - IDs are allocated monotonically from an internal counter and are
//     NEVER reused, for the lifetime of the Book;
//   - a successful Claim removes the deferral before returning;
//
// so at most one Claim per ID can ever succeed, across all transactions,
// forever. A second Claim of the same ID returns ErrNotFound whether the
// first one happened in this transaction or a year ago.
//
// Because the realm performs the effect itself, no closure, callback, or
// capability ever crosses a realm boundary. duebook cannot be handed code
// to run, so it cannot be tricked into running the wrong code.
//
// # Lifecycle
//
// A deferral is open from Schedule until exactly one of Claim, Cancel, or
// Expire consumes it. There is no other transition and no way back.
//
//	Schedule ──> open ──┬── Claim   (now >= DueAt, before ExpiresAt)
//	                    ├── Cancel  (owner only, any time while open)
//	                    └── Expire  (anyone, once now >= ExpiresAt)
//
// Claimability is the half-open interval [DueAt, ExpiresAt): due at DueAt,
// no longer claimable at ExpiresAt. A deferral scheduled with ttl == 0
// never expires and has ExpiresAt == 0.
//
// # State growth
//
// Consumed deferrals are removed, not archived — the ID counter, not a
// tombstone, is what prevents replay, so there is nothing to keep. Open
// deferrals are capped per Book at construction. Storage is therefore
// bounded by maxOpen regardless of how many deferrals have ever existed.
// Audit history belongs in the consuming realm's events.
//
// # Consumer contract (the parts the package cannot enforce)
//
//  1. SUPPLY A REAL CLOCK. duebook cannot verify that `now` came from
//     runtime.ChainHeight() or time.Now().Unix(). A realm that lets a caller
//     choose `now` has no delay at all. Pass the chain's clock, never a
//     transaction parameter. This is the single most important obligation
//     and the one most commonly got wrong.
//  2. USE ONE CLOCK CONSISTENTLY. Heights and seconds must not be mixed
//     within a Book; delay, ttl and now are all in the caller's chosen
//     unit.
//  3. DO NOT EXPORT THE BOOK. A *Book is a mutable handle. Returning one
//     across a realm boundary hands out the right to schedule, cancel and
//     claim. Expose your own crossing functions instead; this package
//     returns Deferral values, never pointers into its state.
//  4. AUTHORIZE THE ACTOR. duebook authenticates nothing but ownership on
//     Cancel. Who may Schedule, and who may Claim, are the realm's policy —
//     derive the caller from cur.Previous().Address(), not from an argument.
//  5. ACT AFTER A SUCCESSFUL CLAIM, IN THE SAME TRANSACTION. Claim's
//     return value is the authorization. Storing it to act on later
//     reintroduces the replay window this package exists to close.
//
// All failures are returned as errors and leave the Book COMPLETELY
// UNCHANGED. Must* wrappers are the only functions here that panic.
//
// The Book is address-agnostic: owners are non-empty strings. Realms
// normally use address.String().
package duebook

import (
	"errors"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// MaxPayloadLen bounds a single deferral's payload. The payload is opaque
// to duebook — it exists so a realm can recover what it scheduled without
// keeping a parallel table.
const MaxPayloadLen = 4096

// MaxOpenLimit is the largest maxOpen a Book may be constructed with. It
// bounds the worst-case cost of Due and IterateOpen, which scan the open
// set.
const MaxOpenLimit = 10000

// Errors returned by Book operations.
var (
	ErrEmptyOwner    = errors.New("duebook: empty owner key")
	ErrPayloadTooBig = errors.New("duebook: payload exceeds MaxPayloadLen")
	ErrInvalidNow    = errors.New("duebook: now must be non-negative")
	ErrInvalidDelay  = errors.New("duebook: delay outside [minDelay, maxDelay]")
	ErrInvalidTTL    = errors.New("duebook: ttl must be non-negative")
	ErrInvalidConfig = errors.New("duebook: invalid book configuration")
	ErrBookFull      = errors.New("duebook: open deferral cap reached")
	ErrNotFound      = errors.New("duebook: no such open deferral")
	ErrNotDue        = errors.New("duebook: not due yet")
	ErrExpired       = errors.New("duebook: deferral has expired")
	ErrNotExpired    = errors.New("duebook: deferral has not expired")
	ErrNotOwner      = errors.New("duebook: caller does not own this deferral")
	ErrOverflow      = errors.New("duebook: int64 overflow")
	ErrIDExhausted   = errors.New("duebook: identifier space exhausted")
)

// Deferral is a scheduled action. It is returned BY VALUE: holders cannot
// reach into a Book through it. Payload is opaque to this package.
//
// ExpiresAt == 0 means the deferral never expires. Otherwise the deferral
// is claimable exactly on [DueAt, ExpiresAt).
type Deferral struct {
	ID        uint64
	Owner     string
	Payload   string
	CreatedAt int64
	DueAt     int64
	ExpiresAt int64
}

// IsDue reports whether the deferral has reached its due time at now.
func (d Deferral) IsDue(now int64) bool { return now >= d.DueAt }

// IsExpired reports whether the deferral is past its expiry at now.
// A deferral with no expiry is never expired.
func (d Deferral) IsExpired(now int64) bool {
	return d.ExpiresAt != 0 && now >= d.ExpiresAt
}

// IsClaimable reports whether Claim would succeed at now, assuming the
// deferral is still open.
func (d Deferral) IsClaimable(now int64) bool {
	return d.IsDue(now) && !d.IsExpired(now)
}

// Book holds the open deferrals of one consuming realm. The zero value is
// not usable; construct with New.
type Book struct {
	minDelay int64
	maxDelay int64
	maxOpen  int
	nextID   uint64    // never decreases; IDs are never reused
	open     *avl.Tree // padded id -> Deferral
}

// New returns an empty Book.
//
// minDelay is the floor on how far ahead a deferral may be scheduled; 0
// permits same-instant scheduling. maxDelay is the ceiling, and doubles as
// the overflow guard on now+delay. maxOpen caps simultaneously open
// deferrals and must be in [1, MaxOpenLimit].
//
// Units are the caller's choice — block heights or seconds — but must be
// used consistently for the life of the Book.
func New(minDelay, maxDelay int64, maxOpen int) (*Book, error) {
	if minDelay < 0 || maxDelay < minDelay {
		return nil, ErrInvalidConfig
	}
	if maxOpen < 1 || maxOpen > MaxOpenLimit {
		return nil, ErrInvalidConfig
	}
	return &Book{
		minDelay: minDelay,
		maxDelay: maxDelay,
		maxOpen:  maxOpen,
		nextID:   1,
		open:     avl.NewTree(),
	}, nil
}

// MustNew is New but panics on error.
func MustNew(minDelay, maxDelay int64, maxOpen int) *Book {
	b, err := New(minDelay, maxDelay, maxOpen)
	if err != nil {
		panic(err)
	}
	return b
}

// MinDelay returns the Book's scheduling floor.
func (b *Book) MinDelay() int64 { return b.minDelay }

// MaxDelay returns the Book's scheduling ceiling.
func (b *Book) MaxDelay() int64 { return b.maxDelay }

// MaxOpen returns the Book's cap on simultaneously open deferrals.
func (b *Book) MaxOpen() int { return b.maxOpen }

// OpenCount returns how many deferrals are currently open.
func (b *Book) OpenCount() int { return b.open.Size() }

// NextID returns the identifier the next Schedule will allocate. It only
// ever increases, which is what makes a consumed ID unreusable.
func (b *Book) NextID() uint64 { return b.nextID }

// Schedule opens a deferral owned by owner, due at now+delay, expiring
// ttl after that (ttl == 0 means it never expires). It returns the new
// deferral's ID.
//
// Fails with ErrEmptyOwner, ErrPayloadTooBig, ErrInvalidNow (now < 0),
// ErrInvalidDelay (delay outside [MinDelay, MaxDelay]), ErrInvalidTTL
// (ttl < 0), ErrBookFull, ErrOverflow, or ErrIDExhausted. On error
// nothing is modified.
func (b *Book) Schedule(owner, payload string, now, delay, ttl int64) (uint64, error) {
	if owner == "" {
		return 0, ErrEmptyOwner
	}
	if len(payload) > MaxPayloadLen {
		return 0, ErrPayloadTooBig
	}
	if now < 0 {
		return 0, ErrInvalidNow
	}
	if delay < b.minDelay || delay > b.maxDelay {
		return 0, ErrInvalidDelay
	}
	if ttl < 0 {
		return 0, ErrInvalidTTL
	}
	if b.open.Size() >= b.maxOpen {
		return 0, ErrBookFull
	}
	if b.nextID == 0 {
		return 0, ErrIDExhausted
	}

	dueAt, ok := checkedAdd(now, delay)
	if !ok {
		return 0, ErrOverflow
	}
	expiresAt := int64(0)
	if ttl > 0 {
		expiresAt, ok = checkedAdd(dueAt, ttl)
		if !ok {
			return 0, ErrOverflow
		}
	}

	id := b.nextID
	b.nextID++
	b.open.Set(idKey(id), Deferral{
		ID:        id,
		Owner:     owner,
		Payload:   payload,
		CreatedAt: now,
		DueAt:     dueAt,
		ExpiresAt: expiresAt,
	})
	return id, nil
}

// MustSchedule is Schedule but panics on error.
func (b *Book) MustSchedule(owner, payload string, now, delay, ttl int64) uint64 {
	id, err := b.Schedule(owner, payload, now, delay, ttl)
	if err != nil {
		panic(err)
	}
	return id
}

// Claim consumes the deferral and returns it, authorizing the caller to
// perform the deferred action NOW, in this transaction.
//
// It succeeds only while the deferral is open and now is in
// [DueAt, ExpiresAt). The deferral is removed BEFORE Claim returns, so a
// re-entrant or later Claim of the same ID finds nothing; combined with
// non-reused IDs, at most one Claim per ID ever succeeds.
//
// Fails with ErrInvalidNow, ErrNotFound (never existed, or already
// consumed by Claim/Cancel/Expire), ErrNotDue, or ErrExpired. On error
// nothing is modified.
//
// duebook does NOT check who is claiming: whether a deferral is
// permissionlessly claimable or restricted to its owner is the consuming
// realm's policy, applied before calling Claim.
func (b *Book) Claim(id uint64, now int64) (Deferral, error) {
	if now < 0 {
		return Deferral{}, ErrInvalidNow
	}
	d, ok := b.get(id)
	if !ok {
		return Deferral{}, ErrNotFound
	}
	if !d.IsDue(now) {
		return Deferral{}, ErrNotDue
	}
	if d.IsExpired(now) {
		return Deferral{}, ErrExpired
	}
	// Consume before returning: the caller acts only after this point, so
	// the deferral is already gone when the effect runs.
	b.open.Remove(idKey(id))
	return d, nil
}

// MustClaim is Claim but panics on error.
func (b *Book) MustClaim(id uint64, now int64) Deferral {
	d, err := b.Claim(id, now)
	if err != nil {
		panic(err)
	}
	return d
}

// Cancel consumes an open deferral without performing it. Only its owner
// may cancel, and cancellation is permitted at any time while the deferral
// is open — including after it became due but before anyone claimed it.
//
// Fails with ErrEmptyOwner, ErrNotFound, or ErrNotOwner. On error nothing
// is modified.
func (b *Book) Cancel(id uint64, owner string) (Deferral, error) {
	if owner == "" {
		return Deferral{}, ErrEmptyOwner
	}
	d, ok := b.get(id)
	if !ok {
		return Deferral{}, ErrNotFound
	}
	if d.Owner != owner {
		return Deferral{}, ErrNotOwner
	}
	b.open.Remove(idKey(id))
	return d, nil
}

// MustCancel is Cancel but panics on error.
func (b *Book) MustCancel(id uint64, owner string) Deferral {
	d, err := b.Cancel(id, owner)
	if err != nil {
		panic(err)
	}
	return d
}

// Expire consumes a deferral that is past its expiry, reclaiming its
// storage. It is deliberately permissionless: an expired deferral can
// never be claimed again, so letting anyone clear it keeps a Book from
// silting up with dead entries that block Schedule against maxOpen.
//
// Fails with ErrInvalidNow, ErrNotFound, or ErrNotExpired (including for
// deferrals with no expiry, which never expire). On error nothing is
// modified.
func (b *Book) Expire(id uint64, now int64) (Deferral, error) {
	if now < 0 {
		return Deferral{}, ErrInvalidNow
	}
	d, ok := b.get(id)
	if !ok {
		return Deferral{}, ErrNotFound
	}
	if !d.IsExpired(now) {
		return Deferral{}, ErrNotExpired
	}
	b.open.Remove(idKey(id))
	return d, nil
}

// MustExpire is Expire but panics on error.
func (b *Book) MustExpire(id uint64, now int64) Deferral {
	d, err := b.Expire(id, now)
	if err != nil {
		panic(err)
	}
	return d
}

// Get returns an open deferral by ID. The second result is false if the
// deferral never existed or has already been consumed — Get cannot tell
// those apart, by design: consumed deferrals leave no tombstone.
//
// Get is a read-only preview and never authorizes anything. Only Claim's
// return value authorizes an action.
func (b *Book) Get(id uint64) (Deferral, bool) { return b.get(id) }

// Due returns up to limit open deferrals that are claimable at now, in
// ascending ID order (oldest first). A limit <= 0 returns nothing.
//
// It scans the open set, so its cost is bounded by MaxOpen.
func (b *Book) Due(now int64, limit int) []Deferral {
	out := []Deferral{}
	if limit <= 0 || now < 0 {
		return out
	}
	b.open.Iterate("", "", func(_ string, value any) bool {
		d := value.(Deferral)
		if d.IsClaimable(now) {
			out = append(out, d)
		}
		return len(out) >= limit
	})
	return out
}

// Expirable returns up to limit open deferrals that Expire would accept at
// now, in ascending ID order. A limit <= 0 returns nothing.
func (b *Book) Expirable(now int64, limit int) []Deferral {
	out := []Deferral{}
	if limit <= 0 || now < 0 {
		return out
	}
	b.open.Iterate("", "", func(_ string, value any) bool {
		d := value.(Deferral)
		if d.IsExpired(now) {
			out = append(out, d)
		}
		return len(out) >= limit
	})
	return out
}

// IterateOpen calls fn for every open deferral in ascending ID order.
// Iteration stops early when fn returns true.
//
// fn receives a COPY: Deferral is passed by value and holds only scalars
// and strings, so fn gets no pointer into the Book and cannot reach past
// it — Book's fields are all unexported.
//
// Two rules for fn, and the second is the one that is easy to miss.
//
//   - Do not Schedule, Claim, Cancel or Expire from inside fn: mutating
//     the tree while iterating it is undefined. Collect IDs first, then
//     act after IterateOpen returns.
//
//   - fn runs under the CALLING REALM'S STORAGE AUTHORITY. This method's
//     receiver is stamped with the importing realm's PkgID, so the borrow
//     rules leave the realm context set to that realm for the whole
//     callback, and a top-level fn has no receiver and no declaring realm
//     to anchor it elsewhere. A callback that re-enters the calling
//     realm's own mutators therefore does so with that realm's authority.
//     Never pass a caller-supplied function here from inside a
//     permission-gated path; pass only a closure this package's consumer
//     wrote itself.
func (b *Book) IterateOpen(fn func(Deferral) bool) {
	b.open.Iterate("", "", func(_ string, value any) bool {
		return fn(value.(Deferral))
	})
}

// get looks up an open deferral without touching the tree otherwise.
func (b *Book) get(id uint64) (Deferral, bool) {
	v := b.open.Get(idKey(id))
	if v == nil {
		return Deferral{}, false
	}
	return v.(Deferral), true
}

// idKey encodes an ID so that avl's lexical key order matches numeric ID
// order. math.MaxUint64 is 20 digits, so a fixed 20-wide zero-padded
// decimal is both sufficient and unambiguous.
func idKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	const width = 20
	if len(s) >= width {
		return s
	}
	return zeros[:width-len(s)] + s
}

const zeros = "00000000000000000000"

// checkedAdd returns a+b and reports whether the addition did not
// overflow int64.
func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
