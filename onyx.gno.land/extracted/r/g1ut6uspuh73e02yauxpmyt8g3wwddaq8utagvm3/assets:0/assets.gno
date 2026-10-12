// Package assets is a per-owner fixed-asset register whose ledger postings
// are DERIVED from state rather than asserted by a caller.
//
// # What this realm is for
//
// A general ledger takes a debit code, a credit code and an amount from
// whoever is posting. That is the right design for a ledger and it means
// gno.land/r/.../books structurally CANNOT know that an entry was a
// depreciation charge, or that the charge for that period had already been
// made. Nothing stops an owner from booking the same month twice, or from
// skipping one, and nothing in the book can tell afterwards.
//
// This realm closes that gap for one class of entry. It holds each asset's
// depreciation schedule as state, computes the charge from the schedule and
// the chain height, and keeps a per-asset HIGH-WATER MARK of the periods
// already booked. The amount is never a parameter. A charge therefore cannot
// be double-booked (the mark does not move backwards) and cannot be skipped
// (the next call books the whole span, because charges telescope exactly).
//
// The resulting claim is narrow and checkable by anyone, which is the point:
//
//	bookedAmount(asset) == asset.schedule.AccumulatedAt(bookedThrough(asset))
//
// and, across a whole register,
//
//	sum of bookedAmount over assets == the credit balance of 1590
//
// Both are exported as [Invariant] and [CrossFoot] and both are FREE reads,
// deliberately — see "Why Rederive is not owner-only" below.
//
// # The chart is two accounts and is fixed
//
//	5500  Depreciation expense       (expense, debit-normal)
//	1590  Accumulated depreciation   (asset,   CONTRA — see below)
//
// Every posting is debit 5500 / credit 1590 for an equal amount, so the
// accounting equation offsets at 0 = 0 on an empty register and after every
// charge. There is no OpenAccount entrypoint and the underlying book is
// created with a hard cap of two accounts, so the chart cannot grow.
//
// The COST BASIS never reaches the book. Booking an asset's cost would force
// a credit leg, and the only honest candidates are a liability
// ("2000 Acquisition payable") or an equity plug ("3000 Contributed
// capital"). Both assert how the asset was funded, which this realm does not
// know and must not invent. The cost stays in register state, where it is
// visible as data rather than as an accounting claim.
//
// 1590 is kind ASSET, so journal treats it as debit-normal and Balance()
// returns Debits - Credits — which reads NEGATIVE for accumulated
// depreciation. That is arithmetically correct for a contra-asset and is
// confusing on first reading, so both figures are exported and each is named
// for what it is: [AccumulatedCredit] is the positive contra balance.
//
// # Periods are measured in BLOCKS
//
// A period is periodBlocks chain heights long, anchored to the height the
// asset was placed in service. Period k closes at placedAt + k*periodBlocks,
// and a partial period in progress is not counted and is not lost.
//
// Block height, not wall-clock time, because that is this portfolio's
// convention: payroll, budgets, reimbursements and subscriptions all carry a
// periodBlocks field, and height is monotone by construction where block time
// is validator-reported. p/depreciation's Daily/Monthly/Yearly constants are
// SECONDS and are therefore not used here; its arithmetic is unit-agnostic
// (Periods is an integer division), so this is a mismatch in that package's
// documentation rather than a divergence from its behaviour. It is recorded
// in DISCOVERY.md § 6 rather than silently worked around.
//
// # Retirement books first, then freezes
//
// [Retire] performs the final booking for the periods completed up to the
// retirement height and only then stops the asset. The two are one
// transaction on purpose: retiring without booking would leave depreciation
// that was genuinely incurred permanently unbooked, and booking after
// retirement would need an exception to the "retired assets do not accrue"
// rule. Historical charges always stand — the depreciation really happened.
//
// Disposal gain or loss is OUT OF SCOPE for v1, and the reason is structural:
// it needs the cost-basis account this realm deliberately does not open, plus
// a proceeds figure the realm cannot observe because it holds no funds.
//
// # What this realm does NOT do
//
//   - No custody. It holds no coins, has no withdrawal path, and refuses a
//     user call that arrives carrying any. An asset's cost is a number an
//     owner typed.
//   - No period close. p/journal can seal a book up to a HEIGHT, refusing
//     entries dated at or before it. This realm's bookedThrough is a PERIOD
//     INDEX — a different axis wearing the same English word — and sealing a
//     derived book could only make the derivation unpostable. The capability
//     exists in the engine and is deliberately not exposed.
//   - No bulk booking. p/depreciation's MaxLife doc states the loop bound
//     (1199 iterations per CarryingAt, 2398 per Charge, and a degenerate
//     declining schedule that runs the full bound on every call forever) and
//     explicitly refuses to price it. A loop over N assets multiplies an
//     unpriced bound by N, so one asset is booked per call.
//   - No truth. A register is a set of claims by its owner. With no custody
//     there is nothing tying "cost 1000000" to a real holding. The invariants
//     here prove that the postings follow from the stored schedules; they
//     prove nothing about the world.
//
// # Why Rederive and the invariants are free reads
//
// r/books exposes Rederive as an owner-only crossing function, to contain the
// cost of a full re-walk. This realm diverges, deliberately: the derivation
// IS the product, and a claim only its owner can check is not a claim worth
// making. [Rederive], [Invariant] and [CrossFoot] are all free reads, so any
// third party can verify a register from vm/qeval without the owner's key.
//
// The bound above is what makes that affordable, and a bound is not a price.
// Measured under the pinned onyx toolchain at the register cap — 64 assets on
// MaxLife declining schedules, the worst case this realm can hold:
//
//	Render   per call:    106,421,272 gas
//	Rederive per call:  9,357,860,004 gas
//
// So the design choice is stated with its cost rather than only its reason.
// Render is an ordinary rich-page figure; Rederive at cap is two orders of
// magnitude above it, falls on the queried node rather than the caller, and
// is reachable with no key and no fee. Whether a given RPC's query gas
// ceiling admits it AT THE CAP is a property of that node and is not measured
// here — if it refuses, the third-party-verification claim above fails
// exactly at the bound it was designed around. [Invariant] is per-asset and
// cheap; [CrossFoot] walks the assets only, not the postings.
//
// # Deploy order
//
// This realm imports p/journal and p/depreciation. Neither is deployed yet,
// so the order is p/journal, p/depreciation, then this realm.
package assets

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/depreciation"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/assets"

// The fixed chart. The codes follow r/books' convention, where an account's
// LEADING DIGIT fixes its kind: 1 asset, 2 liability, 3 equity, 4 revenue,
// 5 expense. A six-series code would be an invalid account under that
// convention, which is why the expense leg is 5500 and not the 6500 a
// textbook chart would use.
const (
	ExpenseCode = "5500"
	ExpenseName = "Depreciation expense"

	AccumCode = "1590"
	AccumName = "Accumulated depreciation"
)

// MaxAssetsPerRegister caps one owner's register. CrossFoot and Render both
// walk every asset, and this bound is what keeps those reads cheap for
// everyone.
const MaxAssetsPerRegister = 64

// MaxEntriesPerRegister caps one owner's journal, far below journal's
// MaxEntriesLimit of 1000000 because RederiveFromJournal is linear in the
// posting count and is a free read here.
//
// The bound is reachable and the arithmetic is worth stating: an asset posts
// at most one entry per completed period, so MaxAssetsPerRegister assets with
// MaxLife-period schedules could want 64*1200 = 76800 entries. A register
// that fills refuses further charges rather than dropping history. There is
// deliberately no Archive — it would destroy the record the invariants are
// checked against — so the remedy is a second register under a second
// address, which is a real limitation and not a hidden one.
const MaxEntriesPerRegister = 8192

// MaxLabelLen bounds an asset's human label. Every label is a candidate for
// Render output.
const MaxLabelLen = 64

// MinPeriodBlocks is the shortest period an asset may use. Matches the floor
// payroll, budgets and reimbursements already use. A period of 0 is not a
// special case here — it is simply invalid, because an asset with no period
// has no schedule to derive anything from.
const MinPeriodBlocks = int64(100)

// RenderAssetLimit caps how many assets one Render call tabulates.
const RenderAssetLimit = 25

// register is one owner's asset register and the book its charges post to.
//
// The book is a POINTER and is never returned by any exported function —
// p/journal consumer obligation 4: a *Book is a mutable handle, and handing
// one across a realm boundary would hand out the right to post.
type register struct {
	book     *journal.Book
	assets   *avl.Tree // decimal id -> *asset
	nextID   uint64
	openedAt int64
}

// asset is one depreciable item.
type asset struct {
	// id is carried in the value as well as the tree key, because the key
	// is zero-padded for ordering and parsing it back would be a second
	// encoding to keep in step with the first.
	id    uint64
	label string
	sched depreciation.Schedule

	// placedAt is the chain height period 0 begins at, and period is the
	// period length in heights. Both are fixed at placement: a schedule
	// whose clock could be edited afterwards would make every historical
	// charge unexplainable from current state.
	placedAt int64
	period   int64

	// booked is the high-water mark — whole periods already charged. It
	// only ever increases, and that is the whole of the idempotence
	// argument.
	booked int32

	// amount is the cumulative expense posted for this asset. The
	// per-asset invariant is amount == sched.AccumulatedAt(booked).
	amount int64

	retired   bool
	retiredAt int64
}

// regs maps an owner's address string to that owner's *register.
var regs = avl.NewTree()

// regCount is maintained alongside the tree so the index page never has to
// iterate it.
var regCount int

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

// refuseCoins panics if a user call arrives carrying coins.
//
// This realm has no withdrawal path, so accepted coins would be stranded
// permanently. The guard is on IsUserCall rather than IsUser deliberately:
// OriginSend is only meaningful for a direct MsgCall, and the MsgRun
// ephemeral can consume the envelope before forwarding control, so IsUser
// would be the wrong predicate.
//
// The IsCurrent() check is a separate concern and is not about coins: this is
// a non-crossing helper reading identity off a realm PARAMETER, which is the
// designation-forgery shape (security.md Class 2) whether or not a caller
// exercising it exists today. It is a no-op at every call site here — each is
// a crossing entrypoint forwarding its OWN first cur, runtime-current by
// construction — and is kept because this realm is IMMUTABLE after addpkg, so
// a call site added later cannot be made safe later. p/coinio guards the same
// shape in Receive, Payout and Sweep; this is that house precedent applied.
//
// No count of the call sites is written down, per CLAUDE.md § 4a.
func refuseCoins(cur realm) {
	if !cur.IsCurrent() {
		panic("assets: refuseCoins called with a realm that is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("assets: this realm holds no coins and has no withdrawal path; send none")
	}
}

// mustOwnRegister returns the CALLER'S register, and there is no variant that
// returns anyone else's. Every mutating entrypoint goes through this, so
// ownership is implicit in the call.
//
// "Ownership is never a parameter" is what this comment used to conclude, and
// it is true of the SIGNATURE and was never true of the realm VALUE: the owner
// is derived from cur, so an uncurrent cur IS an ownership parameter. That is
// the same Class 2 shape refuseCoins carries above and the more consequential
// half of it, because this is the function that decides who owns the register
// rather than one that only refuses coins. The guard is a no-op today for the
// same reason, kept for the same reason, and its call sites are likewise not
// counted here. See AUDIT.md.
func mustOwnRegister(cur realm) *register {
	if !cur.IsCurrent() {
		panic("assets: mustOwnRegister called with a realm that is not current")
	}
	owner := cur.Previous().Address()
	r, ok := reg(owner)
	if !ok {
		panic("assets: no register for " + owner.String() + "; call OpenRegister first")
	}
	return r
}

// reg looks an owner's register up. avl's Get returns a bare `any` and
// signals absence with nil, so the nil test IS the lookup result and not a
// defensive extra — every value this realm stores is a non-nil pointer.
func reg(owner address) (*register, bool) {
	v := regs.Get(owner.String())
	if v == nil {
		return nil, false
	}
	return v.(*register), true
}

func mustReg(owner address) *register {
	r, ok := reg(owner)
	if !ok {
		panic("assets: no register for " + owner.String())
	}
	return r
}

func mustAsset(r *register, id uint64) *asset {
	v := r.assets.Get(idKey(id))
	if v == nil {
		panic("assets: no asset " + strconv.FormatUint(id, 10))
	}
	return v.(*asset)
}

// idKey encodes an id so that avl's lexical key order matches numeric id
// order — the same encoding p/journal uses for entry ids, and for the same
// reason: without it, Render would list asset 10 before asset 2. 20 digits
// covers math.MaxUint64.
func idKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	const width = 20
	if len(s) >= width {
		return s
	}
	return zeros[:width-len(s)] + s
}

const zeros = "00000000000000000000"

func checkLabel(label string) {
	if strings.TrimSpace(label) == "" {
		panic("assets: label must not be blank")
	}
	if len(label) > MaxLabelLen {
		panic("assets: label too long, max " + strconv.Itoa(MaxLabelLen))
	}
}

func checkPeriod(periodBlocks int64) {
	if periodBlocks < MinPeriodBlocks {
		panic("assets: periodBlocks must be at least " +
			strconv.FormatInt(MinPeriodBlocks, 10) + " blocks")
	}
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

// OpenRegister creates the caller's register and opens its two accounts. It
// panics if the caller already has one.
//
// The chart is opened HERE rather than on demand, and the book is created
// with a cap of exactly two accounts. Both facts are load-bearing: they are
// why this realm is its book's only writer and why the CrossFoot identity is
// exact rather than approximate.
func OpenRegister(cur realm) {
	refuseCoins(cur)
	owner := cur.Previous().Address()
	key := owner.String()
	if regs.Has(key) {
		panic("assets: this address already has a register")
	}

	b := journal.MustNew(2, MaxEntriesPerRegister)
	b.MustOpen(ExpenseCode, ExpenseName, journal.Expense)
	b.MustOpen(AccumCode, AccumName, journal.Asset)

	regs.Set(key, &register{
		book:     b,
		assets:   avl.NewTree(),
		nextID:   1,
		openedAt: runtime.ChainHeight(),
	})
	regCount++
}

// Place records a straight-line asset placed in service at the current
// height, and returns its id.
//
// Nothing is posted: at placement zero periods have completed, so the charge
// is zero and a zero posting is not a valid journal entry. The first charge
// becomes bookable at placedAt + periodBlocks.
func Place(cur realm, label string, cost, salvage int64, life int32, periodBlocks int64) uint64 {
	refuseCoins(cur)
	r := mustOwnRegister(cur)
	checkLabel(label)
	checkPeriod(periodBlocks)

	s, err := depreciation.New(cost, salvage, life)
	if err != nil {
		panic(err)
	}
	return place(r, label, s, periodBlocks)
}

// PlaceDeclining records a declining-balance asset charging num/den of the
// remaining carrying amount each period. Double-declining over a 10-period
// life is num=2, den=10.
//
// Two properties of that method are inherited from p/depreciation and are
// visible in this realm's numbers, so they are repeated here. The final
// period absorbs whatever remains above salvage, so the last charge can be
// much larger than the one before it. And a schedule whose per-period charge
// truncates to zero (cost*num < den) never depreciates until that final
// period — [Due] reads 0 for its whole life, which is the schedule behaving
// as specified and not a stuck register.
func PlaceDeclining(cur realm, label string, cost, salvage int64, life int32, num, den, periodBlocks int64) uint64 {
	refuseCoins(cur)
	r := mustOwnRegister(cur)
	checkLabel(label)
	checkPeriod(periodBlocks)

	s, err := depreciation.NewDeclining(cost, salvage, life, num, den)
	if err != nil {
		panic(err)
	}
	return place(r, label, s, periodBlocks)
}

func place(r *register, label string, s depreciation.Schedule, periodBlocks int64) uint64 {
	if r.assets.Size() >= MaxAssetsPerRegister {
		panic("assets: register is full, max " + strconv.Itoa(MaxAssetsPerRegister))
	}
	at := runtime.ChainHeight()

	// Establish the end-of-life arithmetic NOW so FullyDepreciatedAt is a
	// total read for the asset's whole life. At chain heights it cannot
	// overflow, and that is exactly why checking is cheap and omitting it
	// would be a guess.
	if _, err := s.FullyDepreciatedAt(at, periodBlocks); err != nil {
		panic(err)
	}

	id := r.nextID
	r.nextID++
	r.assets.Set(idKey(id), &asset{
		id:       id,
		label:    label,
		sched:    s,
		placedAt: at,
		period:   periodBlocks,
	})
	return id
}

// BookThrough posts the depreciation charge for every period that has
// completed since this asset was last booked, and returns the period the
// asset is now booked through.
//
// It is IDEMPOTENT: calling it twice in one block, or twice in one period,
// posts once. Calling it after skipping ten periods posts the whole span as
// one entry, for the same total a caller who ran it every period would have
// reached — p/depreciation's Charge telescopes exactly, so booking cadence
// cannot change the total booked.
//
// A ZERO charge advances the mark and posts nothing. That is not a shortcut:
// journal rejects a posting of zero (ErrInvalidAmount), while a degenerate
// declining schedule legitimately charges zero, and the invariant is
// preserved exactly because AccumulatedAt is equal at both marks in precisely
// that case.
//
// Panics if the asset is retired, or if the book is full.
func BookThrough(cur realm, id uint64) int32 {
	refuseCoins(cur)
	r := mustOwnRegister(cur)
	a := mustAsset(r, id)
	if a.retired {
		panic("assets: asset " + strconv.FormatUint(id, 10) +
			" is retired and accrues no further charges")
	}
	n := elapsed(a)
	if n <= a.booked {
		return a.booked
	}
	bookSpan(r, a, n)
	return a.booked
}

// Retire books the asset through the current period and then stops it
// permanently. It returns the final amount posted, which may be zero.
//
// The booking is not optional and not separable: see the package doc. After
// this call the asset accrues nothing, BookThrough on it panics, and every
// historical charge stands.
//
// An asset already at or past the end of its life still retires cleanly —
// CarryingAt clamps at Salvage from Life onwards, so the final charge is
// whatever had not yet been booked and is zero if nothing had.
//
// IT PANICS IF THE BOOK IS FULL AND A CHARGE IS DUE, AND THAT REFUSAL IS
// PERMANENT. The booking is not separable, journal's Post is fail-closed
// before it writes, and a panic reverts the whole transaction — so an asset
// with an unbooked charge on a register that has reached
// MaxEntriesPerRegister can never be retired. BookThrough's identical panic
// is harmless (the charge simply stays unbooked and can be booked later if
// the book ever has room, which it never will, there being no archive); this
// one strands the asset permanently in the live state.
//
// It is reachable, and the arithmetic is the same one MaxEntriesPerRegister
// carries: about seven MaxLife assets booked period-by-period fill the book.
// The remedy is the same one the entry cap already has — a second register
// under a second address — and it has to be arranged BEFORE the book fills,
// which is why Capacity is exported and why the register page prints the
// entry headroom. Making Retire freeze without booking would be the obvious
// alternative and is refused: it would forfeit a charge that was genuinely
// incurred, which is the one thing this realm exists not to do.
func Retire(cur realm, id uint64) int64 {
	refuseCoins(cur)
	r := mustOwnRegister(cur)
	a := mustAsset(r, id)
	if a.retired {
		panic("assets: asset " + strconv.FormatUint(id, 10) + " is already retired")
	}

	before := a.amount
	if n := elapsed(a); n > a.booked {
		bookSpan(r, a, n)
	}
	a.retired = true
	a.retiredAt = runtime.ChainHeight()
	return a.amount - before
}

// bookSpan posts the charge for (a.booked, n] and advances the mark. It is
// the only writer of a.amount and a.booked, and the only caller of Post —
// which is what makes CrossFoot an exact identity rather than a heuristic.
func bookSpan(r *register, a *asset, n int32) {
	amt, err := a.sched.Charge(a.booked, n)
	if err != nil {
		panic(err)
	}
	if amt > 0 {
		memo := "depreciation: asset " + strconv.FormatUint(a.id, 10) +
			", periods " + strconv.FormatInt(int64(a.booked), 10) +
			"-" + strconv.FormatInt(int64(n), 10)
		postings := []journal.Posting{
			{Account: ExpenseCode, Side: journal.Debit, Amount: amt},
			{Account: AccumCode, Side: journal.Credit, Amount: amt},
		}
		if _, err := r.book.Post(runtime.ChainHeight(), memo, postings); err != nil {
			panic(err)
		}
		// a.amount + amt cannot overflow: the sum of telescoping charges
		// from period 0 is AccumulatedAt(n), which is at most Basis,
		// which is at most Cost.
		a.amount += amt
	}
	a.booked = n
}

// elapsed is the whole periods completed for an asset at the current height.
//
// Periods cannot fail here: period is at least MinPeriodBlocks (> 0), the
// current height is never below placedAt because placedAt was the height at
// placement and heights do not decrease, and the quotient of two chain
// heights cannot exceed maxInt32. The error is still read and panicked on
// rather than discarded, because every one of those three facts is an
// argument and not a check.
func elapsed(a *asset) int32 {
	n, err := depreciation.Periods(a.placedAt, runtime.ChainHeight(), a.period)
	if err != nil {
		panic(err)
	}
	return n
}

// ---------------------------------------------------------------------------
// Reads — all free, all taking an owner
// ---------------------------------------------------------------------------

// HasRegister reports whether an address has a register.
func HasRegister(owner address) bool { return regs.Has(owner.String()) }

// Registers is how many registers exist. There is deliberately no way to
// enumerate them or to aggregate across them: such a total would be the sum
// of every stranger's self-reported cost figures.
func Registers() int { return regCount }

// OpenedAt is the height a register was created.
func OpenedAt(owner address) int64 { return mustReg(owner).openedAt }

// AssetCount is how many assets a register holds, retired ones included.
func AssetCount(owner address) int { return mustReg(owner).assets.Size() }

// Height is the chain height this realm dates entries and periods with.
// Exposed so a caller can predict what BookThrough will book.
func Height() int64 { return runtime.ChainHeight() }

// AssetInfo reports an asset's whole stored state in one read.
//
// method is "straight-line" or "declining-balance"; rateNum and rateDen are
// 0 for a straight-line asset.
func AssetInfo(owner address, id uint64) (
	label string,
	cost, salvage int64,
	life int32,
	method string,
	rateNum, rateDen int64,
	placedAt, periodBlocks int64,
	bookedThrough int32,
	bookedAmount int64,
	retired bool,
	retiredAt int64,
) {
	a := mustAsset(mustReg(owner), id)
	return a.label, a.sched.Cost, a.sched.Salvage, a.sched.Life,
		a.sched.Method.String(), a.sched.RateNum, a.sched.RateDen,
		a.placedAt, a.period, a.booked, a.amount, a.retired, a.retiredAt
}

// Label is an asset's label.
func Label(owner address, id uint64) string { return mustAsset(mustReg(owner), id).label }

// BookedThrough is the high-water mark: the whole periods already charged.
func BookedThrough(owner address, id uint64) int32 {
	return mustAsset(mustReg(owner), id).booked
}

// BookedAmount is the cumulative expense posted for one asset.
func BookedAmount(owner address, id uint64) int64 {
	return mustAsset(mustReg(owner), id).amount
}

// PeriodsElapsed is the whole periods completed for an asset at the current
// height, whether or not they have been booked. For a retired asset this
// keeps increasing while BookedThrough does not, which is the intended
// difference and is why both are exported.
func PeriodsElapsed(owner address, id uint64) int32 {
	return elapsed(mustAsset(mustReg(owner), id))
}

// Due is the charge BookThrough would post for an asset right now. It is 0
// for a retired asset, for an asset with no newly-completed period, and for a
// degenerate declining schedule that has not reached its final period.
func Due(owner address, id uint64) int64 {
	a := mustAsset(mustReg(owner), id)
	if a.retired {
		return 0
	}
	n := elapsed(a)
	if n <= a.booked {
		return 0
	}
	amt, err := a.sched.Charge(a.booked, n)
	if err != nil {
		panic(err)
	}
	return amt
}

// CarryingAt is an asset's carrying amount after n whole periods: Cost at
// n <= 0, Salvage at every n >= Life. It reads the SCHEDULE and is
// independent of what has been booked.
func CarryingAt(owner address, id uint64, n int32) int64 {
	c, err := mustAsset(mustReg(owner), id).sched.CarryingAt(n)
	if err != nil {
		panic(err)
	}
	return c
}

// AccumulatedAt is Cost - CarryingAt(n): what the contra-asset balance for
// one asset SHOULD be once period n is booked.
func AccumulatedAt(owner address, id uint64, n int32) int64 {
	acc, err := mustAsset(mustReg(owner), id).sched.AccumulatedAt(n)
	if err != nil {
		panic(err)
	}
	return acc
}

// FullyDepreciatedAt is the height at which an asset first carries only its
// salvage value: placedAt + Life*periodBlocks. Validated at placement, so it
// cannot fail afterwards.
func FullyDepreciatedAt(owner address, id uint64) int64 {
	a := mustAsset(mustReg(owner), id)
	t, err := a.sched.FullyDepreciatedAt(a.placedAt, a.period)
	if err != nil {
		panic(err)
	}
	return t
}

// IsRetired reports whether an asset has been retired.
func IsRetired(owner address, id uint64) bool {
	return mustAsset(mustReg(owner), id).retired
}

// ---------------------------------------------------------------------------
// Reads — the book
// ---------------------------------------------------------------------------

// Balance is an account's balance in its NORMAL direction. For 1590 that is
// debit-normal and so reads negative; [AccumulatedCredit] is the figure a
// reader of a contra-asset wants.
func Balance(owner address, code string) (int64, bool) {
	a, ok := mustReg(owner).book.Account(code)
	if !ok {
		return 0, false
	}
	return a.Balance(), true
}

// RawBalance is an account's Debits - Credits, with no normal-direction
// adjustment.
func RawBalance(owner address, code string) (int64, bool) {
	a, ok := mustReg(owner).book.Account(code)
	if !ok {
		return 0, false
	}
	return a.RawDelta(), true
}

// AccountKind is an account's kind as a word: "asset" for 1590, "expense"
// for 5500. The second result is false for a code this chart does not hold.
//
// It exists because the chart's kinds are otherwise unobservable from
// outside. Both accounts are debit-normal, so neither [Balance] nor
// [Equation] can distinguish them, and the package doc's claim that 1590 is
// a contra-ASSET rather than a second expense account would be an assertion
// in a comment with nothing behind it. Opening 1590 as an Expense instead
// would leave every other read in this file identical.
func AccountKind(owner address, code string) (string, bool) {
	a, ok := mustReg(owner).book.Account(code)
	if !ok {
		return "", false
	}
	return a.Kind.String(), true
}

// AccumulatedCredit is the POSITIVE accumulated-depreciation figure: the
// credit balance of 1590, i.e. -RawDelta.
func AccumulatedCredit(owner address) int64 {
	a, ok := mustReg(owner).book.Account(AccumCode)
	if !ok {
		panic("assets: register has no " + AccumCode + " account")
	}
	return -a.RawDelta()
}

// ExpenseDebit is the total depreciation expense recognised: the debit
// balance of 5500.
func ExpenseDebit(owner address) int64 {
	a, ok := mustReg(owner).book.Account(ExpenseCode)
	if !ok {
		panic("assets: register has no " + ExpenseCode + " account")
	}
	return a.Balance()
}

// EntryCount is how many entries a register's book holds.
func EntryCount(owner address) int { return mustReg(owner).book.EntryCount() }

// Capacity reports how many more assets and entries a register can take.
func Capacity(owner address) (assetsLeft, entriesLeft int) {
	r := mustReg(owner)
	return MaxAssetsPerRegister - r.assets.Size(),
		MaxEntriesPerRegister - r.book.EntryCount()
}

// Totals is the book's total debits and credits. They are equal after every
// charge, because every entry is a matched pair.
func Totals(owner address) (debits, credits int64) {
	b := mustReg(owner).book
	return b.TotalDebits(), b.TotalCredits()
}

// IsBalanced reports whether the book's debits equal its credits.
func IsBalanced(owner address) bool { return mustReg(owner).book.IsBalanced() }

// Equation is the accounting equation: debit-normal against credit-normal.
// Both sides offset at 0 for this chart, because the only entry is an
// expense debit against a contra-ASSET credit — both legs are debit-normal
// accounts, so the expense adds and the contra subtracts.
func Equation(owner address) (debitNormal, creditNormal int64, offsets bool) {
	return mustReg(owner).book.AccountingEquation()
}

// Rederive re-walks every posting in the book and reports whether the
// account totals agree with the journal.
//
// It is a FREE read, unlike r/books' owner-only equivalent. The divergence is
// deliberate: this realm's claim is that its postings follow from its stored
// schedules, and a claim only the owner can check is not worth making. The
// cost is linear in the posting count, which is what MaxEntriesPerRegister
// bounds.
func Rederive(owner address) (debits, credits int64, agrees bool) {
	return mustReg(owner).book.RederiveFromJournal()
}

// ---------------------------------------------------------------------------
// The invariants
// ---------------------------------------------------------------------------

// Invariant is the per-asset derivation check:
//
//	bookedAmount == schedule.AccumulatedAt(bookedThrough)
//
// It returns the two figures and whether they agree. A false here means the
// realm posted an amount its own schedule does not imply, which no code path
// in this realm can produce — which is exactly why it is worth exporting:
// the claim is checkable by a third party rather than asserted in a comment.
func Invariant(owner address, id uint64) (booked, derived int64, agrees bool) {
	a := mustAsset(mustReg(owner), id)
	derived, err := a.sched.AccumulatedAt(a.booked)
	if err != nil {
		panic(err)
	}
	return a.amount, derived, a.amount == derived
}

// CrossFoot is the register-wide check: the sum of every asset's booked
// amount against the credit balance of 1590.
//
// The identity is EXACT, not approximate, and the reason is structural: this
// realm exposes no general posting entrypoint, so it is its book's only
// writer and bookSpan is the only code that posts. Adding a general Post
// would destroy this check, which is the cost of adding one.
//
// retired assets are included: their charges were really incurred and the
// 1590 credit they produced does not disappear when the asset stops.
func CrossFoot(owner address) (sumAssets, accumulated int64, agrees bool) {
	r := mustReg(owner)
	var sum int64
	r.assets.Iterate("", "", func(_ string, v any) bool {
		sum += v.(*asset).amount
		return false
	})
	acc, ok := r.book.Account(AccumCode)
	if !ok {
		panic("assets: register has no " + AccumCode + " account")
	}
	credit := -acc.RawDelta()
	return sum, credit, sum == credit
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// Render shows the realm index at "/" and one owner's register at
// "/<address>".
func Render(path string) string {
	p := strings.TrimSpace(strings.Trim(path, "/"))
	if p == "" {
		return renderIndex()
	}
	return renderRegister(address(p))
}

func renderIndex() string {
	var sb strings.Builder
	sb.WriteString("# assets — a fixed-asset register with derived postings\n\n")
	sb.WriteString("Depreciation schedules held as state, charges **derived** ")
	sb.WriteString("from the schedule and the chain height, and **no custody ")
	sb.WriteString("of any asset**.\n\n")

	sb.WriteString("> A general ledger takes the amount from its caller, so it ")
	sb.WriteString("cannot tell a double-booked month from a correct one. This ")
	sb.WriteString("realm never takes an amount: it keeps a per-asset ")
	sb.WriteString("high-water mark, so a charge can be neither repeated nor ")
	sb.WriteString("skipped. That is the whole product, and it proves ")
	sb.WriteString("arithmetic — not truth. Nothing here ties a cost figure ")
	sb.WriteString("to a real holding.\n\n")

	sb.WriteString("## State\n\n")
	sb.WriteString("- registers opened: **" + strconv.Itoa(regCount) + "**\n")
	sb.WriteString("- chain height: **" + strconv.FormatInt(runtime.ChainHeight(), 10) + "**\n\n")

	sb.WriteString("## The chart is two accounts and is fixed\n\n")
	sb.WriteString("| code | name | kind | normal |\n")
	sb.WriteString("|---|---|---|---|\n")
	sb.WriteString("| `" + ExpenseCode + "` | " + ExpenseName + " | expense | debit |\n")
	sb.WriteString("| `" + AccumCode + "` | " + AccumName + " | asset (**contra**) | debit |\n\n")
	sb.WriteString("Every entry is a debit to `" + ExpenseCode + "` against an ")
	sb.WriteString("equal credit to `" + AccumCode + "`. There is no way to open ")
	sb.WriteString("a third account, and the **cost basis never reaches the ")
	sb.WriteString("book** — booking it would need a liability or an equity ")
	sb.WriteString("plug asserting how the asset was funded, which this realm ")
	sb.WriteString("does not know.\n\n")
	sb.WriteString("`" + AccumCode + "` is an asset account, so its *normal* ")
	sb.WriteString("balance reads **negative**. The positive figure is ")
	sb.WriteString("`AccumulatedCredit`.\n\n")

	sb.WriteString("## Bounds\n\n")
	sb.WriteString("| bound | value |\n")
	sb.WriteString("|---|---|\n")
	sb.WriteString("| assets per register | " + strconv.Itoa(MaxAssetsPerRegister) + " |\n")
	sb.WriteString("| entries per register | " + strconv.Itoa(MaxEntriesPerRegister) + " |\n")
	sb.WriteString("| label length | " + strconv.Itoa(MaxLabelLen) + " |\n")
	sb.WriteString("| shortest period | " + strconv.FormatInt(MinPeriodBlocks, 10) + " blocks |\n\n")
	sb.WriteString("One asset is booked per call: the schedule loop's bound is ")
	sb.WriteString("unpriced upstream, so a bulk entrypoint would multiply an ")
	sb.WriteString("unpriced cost by the asset count.\n\n")

	sb.WriteString("## Reading a register\n\n")
	sb.WriteString("`" + RealmPath + ":<address>`\n")
	return sb.String()
}

func renderRegister(owner address) string {
	r, ok := reg(owner)
	if !ok {
		return "# No register\n\nNo register exists for `" +
			sanitize.InlineText(owner.String()) + "`.\n"
	}

	var sb strings.Builder
	sb.WriteString("# Register of " + sanitize.InlineText(owner.String()) + "\n\n")
	sb.WriteString("- opened at height: **" + strconv.FormatInt(r.openedAt, 10) + "**\n")
	sb.WriteString("- chain height: **" + strconv.FormatInt(runtime.ChainHeight(), 10) + "**\n")
	sb.WriteString("- assets: **" + strconv.Itoa(r.assets.Size()) + "** / " +
		strconv.Itoa(MaxAssetsPerRegister) + "\n")
	sb.WriteString("- entries: **" + strconv.Itoa(r.book.EntryCount()) + "** / " +
		strconv.Itoa(MaxEntriesPerRegister) + "\n\n")

	sum, credit, agrees := CrossFoot(owner)
	sb.WriteString("## Cross-foot\n\n")
	sb.WriteString("| figure | value |\n|---|---|\n")
	sb.WriteString("| sum of booked amounts | " + strconv.FormatInt(sum, 10) + " |\n")
	sb.WriteString("| `" + AccumCode + "` credit balance | " + strconv.FormatInt(credit, 10) + " |\n")
	sb.WriteString("| agrees | **" + yesno(agrees) + "** |\n")
	sb.WriteString("| book balanced | **" + yesno(r.book.IsBalanced()) + "** |\n\n")

	sb.WriteString("## Assets\n\n")
	if r.assets.Size() == 0 {
		sb.WriteString("_None placed yet._\n")
		return sb.String()
	}
	sb.WriteString("| id | label | method | cost | salvage | life | period | booked | amount | derived | ok | state |\n")
	sb.WriteString("|---|---|---|---|---|---|---|---|---|---|---|---|\n")

	shown := 0
	total := r.assets.Size()
	r.assets.Iterate("", "", func(_ string, v any) bool {
		if shown >= RenderAssetLimit {
			return true
		}
		a := v.(*asset)
		derived, err := a.sched.AccumulatedAt(a.booked)
		ok := err == nil && derived == a.amount
		state := "live"
		if a.retired {
			state = "retired at " + strconv.FormatInt(a.retiredAt, 10)
		}
		// The avl key is zero-padded to width 20 so lexical order matches
		// numeric order; the id column must print the id, not the key.
		sb.WriteString("| " + strconv.FormatUint(a.id, 10) + " | " + cell(a.label) + " | " +
			cell(a.sched.Method.String()) + " | " +
			strconv.FormatInt(a.sched.Cost, 10) + " | " +
			strconv.FormatInt(a.sched.Salvage, 10) + " | " +
			strconv.FormatInt(int64(a.sched.Life), 10) + " | " +
			strconv.FormatInt(a.period, 10) + " | " +
			strconv.FormatInt(int64(a.booked), 10) + " | " +
			strconv.FormatInt(a.amount, 10) + " | " +
			strconv.FormatInt(derived, 10) + " | " +
			yesno(ok) + " | " + state + " |\n")
		shown++
		return false
	})
	if shown < total {
		sb.WriteString("\n_Showing " + strconv.Itoa(shown) + " of " +
			strconv.Itoa(total) + " assets._\n")
	}
	return sb.String()
}

// cell renders a caller-supplied string into a table cell. A blank value
// would collapse the column, so it is shown as a dash.
func cell(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return sanitize.TableCell(s)
}

func yesno(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}
