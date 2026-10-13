// Package inventory is a per-owner inventory sub-ledger whose cost of goods
// sold is DERIVED from the lots on hand rather than asserted by a caller.
//
// # What this realm is for
//
// A general ledger takes a debit code, a credit code and an amount from
// whoever is posting. That is the right design for a ledger, and it means
// gno.land/r/.../books structurally CANNOT know that an entry was a shipment,
// or that the cost charged for that shipment is the cost the goods were
// actually bought at. Nothing stops a shipper from booking a flattering
// number, and nothing in the book can tell afterwards.
//
// This realm closes that gap for one class of entry. It holds each item's
// cost lots as state, and when goods ship it computes the charge from those
// lots by the item's declared costing method. The amount is never a
// parameter: [Ship] takes a QUANTITY and returns the cost it derived.
//
// The resulting claims are narrow and checkable by anyone, which is the point.
// Per item, from p/lots' own cross-foot:
//
//	receivedCost == chargedCost + costOnHand
//
// and, across a whole register, against the ledger the realm posted to:
//
//	balance(1300) == sum of costOnHand over items
//	balance(5000) == sum of chargedCost over items
//	balance(3900) == sum of receivedCost over items
//
// All four are exported — [ItemCrossFoot], [CrossFootInventory],
// [CrossFootCOGS], [CrossFootContributed] — and all are FREE reads,
// deliberately; see "Why the invariants are free reads" below.
//
// Note what the three ledger identities are NOT. Each compares a walk of the
// lots against an account balance, and the two are maintained by different
// code: the pool counts for itself inside p/lots, while this realm posts to
// the book. A disagreement is therefore a real signal and not a tautology.
// That is the same reason p/lots keeps counters beside its lots.
//
// # The chart is three accounts and is fixed
//
//	1300  Inventory                (asset,   debit-normal)
//	5000  Cost of goods sold       (expense, debit-normal)
//	3900  Inventory contributed    (equity,  credit-normal)
//
// A receipt is debit 1300 / credit 3900. A shipment is debit 5000 / credit
// 1300 for the DERIVED cost. There is no OpenAccount entrypoint and the
// underlying book is created with a hard cap of three accounts, so the chart
// cannot grow. The accounting equation offsets at 0 = 0 on an empty register
// and after every posting, because 1300 + 5000 == 3900 is the register-wide
// restatement of each pool's own cross-foot.
//
// # 3900 IS A PLUG, AND THIS REALM IS FORCED TO PICK ONE
//
// This is the design's one unavoidable assertion about the world, so it is
// stated here rather than buried.
//
// gno.land/r/.../assets faced the same question about an asset's cost basis
// and answered by NOT BOOKING IT: the only honest credit legs were a
// liability ("2000 Acquisition payable") or an equity plug ("3000 Contributed
// capital"), both of which assert how the asset was funded, which that realm
// does not know. It kept the cost in register state as data instead.
//
// That answer is not available here, and the difference is structural rather
// than a matter of taste. The product IS cost of goods sold. A shipment debits
// 5000 and credits 1300, so 1300 must carry a balance, so the receipt must
// reach the book — and a debit to 1300 needs a credit leg. The choice is
// therefore not "book it or not" but "which plug", and every candidate
// asserts something unobservable:
//
//   - 2000 Accounts payable asserts the goods were bought on credit and that
//     a liability is outstanding. This realm cannot see a payment, so the
//     liability would never be relieved and would grow without bound.
//   - 1000 Cash asserts the goods were paid for in cash from a balance this
//     realm does not hold and cannot verify. It holds no coins at all.
//   - 3900 Inventory contributed asserts the goods were contributed by the
//     owner. It is wrong in exactly the same way the other two are, and it is
//     the only one of the three that is SELF-CONSISTENT without an
//     unobservable second event: a contribution is complete on arrival.
//
// So 3900 was chosen because it needs no follow-up transaction to stay
// coherent, not because it is true. Read it as "goods arrived from somewhere
// this ledger does not model". A register whose goods were in fact purchased
// on credit is understating liabilities and overstating equity by exactly
// balance(3900), and no code path here can detect that. Pairing this
// sub-ledger with a real payables ledger is out of scope for v1 and is the
// honest fix.
//
// # Costing method is per item and is FIXED at creation
//
// An item is added by [AddFIFO], [AddLIFO] or [AddWAVG] — three entrypoints
// rather than one taking a method code, following r/assets' Place /
// PlaceDeclining precedent, so a caller never has to know an enum's numbering.
//
// p/lots fixes the method at pool construction and documents why: changing it
// mid-life would recost nothing already charged but would change what the next
// shipment costs, which is a restatement a sub-ledger must not be able to make
// silently. This realm inherits that and adds nothing: there is no entrypoint
// that changes an item's method. An owner who must switch opens a new SKU and
// discloses it.
//
// The three methods differ observably, which is the point of having them:
// FIFO and LIFO charge different amounts whenever unit costs differ, and WAVG
// re-anchors every receipt into a single merged lot so it holds exactly one
// lot and can never hit the per-item lot cap.
//
// That exemption is not a free win, and the trade is the other way round from
// how it reads. WAVG escapes the LOT cap and in exchange acquires a refusal
// FIFO and LIFO do not have: a merged lot must satisfy p/lots' per-lot
// overflow precondition `Cost <= maxInt64/Qty`, and two lots that each satisfy
// it separately can merge into one that does not. So under WAVG a receipt can
// be refused for the pool's ACCUMULATED HISTORY rather than for anything about
// the receipt — the same receipt a FIFO item would have taken. It is a far
// corner of the arithmetic and not a practical bound, but it is the reason
// [LotCapacity] is the wrong thing to watch for a WAVG item: its figure is a
// bound WAVG will never approach, so a caller sizing headroom from it is
// reading the one limit that does not apply. See p/lots' Pool.Receive.
//
// # A ZERO-COST POSTING IS SKIPPED, AND THAT IS NOT A SHORTCUT
//
// p/journal rejects a posting of zero (ErrInvalidAmount) — correctly; a zero
// entry is not an event. But both of this realm's postings can legitimately be
// zero:
//
//   - [Receive] with cost 0 is free goods, which p/lots accepts (ErrBadCost is
//     only for a NEGATIVE cost).
//   - [Ship] out of lots that cost nothing derives a charge of 0.
//
// In both cases the pool is updated and NOTHING is posted. The identities
// above are preserved exactly, because a zero contribution to the ledger side
// is matched by a zero contribution to the walk side. The same choice r/assets
// makes for a degenerate declining schedule, for the same reason.
//
// # What this realm does NOT do
//
//   - No custody. It holds no coins, has no withdrawal path, and refuses a
//     user call that arrives carrying any. A cost is a number an owner typed.
//   - No write-off, shrinkage or revaluation. Shrinkage is a real inventory
//     event and its absence is a real limitation: there is currently no way to
//     remove goods without charging them to 5000, so a loss is indistinguish-
//     able from a sale. The posting it needs is a debit to a 5-series loss
//     account against a credit to 1300, which means a fourth account and a
//     fourth entrypoint. Deliberately deferred to keep the chart fixed at
//     three for v1, and named here rather than discovered later.
//   - No revenue. A shipment books its COST, never a sale price. Revenue
//     belongs to a receivables ledger (r/invoices) and tying the two together
//     would require this realm to learn what was sold for how much.
//   - No period close. p/journal can seal a book up to a HEIGHT; sealing a
//     derived book could only make the next derivation unpostable. The
//     capability exists in the engine and is deliberately not exposed.
//   - No bulk receive or ship. One item per call — see the bound below.
//   - No truth. A sub-ledger is a set of claims by its owner. With no custody
//     there is nothing tying "received 100 units at cost 5000" to a real
//     holding. The invariants here prove that the postings follow from the
//     stored lots; they prove nothing about the world.
//
// # Why the invariants are free reads, and what the bound costs
//
// r/books exposes Rederive as an owner-only crossing function, to contain the
// cost of a full re-walk. This realm diverges, deliberately and for the same
// reason r/assets does: the derivation IS the product, and a claim only its
// owner can check is not a claim worth making. [Rederive], [ItemCrossFoot],
// the three register cross-foots and [Render] are all free reads, so any third
// party can verify a register from vm/qeval with no key.
//
// MaxLotsPerItem is 64 against p/lots' own MaxLotsLimit of 1024, and the gap
// is not timidity. p/lots' audit left the cost of its O(live lots) walks
// explicitly UNPRICED and recorded that a realm rendering many pools must
// measure its own gas. This realm is that realm, so the figures are measured
// rather than reasoned about, under the pinned onyx toolchain.
//
// There are TWO cost axes, not one, and this paragraph used to name only the
// first: MaxItemsPerRegister*MaxLotsPerItem live lots, and separately
// MaxEntriesPerRegister postings. It called 64 items of 64 live lots "the worst
// case this realm can hold", which is false — a register can sit at the lot cap
// and the entry cap AT ONCE. It was also claimed in review that the two are
// mutually exclusive by construction; that is wrong too. A one-unit FIFO
// shipment draws from the oldest lot, which holds 100 units, so 64 of them
// never exhaust it: 64 items x 64 receipts then 64 items x 64 one-unit
// shipments leaves 4096 live lots and exactly 8192 entries. The figures below
// were taken on a register asserted in-fixture to sit at all three caps
// simultaneously, so the combined shape is measured and not argued about.
//
// Free reads, net of a trivial-read baseline on the same register:
//
//	Rederive                 506,486,523
//	Render, register page    186,179,474
//	CrossFoot                 96,213,741
//	Render, item page          6,467,621
//	Render, index                192,716
//
// The dearest is 16.9% of the 3,000,000,000 maxGasQuery. The two axes do not
// compose in any single read's price, because no single read walks both:
// Rederive walks postings and reads no lot, while CrossFoot and Render walk
// lots and read three accounts plus EntryCount. Measured rather than inferred —
// Rederive at the lot cap agrees with the same read on a lot-cheap register
// (506,495,345) to 0.002%, which is what proves the lot axis does not price it.
// So the ceiling is the MAX of the two axes and never their product.
//
// A bound is not a price, and one item per call is what keeps the write side
// cheap: [Receive] and [Ship] each touch exactly one pool. Measured on the same
// toolchain, net of the same kind of baseline:
//
//	Receive creating the 64th lot        930,676
//	Ship of all OnHand, dropping all 64 lots  11,837,593
//	Receive refused at the lot cap       304,454
//
// The dearest write is 2.3% of the dearest read, so the read side is what the
// caps exist for. See DEPLOY_READINESS.md for the transcript, the per-header
// GAS pairing rule, and the two limits of these figures: they came from
// throwaway test files that were deleted rather than committed, so they are
// reproducible but NOT guarded by the suite; and gno test's GAS line covers a
// whole test function, so a figure is only a call's own price when the fixture
// that enables it lives in a separate test. Both halves bit: the refused
// receipt first measured at 53,123,019 — 174x its real price — because its
// 64-lot fixture shared its GAS line.
//
// # Deploy order
//
// This realm imports p/journal and p/lots, so on any chain the order is
// p/journal, p/lots, then this realm. The order is stated and the deployment
// STATE of either import deliberately is not: a sentence about what is
// deployed is true at signing time at best, and addpkg freezes it — r/assets
// carries exactly that fossil. The import relation is the durable fact.
package inventory

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/lots"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/inventory"

// The fixed chart. The codes follow r/books' convention, where an account's
// LEADING DIGIT fixes its kind: 1 asset, 2 liability, 3 equity, 4 revenue,
// 5 expense. A six-series code would be an invalid account under that
// convention, which is why cost of goods sold is 5000 and not the 6000 some
// charts use.
const (
	InventoryCode = "1300"
	InventoryName = "Inventory"

	COGSCode = "5000"
	COGSName = "Cost of goods sold"

	ContribCode = "3900"
	ContribName = "Inventory contributed"
)

// MaxItemsPerRegister caps one owner's SKU count. Every register-wide
// cross-foot walks every item's lots, and this bound is half of what keeps
// those reads affordable for everyone.
const MaxItemsPerRegister = 64

// MaxLotsPerItem caps one item's LIVE lots, well below p/lots' MaxLotsLimit of
// 1024. It is the other half of the read bound: the worst case a register-wide
// walk must visit is MaxItemsPerRegister*MaxLotsPerItem lots.
//
// Exhausted lots are dropped by p/lots, so this bounds concurrent lots and not
// the number of receipts an item may ever take. A WAVG item merges every
// receipt into one lot and so can never reach it — which means this is NOT the
// binding constraint for a WAVG item, and that item has a merge-overflow
// refusal of its own instead. See the package doc.
const MaxLotsPerItem = 64

// MaxEntriesPerRegister caps one owner's journal, far below journal's
// MaxEntriesLimit of 1000000 because Rederive is linear in the posting count
// and is a free read here.
//
// A register that fills refuses further receipts and shipments rather than
// dropping history. There is deliberately no Archive — it would destroy the
// record the invariants are checked against — so the remedy is a second
// register under a second address, which is a real limitation and not a
// hidden one.
const MaxEntriesPerRegister = 8192

// MaxSKULen bounds a SKU, which is an avl key, a Render table cell and a
// Render path component all at once.
const MaxSKULen = 32

// MaxItemNameLen bounds an item's human name. Every name is a candidate for
// Render output.
const MaxItemNameLen = 64

// RenderItemLimit caps how many items one register page tabulates.
const RenderItemLimit = 25

// RenderLotLimit caps how many lots one item page tabulates.
const RenderLotLimit = 20

// maxInt64 is the largest int64. It is a precondition of the counter guards
// below, so it is pinned BY BEHAVIOUR in the suite rather than by a test that
// restates the literal: TestMaxInt64IsTheInt64Maximum proves it wraps when
// incremented.
const maxInt64 int64 = 9223372036854775807

// register is one owner's inventory sub-ledger and the book its postings go
// to.
//
// The book and every pool are POINTERS and none is ever returned by any
// exported function — p/journal consumer obligation 4 and the identical rule
// for p/lots: a *Book is a mutable handle and a *Pool is a mutable handle, and
// handing either across a realm boundary would hand out the right to post or
// to consume.
type register struct {
	book     *journal.Book
	items    *avl.Tree // sku -> *item
	openedAt int64
}

// item is one stock-keeping unit and its cost pool.
type item struct {
	// sku is carried in the value as well as the tree key. The key IS the
	// sku here — unlike r/assets, whose keys are zero-padded ids — so this
	// is a convenience rather than a second encoding to keep in step.
	sku     string
	name    string
	pool    *lots.Pool
	addedAt int64

	// The posted counters, maintained INDEPENDENTLY of the pool. Each is the
	// cumulative amount this realm actually posted for this item, so
	// comparing one against the pool's own figure compares two things rather
	// than restating one. That is the whole of [Invariant].
	postedRecv int64
	postedCOGS int64
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
// exercising it exists today. It is a no-op at every call site here, and that
// claim has one more hop in this realm than in its siblings: addItem is itself
// non-crossing and forwards the cur it was given, so the chain is
// AddFIFO/AddLIFO/AddWAVG -> addItem -> here. Every link forwards a crossing
// entrypoint's OWN first cur, which is runtime-current by construction and
// stays current through any number of non-crossing calls — so the guard still
// never fires, and the extra hop is exactly why having it at the point of USE
// rather than at the entrypoints is the right placement. It is kept because
// this realm is IMMUTABLE after addpkg. p/coinio guards the same shape in
// Receive, Payout and Sweep; this is that house precedent applied.
//
// No count of the call sites is written down, per CLAUDE.md § 4a.
func refuseCoins(cur realm) {
	if !cur.IsCurrent() {
		panic("inventory: refuseCoins called with a realm that is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("inventory: this realm holds no coins and has no withdrawal path; send none")
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
// rather than one that only refuses coins. The addItem hop described above
// applies here too. The guard is a no-op today for the same reason, kept for
// the same reason, and its call sites are likewise not counted here. See
// AUDIT.md.
func mustOwnRegister(cur realm) *register {
	if !cur.IsCurrent() {
		panic("inventory: mustOwnRegister called with a realm that is not current")
	}
	owner := cur.Previous().Address()
	r, ok := reg(owner)
	if !ok {
		panic("inventory: no register for " + owner.String() + "; call OpenRegister first")
	}
	return r
}

// reg looks an owner's register up. avl's Get returns a bare `any` and signals
// absence with nil, so the nil test IS the lookup result and not a defensive
// extra — every value this realm stores is a non-nil pointer.
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
		panic("inventory: no register for " + owner.String())
	}
	return r
}

func mustItem(r *register, sku string) *item {
	v := r.items.Get(sku)
	if v == nil {
		panic("inventory: no item " + sanitize.InlineText(sku))
	}
	return v.(*item)
}

// checkSKU validates a SKU against a deliberately narrow charset:
// A-Z, a-z, 0-9, '.', '_' and '-'.
//
// The restriction buys three things at once, which is why it is worth imposing
// on a caller. A SKU is an avl KEY, so its byte order is the Render table's
// row order. It is a Render PATH COMPONENT, so a '/' would forge a route and a
// '?' or '#' would truncate one. And it is a markdown TABLE CELL, so a '|'
// would forge a column. Escaping at each use site would be three chances to
// miss one; a charset is checked once, here, on the way in.
//
// Case is significant and "sku-1" and "SKU-1" are different items. That is a
// real sharp edge for a human operator and is the honest reading of a key:
// folding case would mean this realm, not the owner, decides which SKUs
// collide.
func checkSKU(sku string) {
	if sku == "" {
		panic("inventory: sku must not be blank")
	}
	if len(sku) > MaxSKULen {
		panic("inventory: sku too long, max " + strconv.Itoa(MaxSKULen))
	}
	for i := 0; i < len(sku); i++ {
		c := sku[i]
		switch {
		case c >= 'A' && c <= 'Z':
		case c >= 'a' && c <= 'z':
		case c >= '0' && c <= '9':
		case c == '.' || c == '_' || c == '-':
		default:
			panic("inventory: sku may use only letters, digits, '.', '_' and '-'")
		}
	}
}

func checkItemName(name string) {
	if strings.TrimSpace(name) == "" {
		panic("inventory: name must not be blank")
	}
	if len(name) > MaxItemNameLen {
		panic("inventory: name too long, max " + strconv.Itoa(MaxItemNameLen))
	}
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

// OpenRegister creates the caller's register and opens its three accounts. It
// panics if the caller already has one.
//
// The chart is opened HERE rather than on demand, and the book is created with
// a cap of exactly three accounts. Both facts are load-bearing: they are why
// this realm is its book's only writer and why the cross-foot identities are
// exact rather than approximate.
func OpenRegister(cur realm) {
	refuseCoins(cur)
	owner := cur.Previous().Address()
	key := owner.String()
	if regs.Has(key) {
		panic("inventory: this address already has a register")
	}

	b := journal.MustNew(3, MaxEntriesPerRegister)
	b.MustOpen(InventoryCode, InventoryName, journal.Asset)
	b.MustOpen(COGSCode, COGSName, journal.Expense)
	b.MustOpen(ContribCode, ContribName, journal.Equity)

	regs.Set(key, &register{
		book:     b,
		items:    avl.NewTree(),
		openedAt: runtime.ChainHeight(),
	})
	regCount++
}

// AddFIFO adds an item whose shipments are costed oldest-lot-first.
func AddFIFO(cur realm, sku, name string) {
	addItem(cur, sku, name, lots.FIFO)
}

// AddLIFO adds an item whose shipments are costed newest-lot-first.
func AddLIFO(cur realm, sku, name string) {
	addItem(cur, sku, name, lots.LIFO)
}

// AddWAVG adds an item whose receipts are merged into a single re-anchored lot
// and whose shipments are costed at the blended unit cost.
//
// A WAVG item holds exactly one lot however many receipts it takes, so it can
// never reach MaxLotsPerItem. It can still refuse a receipt: the MERGE has an
// overflow precondition the other two methods never evaluate, and it is a
// property of the pool's accumulated history rather than of the receipt. See
// the package doc; the practical consequence is that [LotCapacity] is not the
// figure to watch for a WAVG item.
func AddWAVG(cur realm, sku, name string) {
	addItem(cur, sku, name, lots.WAVG)
}

func addItem(cur realm, sku, name string, m lots.Method) {
	refuseCoins(cur)
	r := mustOwnRegister(cur)
	checkSKU(sku)
	checkItemName(name)

	if r.items.Has(sku) {
		panic("inventory: item " + sanitize.InlineText(sku) + " already exists")
	}
	if r.items.Size() >= MaxItemsPerRegister {
		panic("inventory: register is full, max " + strconv.Itoa(MaxItemsPerRegister) + " items")
	}

	p, err := lots.NewPool(m, MaxLotsPerItem)
	if err != nil {
		panic(err)
	}
	r.items.Set(sku, &item{
		sku:     sku,
		name:    name,
		pool:    p,
		addedAt: runtime.ChainHeight(),
	})
}

// Receive takes qty units costing cost in total into the item's pool and posts
// debit 1300 / credit 3900, returning the entry id.
//
// A cost of ZERO is accepted — free goods — and posts nothing; the returned id
// is then 0, which is not a valid entry id and is the signal that no entry was
// made. See the package doc.
//
// Panics if the item does not exist, if qty is not positive, if cost is
// negative, if the pool's lot cap is reached, if a WAVG merge would breach the
// per-lot overflow precondition — a refusal that depends on the item's history
// and not on this receipt, see [AddWAVG] — or if the book is full. Every
// one of those aborts the whole transaction, which is what makes the
// pool-then-post order safe: an error return would NOT revert the pool update,
// a panic does.
func Receive(cur realm, sku string, qty, cost int64) uint64 {
	refuseCoins(cur)
	r := mustOwnRegister(cur)
	it := mustItem(r, sku)

	if err := it.pool.Receive(qty, cost); err != nil {
		panic(err)
	}

	// Guard the realm's own counter before committing it. The bound argument
	// says this cannot fire — postedRecv tracks pool.ReceivedCost() exactly,
	// and p/lots already refused to let that overflow — and it is written
	// anyway, because "unreachable" is an argument about code that may be
	// edited and the cost of being wrong here is a silently negative
	// inventory figure. p/lots' CostOnHand makes the same trade for the same
	// reason.
	if it.postedRecv > maxInt64-cost {
		panic("inventory: posted receipt counter would overflow")
	}
	it.postedRecv += cost

	if cost == 0 {
		return 0
	}
	return r.book.MustPost(runtime.ChainHeight(), "receive "+sku, []journal.Posting{
		{Account: InventoryCode, Side: journal.Debit, Amount: cost},
		{Account: ContribCode, Side: journal.Credit, Amount: cost},
	})
}

// Ship consumes qty units from the item's pool and posts debit 5000 /
// credit 1300 for the cost it DERIVED, returning that cost.
//
// The cost is never a parameter. It is whatever the item's costing method
// charges against the lots on hand, which is the whole product.
//
// A derived cost of ZERO posts nothing — goods that cost nothing to acquire
// cost nothing to ship. The return value is then 0 and so is indistinguishable
// from "no entry made", deliberately: both facts are the same fact here.
//
// Panics if the item does not exist, if qty is not positive, if qty exceeds
// the quantity on hand (p/lots fails closed with ErrInsufficient and consumes
// nothing), or if the book is full.
func Ship(cur realm, sku string, qty int64) int64 {
	refuseCoins(cur)
	r := mustOwnRegister(cur)
	it := mustItem(r, sku)

	charge, err := it.pool.Consume(qty)
	if err != nil {
		panic(err)
	}

	// Same trade as Receive's guard, and the same bound argument: postedCOGS
	// tracks pool.ChargedCost(), whose accumulation p/lots guards.
	if it.postedCOGS > maxInt64-charge {
		panic("inventory: posted COGS counter would overflow")
	}
	it.postedCOGS += charge

	if charge == 0 {
		return 0
	}
	r.book.MustPost(runtime.ChainHeight(), "ship "+sku, []journal.Posting{
		{Account: COGSCode, Side: journal.Debit, Amount: charge},
		{Account: InventoryCode, Side: journal.Credit, Amount: charge},
	})
	return charge
}

// Rename changes an item's human name. The SKU, the costing method and every
// lot are immutable; a name is presentation only and nothing derives from it.
func Rename(cur realm, sku, name string) {
	refuseCoins(cur)
	r := mustOwnRegister(cur)
	it := mustItem(r, sku)
	checkItemName(name)
	it.name = name
}

// ---------------------------------------------------------------------------
// Reads — register
// ---------------------------------------------------------------------------

// HasRegister reports whether an address has opened a register.
func HasRegister(owner address) bool { return regs.Has(owner.String()) }

// Registers is how many registers exist across the realm.
func Registers() int { return regCount }

// OpenedAt is the height an owner's register was opened at.
func OpenedAt(owner address) int64 { return mustReg(owner).openedAt }

// ItemCount is how many items an owner's register holds.
func ItemCount(owner address) int { return mustReg(owner).items.Size() }

// Height is the current chain height, so a reader can date every other figure
// on this page without a second query.
func Height() int64 { return runtime.ChainHeight() }

// SKUs lists an owner's SKUs in key order, starting at or after from and
// returning at most limit of them. An empty from starts at the beginning.
//
// This enumerator exists because its absence is a known defect elsewhere in
// this portfolio: r/books exposes no account enumerator, so a third party
// cannot discover what to ask it about without already knowing. A sub-ledger
// whose invariants are per-item is useless to a verifier who cannot list the
// items, so the list is part of the product rather than an afterthought.
//
// A non-positive limit returns nothing rather than everything. The cap is the
// item cap, so a caller may always page the whole register.
func SKUs(owner address, from string, limit int) []string {
	r := mustReg(owner)
	if limit <= 0 {
		return nil
	}
	if limit > MaxItemsPerRegister {
		limit = MaxItemsPerRegister
	}
	out := make([]string, 0, limit)
	r.items.Iterate(from, "", func(k string, _ any) bool {
		if len(out) >= limit {
			return true
		}
		out = append(out, k)
		return false
	})
	return out
}

// ---------------------------------------------------------------------------
// Reads — item
// ---------------------------------------------------------------------------

// HasItem reports whether an owner's register holds a SKU.
func HasItem(owner address, sku string) bool {
	r, ok := reg(owner)
	if !ok {
		return false
	}
	return r.items.Has(sku)
}

// ItemName is an item's human name.
func ItemName(owner address, sku string) string {
	return mustItem(mustReg(owner), sku).name
}

// Method is an item's costing method, as "fifo", "lifo" or
// "weighted-average".
func Method(owner address, sku string) string {
	return mustItem(mustReg(owner), sku).pool.Method().String()
}

// AddedAt is the height an item was added at.
func AddedAt(owner address, sku string) int64 {
	return mustItem(mustReg(owner), sku).addedAt
}

// OnHand is the quantity of an item on hand, DERIVED by walking its live lots
// rather than read from a counter — which is what makes [ItemCrossFootQty] a
// comparison rather than a tautology.
func OnHand(owner address, sku string) int64 {
	return mustItem(mustReg(owner), sku).pool.QtyOnHand()
}

// CostOnHand is the carrying value of an item's live lots: the figure this
// item contributes to the 1300 balance. Derived, for the same reason as
// [OnHand].
func CostOnHand(owner address, sku string) int64 {
	c, err := mustItem(mustReg(owner), sku).pool.CostOnHand()
	if err != nil {
		panic(err)
	}
	return c
}

// Received is an item's cumulative received quantity and cost.
func Received(owner address, sku string) (qty, cost int64) {
	p := mustItem(mustReg(owner), sku).pool
	return p.ReceivedQty(), p.ReceivedCost()
}

// Charged is an item's cumulative shipped quantity and the cost charged out
// for it. The cost figure is derived: no caller has ever supplied it.
func Charged(owner address, sku string) (qty, cost int64) {
	p := mustItem(mustReg(owner), sku).pool
	return p.ConsumedQty(), p.ChargedCost()
}

// Receipts is how many receipts an item has taken, including those whose lots
// are exhausted and dropped. It is NOT the live lot count — see [LotCount].
func Receipts(owner address, sku string) int64 {
	return mustItem(mustReg(owner), sku).pool.ReceiptCount()
}

// LotCount is how many LIVE lots an item holds. Exhausted lots are dropped.
func LotCount(owner address, sku string) int {
	return mustItem(mustReg(owner), sku).pool.LotCount()
}

// LotAt reports the i'th live lot of an item in receipt order, and whether i
// was in range. It returns primitives rather than a p/lots.Lot so that the
// figures are readable from vm/qeval without the caller knowing that type.
func LotAt(owner address, sku string, i int) (qty, cost, consumed, remaining, remainingCost int64, ok bool) {
	l, found := mustItem(mustReg(owner), sku).pool.Lot(i)
	if !found {
		return 0, 0, 0, 0, 0, false
	}
	rc, err := l.RemainingCost()
	if err != nil {
		panic(err)
	}
	return l.Qty, l.Cost, l.Consumed, l.Remaining(), rc, true
}

// Capacity reports how much room an owner's register has left.
func Capacity(owner address) (itemsLeft, entriesLeft int) {
	r := mustReg(owner)
	return MaxItemsPerRegister - r.items.Size(), MaxEntriesPerRegister - r.book.EntryCount()
}

// LotCapacity reports how many further live lots one item can hold. A WAVG
// item merges into one lot, so its figure is a bound it will never approach —
// and reading headroom off it for a WAVG item is therefore reading the wrong
// limit, because the refusal that CAN bind there is a merge overflow this
// figure knows nothing about. See [AddWAVG].
func LotCapacity(owner address, sku string) int {
	return MaxLotsPerItem - mustItem(mustReg(owner), sku).pool.LotCount()
}

// ---------------------------------------------------------------------------
// Reads — the ledger
// ---------------------------------------------------------------------------

// Balance returns an account's balance in its NORMAL direction and whether the
// code exists. All three of this realm's accounts are normal, so all three
// read non-negative.
func Balance(owner address, code string) (int64, bool) {
	return mustReg(owner).book.Balance(code)
}

// RawBalance returns debits minus credits regardless of kind. Summed over the
// three accounts it is exactly zero in a balanced book, which is what makes it
// the useful figure for a consistency check and the wrong one for a report.
func RawBalance(owner address, code string) (int64, bool) {
	a, ok := mustReg(owner).book.Account(code)
	if !ok {
		return 0, false
	}
	return a.RawDelta(), true
}

// AccountKind returns an account's kind as a word, and whether it exists.
func AccountKind(owner address, code string) (string, bool) {
	a, ok := mustReg(owner).book.Account(code)
	if !ok {
		return "", false
	}
	return a.Kind.String(), true
}

// InventoryDebit is the 1300 balance: the value of goods on hand per the
// ledger.
func InventoryDebit(owner address) int64 {
	b, ok := mustReg(owner).book.Balance(InventoryCode)
	if !ok {
		panic("inventory: register has no " + InventoryCode + " account")
	}
	return b
}

// COGSDebit is the 5000 balance: everything ever charged out as cost of goods
// sold.
func COGSDebit(owner address) int64 {
	b, ok := mustReg(owner).book.Balance(COGSCode)
	if !ok {
		panic("inventory: register has no " + COGSCode + " account")
	}
	return b
}

// ContributedCredit is the 3900 balance. Read it as "goods arrived from
// somewhere this ledger does not model" — see the package doc on why 3900 is a
// plug this realm is forced to pick.
func ContributedCredit(owner address) int64 {
	b, ok := mustReg(owner).book.Balance(ContribCode)
	if !ok {
		panic("inventory: register has no " + ContribCode + " account")
	}
	return b
}

// EntryCount is how many entries an owner's book holds.
func EntryCount(owner address) int { return mustReg(owner).book.EntryCount() }

// Totals are the book's total debits and credits.
func Totals(owner address) (debits, credits int64) {
	b := mustReg(owner).book
	return b.TotalDebits(), b.TotalCredits()
}

// IsBalanced reports whether total debits equal total credits.
func IsBalanced(owner address) bool { return mustReg(owner).book.IsBalanced() }

// Equation reports the accounting equation: debit-normal against
// credit-normal, and whether they offset. For this realm that is
// 1300 + 5000 against 3900, which offsets at 0 = 0 on an empty register and
// after every posting.
//
// READ THE SIGN BEFORE PRESENTING EITHER FIGURE. journal partitions RAW
// DELTAS — debits minus credits — so creditNormal is NEGATIVE whenever 3900
// carries a credit balance, and `offsets` means debitNormal + creditNormal
// == 0, not debitNormal == creditNormal. The textbook "assets = equity" has
// both sides positive; this does not. A caller rendering a balance sheet
// wants -creditNormal. The first test written against this function asserted
// the right magnitude with the wrong sign and was red for it, which is why
// this paragraph exists rather than a reader discovering it.
//
// What `offsets` does NOT prove is journal's obligation 7, inherited here
// verbatim: the two subtotals are a partition of the same addends, so
// reclassifying every account in the chart changes both and leaves `offsets`
// true. A Kind set wrongly at Open time is invisible to it. What pins this
// realm's chart is the PAIR — debitNormal == InventoryDebit + COGSDebit and
// creditNormal == -ContributedCredit — and the suite asserts exactly that.
//
// Sharper than that, because the partition is arithmetically inert: the two
// subtotals are added back together, so `offsets` reduces to
// Σ debits == Σ credits over the whole chart, which is the FIRST of the three
// conjuncts [IsBalanced] checks. A balanced book therefore always offsets, and
// `offsets` carries no fact [IsBalanced] has not already carried more
// strongly. The informative half of this function is the PAIR OF FIGURES, not
// the boolean — the figures move when a Kind changes and the boolean does not.
// (The two walks accumulate in different orders, so a mid-sum overflow could
// in principle separate them. At 8192 entries it would take amounts no
// register can reach, and it is not a second independent check.)
func Equation(owner address) (debitNormal, creditNormal int64, offsets bool) {
	return mustReg(owner).book.AccountingEquation()
}

// Rederive re-walks every posting in the book and reports whether the account
// totals agree with the journal.
//
// It is a FREE read, unlike r/books' owner-only equivalent, for the reason
// given in the package doc. The cost is linear in the posting count, which is
// what MaxEntriesPerRegister bounds.
func Rederive(owner address) (debits, credits int64, agrees bool) {
	return mustReg(owner).book.RederiveFromJournal()
}

// ---------------------------------------------------------------------------
// The invariants
// ---------------------------------------------------------------------------

// Invariant is the per-item derivation check, and it is this realm's central
// claim:
//
//	postedCOGS == pool.ChargedCost()
//
// The left figure is what this realm posted to 5000 for the item; the right is
// what the pool says it charged. They are maintained by different code in
// different packages, so a false here means the realm posted an amount its own
// lots do not imply — which no code path in this realm can produce, and which
// is exactly why it is worth exporting. A claim is worth more checkable by a
// stranger than asserted in a comment.
//
// The receipt side is checked the same way by [InvariantReceipts].
func Invariant(owner address, sku string) (posted, derived int64, agrees bool) {
	it := mustItem(mustReg(owner), sku)
	d := it.pool.ChargedCost()
	return it.postedCOGS, d, it.postedCOGS == d
}

// InvariantReceipts is [Invariant] for the receipt side:
//
//	postedRecv == pool.ReceivedCost()
func InvariantReceipts(owner address, sku string) (posted, derived int64, agrees bool) {
	it := mustItem(mustReg(owner), sku)
	d := it.pool.ReceivedCost()
	return it.postedRecv, d, it.postedRecv == d
}

// ItemCrossFoot is p/lots' own cost identity for one item:
//
//	receivedCost == chargedCost + costOnHand
//
// Received and charged are counters; on-hand is a walk of the live lots. The
// identity therefore compares two independently maintained things, which is
// why p/lots keeps them apart.
func ItemCrossFoot(owner address, sku string) (received, charged, onHand int64, foots bool) {
	return mustItem(mustReg(owner), sku).pool.CrossFootCost()
}

// ItemCrossFootQty is the quantity identity for one item:
//
//	receivedQty == consumedQty + qtyOnHand
//
// It is not implied by [ItemCrossFoot]: costs and quantities can disagree
// independently, and a bug that moved cost without moving quantity would be
// invisible to the cost identity alone.
func ItemCrossFootQty(owner address, sku string) (received, consumed, onHand int64, foots bool) {
	return mustItem(mustReg(owner), sku).pool.CrossFootQty()
}

// CrossFootInventory is the register-wide check on 1300: the sum of every
// item's carrying value against the ledger balance.
//
// The identity is EXACT, not approximate, and the reason is structural: this
// realm exposes no general posting entrypoint, so it is its book's only
// writer. Adding a general Post would destroy this check, which is the cost of
// adding one.
func CrossFootInventory(owner address) (sumOnHand, balance int64, agrees bool) {
	r := mustReg(owner)
	var sum int64
	var failed bool
	r.items.Iterate("", "", func(_ string, v any) bool {
		c, err := v.(*item).pool.CostOnHand()
		if err != nil {
			failed = true
			return true
		}
		sum += c
		return false
	})
	b := InventoryDebit(owner)
	if failed {
		// A pool that cannot value itself makes the sum meaningless, so the
		// check REPORTS disagreement rather than panicking or quietly
		// returning a short sum. A partial total compared against a full
		// balance is the shape of a false pass.
		return 0, b, false
	}
	return sum, b, sum == b
}

// CrossFootCOGS is the register-wide check on 5000: the sum of every item's
// charged cost against the ledger balance.
func CrossFootCOGS(owner address) (sumCharged, balance int64, agrees bool) {
	r := mustReg(owner)
	var sum int64
	r.items.Iterate("", "", func(_ string, v any) bool {
		sum += v.(*item).pool.ChargedCost()
		return false
	})
	b := COGSDebit(owner)
	return sum, b, sum == b
}

// CrossFootContributed is the register-wide check on 3900: the sum of every
// item's received cost against the ledger balance.
func CrossFootContributed(owner address) (sumReceived, balance int64, agrees bool) {
	r := mustReg(owner)
	var sum int64
	r.items.Iterate("", "", func(_ string, v any) bool {
		sum += v.(*item).pool.ReceivedCost()
		return false
	})
	b := ContributedCredit(owner)
	return sum, b, sum == b
}

// CrossFoot reports all four register-wide agreements as separate bools.
//
// They are returned SEPARATELY and there is deliberately no single aggregate
// bool: a one-word verdict over four checks is the shape that gets quoted
// without its coverage, and a reader who wants the figures behind any one of
// these has [CrossFootInventory], [CrossFootCOGS], [CrossFootContributed] and
// [Equation].
func CrossFoot(owner address) (inventoryAgrees, cogsAgrees, contributedAgrees, equationOffsets bool) {
	_, _, inv := CrossFootInventory(owner)
	_, _, cogs := CrossFootCOGS(owner)
	_, _, contrib := CrossFootContributed(owner)
	_, _, offsets := Equation(owner)
	return inv, cogs, contrib, offsets
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// Render shows the realm index at "/", one owner's register at "/<address>",
// and one item at "/<address>/<sku>".
func Render(path string) string {
	p := strings.TrimSpace(strings.Trim(path, "/"))
	if p == "" {
		return renderIndex()
	}
	if i := strings.Index(p, "/"); i >= 0 {
		return renderItem(address(p[:i]), p[i+1:])
	}
	return renderRegister(address(p))
}

func renderIndex() string {
	var sb strings.Builder
	sb.WriteString("# inventory — a sub-ledger whose COGS is derived\n\n")
	sb.WriteString("Cost lots held as state, the cost of a shipment **derived** ")
	sb.WriteString("from those lots by the item's costing method, and **no ")
	sb.WriteString("custody of anything**.\n\n")

	sb.WriteString("> A general ledger takes the amount from its caller, so it ")
	sb.WriteString("cannot tell a correctly costed shipment from a flattering ")
	sb.WriteString("one. This realm never takes an amount: `Ship` takes a ")
	sb.WriteString("quantity and returns the cost it derived. That is the whole ")
	sb.WriteString("product, and it proves arithmetic — not truth. Nothing here ")
	sb.WriteString("ties a cost figure to a real holding.\n\n")

	sb.WriteString("## State\n\n")
	sb.WriteString("- registers opened: **" + strconv.Itoa(regCount) + "**\n")
	sb.WriteString("- chain height: **" + strconv.FormatInt(runtime.ChainHeight(), 10) + "**\n\n")

	sb.WriteString("## The chart is three accounts and is fixed\n\n")
	sb.WriteString("| code | name | kind | normal |\n")
	sb.WriteString("|---|---|---|---|\n")
	sb.WriteString("| `" + InventoryCode + "` | " + InventoryName + " | asset | debit |\n")
	sb.WriteString("| `" + COGSCode + "` | " + COGSName + " | expense | debit |\n")
	sb.WriteString("| `" + ContribCode + "` | " + ContribName + " | equity | credit |\n\n")
	sb.WriteString("A receipt is debit `" + InventoryCode + "` / credit `")
	sb.WriteString(ContribCode + "`. A shipment is debit `" + COGSCode)
	sb.WriteString("` / credit `" + InventoryCode + "` for the derived cost. ")
	sb.WriteString("There is no way to open a fourth account.\n\n")
	sb.WriteString("**`" + ContribCode + "` is a plug.** A debit to inventory ")
	sb.WriteString("needs a credit leg, and every candidate asserts something ")
	sb.WriteString("this realm cannot observe — a payable it would never ")
	sb.WriteString("relieve, a cash balance it does not hold, or a ")
	sb.WriteString("contribution. The contribution was chosen because it is ")
	sb.WriteString("the only one that stays coherent with no follow-up event, ")
	sb.WriteString("**not** because it is true. A register whose goods were ")
	sb.WriteString("bought on credit understates liabilities by exactly this ")
	sb.WriteString("balance.\n\n")

	sb.WriteString("## Costing methods\n\n")
	sb.WriteString("| entrypoint | method | lots held |\n")
	sb.WriteString("|---|---|---|\n")
	sb.WriteString("| `AddFIFO` | " + lots.FIFO.String() + " | one per live receipt |\n")
	sb.WriteString("| `AddLIFO` | " + lots.LIFO.String() + " | one per live receipt |\n")
	sb.WriteString("| `AddWAVG` | " + lots.WAVG.String() + " | always exactly one |\n\n")
	sb.WriteString("Fixed at creation. Changing an item's method mid-life ")
	sb.WriteString("would recost nothing already charged but would change what ")
	sb.WriteString("the next shipment costs, which is a restatement a ")
	sb.WriteString("sub-ledger must not be able to make silently.\n\n")
	sb.WriteString("\"Always exactly one\" does not mean unconstrained. A ")
	sb.WriteString(lots.WAVG.String() + " item escapes the live-lot bound and ")
	sb.WriteString("gains a refusal the other two never evaluate: merging a ")
	sb.WriteString("receipt into the single lot can breach that lot's own ")
	sb.WriteString("overflow precondition, and whether it does depends on the ")
	sb.WriteString("item's accumulated history rather than on the receipt. So ")
	sb.WriteString("`LotCapacity` is the wrong headroom figure for a ")
	sb.WriteString(lots.WAVG.String() + " item — it reports the one limit that ")
	sb.WriteString("cannot bind there.\n\n")

	sb.WriteString("## Bounds\n\n")
	sb.WriteString("| bound | value |\n")
	sb.WriteString("|---|---|\n")
	sb.WriteString("| items per register | " + strconv.Itoa(MaxItemsPerRegister) + " |\n")
	sb.WriteString("| live lots per item | " + strconv.Itoa(MaxLotsPerItem) + " |\n")
	sb.WriteString("| entries per register | " + strconv.Itoa(MaxEntriesPerRegister) + " |\n")
	sb.WriteString("| sku length | " + strconv.Itoa(MaxSKULen) + " |\n")
	sb.WriteString("| name length | " + strconv.Itoa(MaxItemNameLen) + " |\n\n")
	sb.WriteString("The entry bound is **register-wide and shared**, not per ")
	sb.WriteString("item, and that is the one bound here with a blast radius ")
	sb.WriteString("wider than the thing it limits. Every costed receipt and ")
	sb.WriteString("every costed shipment of every SKU spends one entry out of ")
	sb.WriteString("the same " + strconv.Itoa(MaxEntriesPerRegister) + ", and ")
	sb.WriteString("entries are never freed — exhausted lots are dropped, ")
	sb.WriteString("postings are not. So a single high-turnover SKU can spend ")
	sb.WriteString("the whole budget and leave the other ")
	sb.WriteString(strconv.Itoa(MaxItemsPerRegister-1) + " items unable to ")
	sb.WriteString("receive or ship, each with capacity of its own to spare. ")
	sb.WriteString("There is deliberately no archive and no reset — either ")
	sb.WriteString("would destroy the record the cross-foots are checked ")
	sb.WriteString("against — so the remedy is a second register under a ")
	sb.WriteString("second address, and busy SKUs are worth separating before ")
	sb.WriteString("they are busy. Watch `Capacity`'s second figure, which ")
	sb.WriteString("counts down for the register and not for one item.\n\n")
	sb.WriteString("A SKU may use only letters, digits, `.`, `_` and `-`: it is ")
	sb.WriteString("an index key, a page path and a table cell at once, and a ")
	sb.WriteString("charset checked on the way in beats escaping at three use ")
	sb.WriteString("sites. Case is significant.\n\n")
	sb.WriteString("There is **no write-off**: goods cannot leave without ")
	sb.WriteString("being charged to `" + COGSCode + "`, so shrinkage is ")
	sb.WriteString("indistinguishable from a sale. A real limitation, named ")
	sb.WriteString("rather than hidden.\n\n")

	sb.WriteString("## Reading a register\n\n")
	sb.WriteString("`" + RealmPath + ":<address>`\n\n")
	sb.WriteString("`" + RealmPath + ":<address>/<sku>`\n")
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
	sb.WriteString("- items: **" + strconv.Itoa(r.items.Size()) + "** / " +
		strconv.Itoa(MaxItemsPerRegister) + "\n")
	sb.WriteString("- entries: **" + strconv.Itoa(r.book.EntryCount()) + "** / " +
		strconv.Itoa(MaxEntriesPerRegister) + "\n\n")

	sumOnHand, invBal, invOK := CrossFootInventory(owner)
	sumCharged, cogsBal, cogsOK := CrossFootCOGS(owner)
	sumRecv, contribBal, contribOK := CrossFootContributed(owner)
	dn, cn, offsets := Equation(owner)

	sb.WriteString("## Cross-foot\n\n")
	sb.WriteString("| account | sum over items | ledger balance | agrees |\n")
	sb.WriteString("|---|---|---|---|\n")
	sb.WriteString("| `" + InventoryCode + "` on hand | " +
		strconv.FormatInt(sumOnHand, 10) + " | " +
		strconv.FormatInt(invBal, 10) + " | **" + yesno(invOK) + "** |\n")
	sb.WriteString("| `" + COGSCode + "` charged | " +
		strconv.FormatInt(sumCharged, 10) + " | " +
		strconv.FormatInt(cogsBal, 10) + " | **" + yesno(cogsOK) + "** |\n")
	sb.WriteString("| `" + ContribCode + "` received | " +
		strconv.FormatInt(sumRecv, 10) + " | " +
		strconv.FormatInt(contribBal, 10) + " | **" + yesno(contribOK) + "** |\n\n")
	sb.WriteString("| figure | value |\n|---|---|\n")
	sb.WriteString("| debit-normal total | " + strconv.FormatInt(dn, 10) + " |\n")
	sb.WriteString("| credit-normal total | " + strconv.FormatInt(cn, 10) + " |\n")
	sb.WriteString("| equation offsets | **" + yesno(offsets) + "** |\n")
	sb.WriteString("| book balanced | **" + yesno(r.book.IsBalanced()) + "** |\n\n")
	sb.WriteString("Those last two rows are **not two independent checks**, ")
	sb.WriteString("and a reader counting agreements would over-count here. ")
	sb.WriteString("The equation partitions accounts into debit-normal and ")
	sb.WriteString("credit-normal and then adds the two subtotals back ")
	sb.WriteString("together, so \"offsets\" reduces to total debits equal ")
	sb.WriteString("total credits — which is the first of the three things ")
	sb.WriteString("\"balanced\" checks. A balanced book always offsets. ")
	sb.WriteString("Neither row can see an account **classified** wrongly: ")
	sb.WriteString("reclassifying the whole chart moves the two totals above ")
	sb.WriteString("and leaves both booleans true. What pins the ")
	sb.WriteString("classification is the cross-foot table, where each ")
	sb.WriteString("account's ledger balance is compared against a figure ")
	sb.WriteString("derived from the items independently of the chart.\n\n")

	sb.WriteString("## Items\n\n")
	if r.items.Size() == 0 {
		sb.WriteString("_None added yet._\n")
		return sb.String()
	}
	sb.WriteString("| sku | name | method | lots | on hand | cost on hand | received | charged | ok |\n")
	sb.WriteString("|---|---|---|---|---|---|---|---|---|\n")

	shown := 0
	total := r.items.Size()
	r.items.Iterate("", "", func(_ string, v any) bool {
		if shown >= RenderItemLimit {
			return true
		}
		it := v.(*item)
		coh, err := it.pool.CostOnHand()
		ok := err == nil && it.postedCOGS == it.pool.ChargedCost()
		_, _, _, foots := it.pool.CrossFootCost()
		sb.WriteString("| [" + cell(it.sku) + "](" + RealmPath + ":" +
			owner.String() + "/" + it.sku + ") | " + cell(it.name) + " | " +
			cell(it.pool.Method().String()) + " | " +
			strconv.Itoa(it.pool.LotCount()) + " | " +
			strconv.FormatInt(it.pool.QtyOnHand(), 10) + " | " +
			strconv.FormatInt(coh, 10) + " | " +
			strconv.FormatInt(it.pool.ReceivedCost(), 10) + " | " +
			strconv.FormatInt(it.pool.ChargedCost(), 10) + " | " +
			yesno(ok && foots) + " |\n")
		shown++
		return false
	})
	if shown < total {
		sb.WriteString("\n_Showing " + strconv.Itoa(shown) + " of " +
			strconv.Itoa(total) + " items._\n")
	}
	return sb.String()
}

func renderItem(owner address, sku string) string {
	r, ok := reg(owner)
	if !ok {
		return "# No register\n\nNo register exists for `" +
			sanitize.InlineText(owner.String()) + "`.\n"
	}
	v := r.items.Get(sku)
	if v == nil {
		return "# No item\n\nNo item `" + sanitize.InlineText(sku) +
			"` in the register of `" + sanitize.InlineText(owner.String()) + "`.\n"
	}
	it := v.(*item)

	var sb strings.Builder
	sb.WriteString("# " + cell(it.sku) + " — " + cell(it.name) + "\n\n")
	sb.WriteString("- owner: `" + sanitize.InlineText(owner.String()) + "`\n")
	sb.WriteString("- costing method: **" + cell(it.pool.Method().String()) + "**\n")
	sb.WriteString("- added at height: **" + strconv.FormatInt(it.addedAt, 10) + "**\n")
	sb.WriteString("- receipts taken: **" + strconv.FormatInt(it.pool.ReceiptCount(), 10) + "**\n")
	sb.WriteString("- live lots: **" + strconv.Itoa(it.pool.LotCount()) + "** / " +
		strconv.Itoa(MaxLotsPerItem) + "\n\n")

	recv, charged, onHand, foots := it.pool.CrossFootCost()
	rq, cq, qOnHand, qFoots := it.pool.CrossFootQty()
	sb.WriteString("## Cross-foot\n\n")
	sb.WriteString("| identity | received | out | on hand | foots |\n")
	sb.WriteString("|---|---|---|---|---|\n")
	sb.WriteString("| cost | " + strconv.FormatInt(recv, 10) + " | " +
		strconv.FormatInt(charged, 10) + " | " +
		strconv.FormatInt(onHand, 10) + " | **" + yesno(foots) + "** |\n")
	sb.WriteString("| quantity | " + strconv.FormatInt(rq, 10) + " | " +
		strconv.FormatInt(cq, 10) + " | " +
		strconv.FormatInt(qOnHand, 10) + " | **" + yesno(qFoots) + "** |\n\n")
	sb.WriteString("| posted vs derived | posted | derived | agrees |\n")
	sb.WriteString("|---|---|---|---|\n")
	sb.WriteString("| cost of goods sold | " + strconv.FormatInt(it.postedCOGS, 10) +
		" | " + strconv.FormatInt(it.pool.ChargedCost(), 10) + " | **" +
		yesno(it.postedCOGS == it.pool.ChargedCost()) + "** |\n")
	sb.WriteString("| receipts | " + strconv.FormatInt(it.postedRecv, 10) +
		" | " + strconv.FormatInt(it.pool.ReceivedCost(), 10) + " | **" +
		yesno(it.postedRecv == it.pool.ReceivedCost()) + "** |\n\n")

	sb.WriteString("## Live lots\n\n")
	all := it.pool.Lots()
	if len(all) == 0 {
		sb.WriteString("_No lots on hand._\n")
		return sb.String()
	}
	sb.WriteString("| # | qty | cost | consumed | remaining | remaining cost |\n")
	sb.WriteString("|---|---|---|---|---|---|\n")
	shown := 0
	for i, l := range all {
		if shown >= RenderLotLimit {
			break
		}
		rc, err := l.RemainingCost()
		rcs := strconv.FormatInt(rc, 10)
		if err != nil {
			// A lot that cannot value itself is shown as such rather than as
			// a zero: a zero in a cost column reads as a fact.
			rcs = "**invalid**"
		}
		sb.WriteString("| " + strconv.Itoa(i) + " | " +
			strconv.FormatInt(l.Qty, 10) + " | " +
			strconv.FormatInt(l.Cost, 10) + " | " +
			strconv.FormatInt(l.Consumed, 10) + " | " +
			strconv.FormatInt(l.Remaining(), 10) + " | " + rcs + " |\n")
		shown++
	}
	if shown < len(all) {
		sb.WriteString("\n_Showing " + strconv.Itoa(shown) + " of " +
			strconv.Itoa(len(all)) + " lots._\n")
	}
	return sb.String()
}

// cell renders a caller-supplied string into a table cell. A blank value would
// collapse the column, so it is shown as a dash.
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
