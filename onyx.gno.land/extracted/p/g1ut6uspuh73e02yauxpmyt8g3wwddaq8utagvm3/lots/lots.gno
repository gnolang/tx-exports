// Package lots is the cost of goods consumed as a pure function of how much
// of a lot has been consumed.
//
// A realm stores receipts of a stock-keeping unit — each a quantity and what
// was paid for it — and asks this package what the goods it just shipped cost.
// Nothing here reads the chain, holds coins, or knows what a ledger is, so a
// realm can test a year of its own inventory costing without a node.
//
//	p, _ := NewPool(FIFO, 64)
//	p.Receive(100, 2500)             // 100 units for 2500 in total
//	p.Receive(50, 1400)              // a second, dearer receipt
//	cogs, _ := p.Consume(120)        // what the shipment cost: DERIVED
//	onHand, _ := p.CostOnHand()      // what is left is worth
//
// # The amount is never a parameter
//
// This is the thesis the rest of the package serves. A caller says how *many*
// units left the shelf; it never says what they cost. The cost is computed from
// the lots the units came out of, so a realm cannot post a cost of goods sold
// that disagrees with the inventory it holds — not because it is careful, but
// because there is no argument through which the two could be made to disagree.
//
// [p/.../depreciation] makes the same move for a capital asset, where the
// charge is a function of periods elapsed. Here it is sharpened: a depreciation
// schedule is fixed at acquisition and a caller supplies only time, while an
// inventory pool is mutated by every receipt, and the function still holds.
//
// # Why the cost is a difference of a pure function, and not a running average
//
// The obvious implementation keeps a remaining quantity and a remaining cost
// and, for a shipment of n units, charges
//
//	remainingCost * n / remainingQuantity
//
// It is wrong in a way that is specific and quiet. The division truncates, and
// what it truncates is retained in the lot rather than charged, so the cost
// charged for the first k units out of a lot **depends on how those k units
// were sliced into shipments**. Measured, with the whole lot's life evaluated:
//
//	lot(Qty=7, Cost=10) consumed as [1,1,1]
//	    naive       -> [1, 1, 1]   total 3
//	    telescoping -> [1, 1, 2]   total 4
//
// Nothing here is an accumulator. [Lot.CostAt] is a pure function of the
// cumulative units consumed,
//
//	CostAt(k) == Cost*k / Qty
//
// and [Lot.Take] is its difference at two points. So charges **telescope** —
//
//	Take(a→b) + Take(b→c) == Take(a→c)
//
// — by construction rather than by careful remainder arithmetic, and there is no
// stored remaining cost that could drift from the lot at all. A realm that
// loses track of what it has charged can recompute it from the quantities.
//
// # What the naive form actually gets wrong, stated precisely
//
// It **mis-times** cost; it does not lose it. Over a lot's whole life the naive
// form charges exactly Cost, because the shipment that exhausts the lot has
// `n == remainingQuantity` and so charges the whole remainder. Saying "it loses
// money" would be a stronger and false claim, and a reader who checks the
// totals would correctly conclude the warning was overstated and ignore the
// real defect. The real defect is that a *period's* cost of goods sold, and the
// inventory value carried at any moment before exhaustion, both depend on
// shipment slicing — which is a misstatement of both the income statement and
// the balance sheet, for a quantity nobody chose.
//
// Measured by differential sweep against exact arithmetic, over quantities 1
// to 12 and costs 1 to 50, evaluating **every ordered composition** of the
// quantity (so every way of slicing a lot's whole life into shipments):
//
//	compositions evaluated           204750
//	naive path-dependent             108320   over 260 of 600 (Qty,Cost) pairs
//	telescoping path-dependent            0
//	naive conservation failures           0
//	telescoping conservation failures     0
//	worst naive mis-timing            3 units of cost, at Qty=12 Cost=6
//
// "Path-dependent" has a definition, because the count is worthless without
// one: a composition is path-dependent if the cumulative cost charged after
// some prefix of it differs from the cumulative cost the same number of units
// would have carried had they shipped one at a time. The two zeroes on the
// conservation lines are the evidence for the paragraph above — the naive form
// reaches the right total every time and gets there wrongly — and the worst
// case is half of a small lot's cost, not a rounding crumb.
//
// # The weighted-average method re-anchors at every receipt, and must
//
// Under [WAVG] a receipt merges into the single live lot: the merged lot's
// quantity is what remained plus what arrived, its cost is what remained *was
// worth* plus what arrived cost, and its consumed count resets to zero. The
// reset is not bookkeeping convenience and is not a defect — it is forced.
// CostAt is a function of the lot's own Qty and Cost, and a receipt changes
// both, so a consumed count measured against the old pair means nothing
// against the new one. Telescoping therefore holds **within an anchor epoch**,
// and across the re-anchor what holds instead is exact cost neutrality: the
// merged lot's cost is the outgoing lot's remaining cost plus the receipt's,
// with nothing dropped and nothing invented. [Pool.CrossFootCost] is what
// proves it, and it is asserted over receipt/consume interleavings in the
// suite.
//
// The asymmetry this creates is worth knowing before choosing a method: WAVG
// can **refuse** a receipt that FIFO and LIFO accept, because the merged lot
// must satisfy the overflow precondition `Cost <= maxInt64/Qty` that two
// separate lots would each satisfy on their own. See [Pool.Receive].
//
// # An error return does not revert a Gno transaction
//
// Only a panic reverts. So every mutating method here stages its whole effect
// — a copy of the lots it will touch, and the total it will charge — and
// commits only once the last step has succeeded. A method that returned an
// error after mutating half the pool would leave a realm holding inventory
// whose cost had been partly charged, with the realm's own error handling
// unable to undo it, and the realm would have no way to detect it short of a
// cross-foot. This package does not panic on caller error; it returns errors
// and keeps the pool untouched when it does.
//
// # What this package does not claim
//
//   - **No novelty for FIFO, LIFO or weighted average.** They are textbook and
//     older than software. What was not found in the searched sources is an
//     on-chain integer implementation with a path-independent cost function;
//     see DISCOVERY.md.
//   - **Nothing about money.** A lot cost is a number in a record. This package
//     never sees a coin, never holds value, and a realm using it must not infer
//     custody from it.
//   - **No specific identification.** The four methods a textbook lists are
//     three here. Specific identification — the shipper naming which lot a unit
//     came from — would make the consumed amount depend on a caller-supplied
//     choice, which is the one thing the thesis above rules out. A realm that
//     needs it should hold one pool per identified lot.
//   - **No units of measure, no currency, no SKU identity.** A quantity is an
//     integer and a cost is an integer. Deciding that they are kilograms and
//     thousandths of a ugnot, and that this pool is the one for SKU "A-1", is
//     the realm's job.
//   - **No negative inventory, no write-offs, no revaluation.** Consuming more
//     than is on hand is [ErrInsufficient], never a negative lot. Shrinkage and
//     lower-of-cost-or-market are not here; a realm that needs them needs a
//     fourth and fifth account and should say so in its own chart.
//
// [p/.../depreciation]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/depreciation
package lots

import "errors"

// MaxLotsLimit bounds the live lots a single pool may hold, and so bounds
// every walk in this package: [Pool.CostOnHand], [Pool.QtyOnHand],
// [Pool.Consume] and both cross-foots are O(live lots).
//
// What the bound costs is stated rather than waved at. A pool at the limit
// makes Consume scan up to 1024 lots and the cross-foots walk them all, and a
// realm that renders many pools in one query multiplies that. The limit is the
// ceiling a caller may ask for, not a recommendation: a caller passes its own
// smaller cap to [NewPool] and should, because exhausted lots are dropped but
// live ones are not, and a pool fed many small receipts and consumed in large
// shipments is the shape that fills up.
const MaxLotsLimit = 1024

var (
	// ErrBadQty is returned when a quantity is not positive. A zero-quantity
	// receipt is not a lot and a zero-quantity shipment is not an event;
	// accepting either would have a realm post an entry for nothing.
	ErrBadQty = errors.New("lots: quantity must be positive")

	// ErrBadCost is returned when a cost is negative. Zero is allowed: goods
	// received at no cost are ordinary — donated stock, samples, a
	// promotional allowance that zeroed the invoice — and they consume
	// exactly zero cost for their whole life, which is the right answer and
	// not a degenerate one.
	ErrBadCost = errors.New("lots: cost must not be negative")

	// ErrBadConsumed is returned when a lot's consumed count is negative or
	// exceeds its quantity. It is reachable only on a lot a caller built by
	// hand; lots this package produces always satisfy it.
	ErrBadConsumed = errors.New("lots: consumed must be in [0, qty]")

	// ErrBadSeq is returned when a lot's receipt sequence is negative.
	ErrBadSeq = errors.New("lots: seq must not be negative")

	// ErrBadMethod is returned for a method outside the declared set.
	ErrBadMethod = errors.New("lots: unknown method")

	// ErrBadMaxLots is returned when a pool's lot cap is not positive or
	// exceeds MaxLotsLimit.
	ErrBadMaxLots = errors.New("lots: maxLots must be in [1, MaxLotsLimit]")

	// ErrPoolFull is returned when a receipt would exceed the pool's own lot
	// cap. It is fail-closed: the receipt is refused and the pool is
	// untouched, so a realm sees a refused receipt rather than silently
	// merged or dropped stock.
	ErrPoolFull = errors.New("lots: lot cap reached")

	// ErrInsufficient is returned when a shipment exceeds the quantity on
	// hand. There is no partial fill and no negative inventory: a realm that
	// wants to ship what it can must ask QtyOnHand first and decide.
	ErrInsufficient = errors.New("lots: quantity exceeds quantity on hand")

	// ErrSeqExhausted is returned when the receipt sequence space is spent.
	// Unreachable in practice and checked anyway, because the alternative is
	// two lots sharing a sequence and a silently non-deterministic order.
	ErrSeqExhausted = errors.New("lots: receipt sequence space exhausted")

	// ErrOverflow is returned when the arithmetic would wrap. Most overflow
	// is excluded by a precondition established when a lot is constructed;
	// see Lot.check and Pool.Receive.
	ErrOverflow = errors.New("lots: int64 overflow")
)

// The bound is written as a literal rather than as the usual
// `int64(1)<<63 - 1` idiom, which does not compile: the shift is evaluated in
// the already-typed int64 and overflows before the subtraction can bring it
// back in range. It is a compile error here rather than a wrong number, but it
// is the same shape as the arithmetic this package exists to get right, so it
// is worth naming.
const maxInt64 int64 = 9223372036854775807

// Method is the order in which lots are consumed.
type Method uint8

const (
	// FIFO consumes the earliest-received live lot first.
	FIFO Method = 1

	// LIFO consumes the latest-received live lot first.
	LIFO Method = 2

	// WAVG keeps one lot, merging every receipt into it at a weighted
	// average. See the package doc on why the merge re-anchors.
	WAVG Method = 3
)

// Valid reports whether m is a method this package implements.
func (m Method) Valid() bool { return m == FIFO || m == LIFO || m == WAVG }

// String names the method. The zero Method is "invalid" rather than empty, so
// a caller that renders it without checking Valid prints something that reads
// as wrong instead of something that reads as missing.
func (m Method) String() string {
	switch m {
	case FIFO:
		return "fifo"
	case LIFO:
		return "lifo"
	case WAVG:
		return "weighted-average"
	}
	return "invalid"
}

// Lot is one receipt of stock: a quantity, what was paid for all of it, and how
// much of it has since been consumed. It is a value, is safe to copy, and every
// method validates its receiver, so a hand-built or zero Lot fails rather than
// returning a plausible number.
//
// Construct with [NewLot] so the overflow precondition is checked once rather
// than on every call. The fields are exported because a realm must be able to
// render a lot and persist it, and because [Pool.Lots] hands out copies.
type Lot struct {
	// Qty is the quantity received. It never changes: consumption moves
	// Consumed, not Qty, because CostAt is a function of the original pair
	// and reducing Qty would redefine the function under its own callers.
	Qty int64

	// Cost is what the whole of Qty cost. It never changes either, for the
	// same reason — except under [WAVG], where a receipt replaces the lot
	// with a freshly anchored one rather than editing this field.
	Cost int64

	// Consumed is the cumulative quantity consumed from this lot, in
	// [0, Qty]. It is the sole argument of the cost function.
	Consumed int64

	// Seq is the receipt order within a pool, assigned by [Pool.Receive].
	// It orders lots for FIFO and LIFO and **never enters a cost
	// computation**: two lots with the same Qty and Cost cost the same to
	// consume whatever their sequence, which is why the ordering decision
	// and the costing arithmetic can be reviewed separately.
	Seq int64
}

// NewLot validates and returns a lot of qty units costing cost in total. Seq
// is zero; [Pool.Receive] assigns it.
func NewLot(qty, cost int64) (Lot, error) {
	l := Lot{Qty: qty, Cost: cost}
	if err := l.check(); err != nil {
		return Lot{}, err
	}
	return l, nil
}

// check validates every field and, critically, the overflow precondition that
// lets [Lot.CostAt] be a total function on a constructed lot. A zero Lot
// fails, which is why every method calls check rather than trusting its
// receiver.
func (l Lot) check() error {
	if l.Qty <= 0 {
		return ErrBadQty
	}
	if l.Cost < 0 {
		return ErrBadCost
	}
	if l.Consumed < 0 || l.Consumed > l.Qty {
		return ErrBadConsumed
	}
	if l.Seq < 0 {
		return ErrBadSeq
	}
	// Cost*k is the only product in this package's cost function and
	// k <= Qty, so Cost*Qty bounds it. Qty >= 1 is already established, so
	// the division is safe.
	if l.Cost > maxInt64/l.Qty {
		return ErrOverflow
	}
	return nil
}

// Valid reports whether the lot is well-formed. A zero Lot is not.
func (l Lot) Valid() bool { return l.check() == nil }

// Remaining is Qty - Consumed: the quantity still on the shelf from this lot.
//
// It does not validate, and it is the only method here that does not. On an
// ill-formed lot it returns an arbitrary number — Lot{Qty: 1, Consumed:
// minInt64} wraps. A zero result means "exhausted, or invalid", never
// "exhausted" alone; use [Lot.Exhausted], which does validate. Guard a
// caller-supplied lot with [Lot.Valid] before quoting Remaining from it.
func (l Lot) Remaining() int64 { return l.Qty - l.Consumed }

// Exhausted reports whether a well-formed lot has nothing left. An invalid lot
// is not exhausted — it is invalid, and conflating the two is how a bad lot
// gets silently dropped by [Pool.Consume]'s housekeeping.
func (l Lot) Exhausted() bool { return l.Valid() && l.Remaining() == 0 }

// CostAt returns the cumulative cost consumed from this lot once k units in
// total have been consumed from it:
//
//	CostAt(k) == Cost*k / Qty
//
// It is the one function in this package, and everything else is defined from
// it. It is monotone non-decreasing in k, zero at k == 0, and **exactly Cost at
// k == Qty** — that endpoint is not an approximation, because Cost*Qty/Qty is
// exact in integers, and it is what makes a lot's whole life charge exactly
// what the lot cost and makes dropping an exhausted lot cost-neutral.
//
// k outside [0, Qty] is [ErrBadConsumed] rather than a clamp: a clamp would let
// a caller's off-by-one read as a valid cost at the boundary.
func (l Lot) CostAt(k int64) (int64, error) {
	if err := l.check(); err != nil {
		return 0, err
	}
	if k < 0 || k > l.Qty {
		return 0, ErrBadConsumed
	}
	// Cannot overflow: check established Cost <= maxInt64/Qty and k <= Qty.
	return (l.Cost * k) / l.Qty, nil
}

// ConsumedCost returns the cost consumed from this lot so far: CostAt(Consumed).
func (l Lot) ConsumedCost() (int64, error) { return l.CostAt(l.Consumed) }

// RemainingCost returns what the units still on the shelf are carried at:
// Cost - ConsumedCost. It is defined in terms of CostAt so the two can never
// disagree, which is the same reason [Lot.Take] is. It is zero exactly when the
// lot is exhausted.
func (l Lot) RemainingCost() (int64, error) {
	c, err := l.ConsumedCost()
	if err != nil {
		return 0, err
	}
	// Non-negative and cannot overflow: CostAt is in [0, Cost].
	return l.Cost - c, nil
}

// Take consumes n units from the lot, returning the advanced lot and the cost
// of those units. The receiver is a value, so a failed Take cannot have
// mutated anything the caller holds — the atomicity the package doc describes
// is structural at this level and has to be built by hand one level up, in
// [Pool.Consume].
//
// The charge is the difference of [Lot.CostAt] at the two consumed counts,
// which makes charges telescope exactly:
//
//	Take(a→b) + Take(b→c) == Take(a→c)   for a <= b <= c
//
// So how a realm slices its shipments cannot change what a lot charges in
// total, nor what it has charged by any point in its life. The charge is never
// negative; n must be positive and within [Lot.Remaining].
func (l Lot) Take(n int64) (Lot, int64, error) {
	if err := l.check(); err != nil {
		return Lot{}, 0, err
	}
	if n <= 0 {
		return Lot{}, 0, ErrBadQty
	}
	if n > l.Remaining() {
		return Lot{}, 0, ErrInsufficient
	}
	before, err := l.CostAt(l.Consumed)
	if err != nil {
		return Lot{}, 0, err
	}
	after, err := l.CostAt(l.Consumed + n)
	if err != nil {
		return Lot{}, 0, err
	}
	l.Consumed += n
	// after >= before because CostAt is monotone non-decreasing, so the
	// difference is non-negative and cannot overflow: both lie in [0, Cost].
	return l, after - before, nil
}

// Pool is the live lots of one stock-keeping unit under one consumption
// method, plus the four cumulative counters the cross-foots compare against.
//
// It is a pointer type with unexported state because the counters and the lots
// must move together — a realm holding a mutable view of one without the other
// could leave the pool stating a cost on hand its own receipts contradict.
// [Pool.Lots] therefore returns copies.
type Pool struct {
	method  Method
	maxLots int
	lots    []Lot
	nextSeq int64

	// The counters. Each is monotone non-decreasing and each is maintained
	// independently of the lots, which is the whole point: a cross-foot
	// compares a counter against a walk of the lots, so a bug in either one
	// is visible rather than cancelling.
	recvQty  int64
	recvCost int64
	consQty  int64
	chgCost  int64
}

// NewPool validates and returns an empty pool consuming lots in the given
// order and holding at most maxLots live lots.
func NewPool(method Method, maxLots int) (*Pool, error) {
	if !method.Valid() {
		return nil, ErrBadMethod
	}
	if maxLots <= 0 || maxLots > MaxLotsLimit {
		return nil, ErrBadMaxLots
	}
	return &Pool{method: method, maxLots: maxLots, nextSeq: 1}, nil
}

// MustNewPool is NewPool, panicking on an invalid configuration. It is for a
// realm's init, where a configuration error is a deployment bug and should
// abort the transaction rather than be handled.
func MustNewPool(method Method, maxLots int) *Pool {
	p, err := NewPool(method, maxLots)
	if err != nil {
		panic(err)
	}
	return p
}

// Method is the consumption order, fixed at construction. It is deliberately
// immutable: changing it mid-life would recost nothing already charged but
// would change what the next shipment costs, which is a restatement a
// sub-ledger must not be able to make silently. A realm that must switch
// methods opens a new pool and discloses it.
func (p *Pool) Method() Method { return p.method }

// MaxLots is the pool's own live-lot cap.
func (p *Pool) MaxLots() int { return p.maxLots }

// LotCount is the number of live lots. Exhausted lots are dropped by
// [Pool.Consume], so this is not the number of receipts; that is
// [Pool.ReceiptCount].
func (p *Pool) LotCount() int { return len(p.lots) }

// ReceiptCount is how many receipts the pool has taken, including those whose
// lots are exhausted and dropped, and including WAVG merges.
//
// The clamp is not defensive noise. nextSeq is 1 on a constructed pool, so a
// zero-value Pool — one a realm declared rather than built with [NewPool] —
// would otherwise report **minus one receipt**, an affirmatively wrong number
// rendered as fact. That is the opposite of the choice [Method.String] makes
// twenty lines up, where the zero value deliberately reads "invalid" so a
// caller who skipped the check prints something that reads as wrong rather than
// as missing. A count has no such word, so the honest answer for a pool that
// has taken no receipts is zero. Transacting on that pool is still refused:
// [Pool.Receive] and [Pool.Consume] both return [ErrBadMethod].
func (p *Pool) ReceiptCount() int64 {
	if p.nextSeq <= 0 {
		return 0
	}
	return p.nextSeq - 1
}

// Lots returns the live lots in receipt order, as copies. Mutating the result
// does not affect the pool.
func (p *Pool) Lots() []Lot {
	out := make([]Lot, len(p.lots))
	copy(out, p.lots)
	return out
}

// Lot returns the i'th live lot in receipt order, and whether i was in range.
func (p *Pool) Lot(i int) (Lot, bool) {
	if i < 0 || i >= len(p.lots) {
		return Lot{}, false
	}
	return p.lots[i], true
}

// ReceivedQty is the cumulative quantity received.
func (p *Pool) ReceivedQty() int64 { return p.recvQty }

// ReceivedCost is the cumulative cost received.
func (p *Pool) ReceivedCost() int64 { return p.recvCost }

// ConsumedQty is the cumulative quantity consumed.
func (p *Pool) ConsumedQty() int64 { return p.consQty }

// ChargedCost is the cumulative cost charged out by [Pool.Consume]. This is
// the figure a realm posts as cost of goods sold, and it is derived: no caller
// has ever supplied it.
func (p *Pool) ChargedCost() int64 { return p.chgCost }

// QtyOnHand walks the live lots and sums what remains. It is derived from the
// lots rather than read from a counter, which is what makes
// [Pool.CrossFootQty] a comparison of two things rather than a tautology.
//
// It cannot overflow: every lot's remaining quantity is non-negative and their
// sum is bounded by recvQty, which [Pool.Receive] refused to let overflow.
func (p *Pool) QtyOnHand() int64 {
	total := int64(0)
	for _, l := range p.lots {
		total += l.Remaining()
	}
	return total
}

// CostOnHand walks the live lots and sums what they are carried at: the
// inventory value a realm reports on its balance sheet. Derived, for the same
// reason as [Pool.QtyOnHand].
//
// It returns an error because a lot that failed validation makes the sum
// meaningless, and because the running total is overflow-checked. That check
// is believed unreachable — the sum is bounded by recvCost, whose own
// accumulation Receive guards — and it is written anyway, because "unreachable"
// is an argument about code that may be edited and the cost of being wrong
// here is a negative inventory value.
func (p *Pool) CostOnHand() (int64, error) {
	total := int64(0)
	for _, l := range p.lots {
		c, err := l.RemainingCost()
		if err != nil {
			return 0, err
		}
		if total > maxInt64-c {
			return 0, ErrOverflow
		}
		total += c
	}
	return total, nil
}

// Receive records a receipt of qty units costing cost in total.
//
// Under FIFO and LIFO it appends a lot, refusing with [ErrPoolFull] at the
// pool's cap. Under WAVG it merges into the single live lot, re-anchoring it:
// the merged lot carries the remaining quantity plus qty, the remaining cost
// plus cost, and a consumed count of zero. See the package doc on why the
// re-anchor is forced rather than chosen.
//
// The merge is where WAVG can refuse what the other two methods accept. A
// merged lot must satisfy the same precondition every lot does,
// `Cost <= maxInt64/Qty`, and two separately-held lots each satisfying it do
// not imply their merge does. That returns [ErrOverflow] and leaves the pool
// exactly as it was, so the receipt is refused rather than partly applied —
// but a realm must handle it, because under WAVG it is a property of the
// *history* and not only of the arguments.
//
// Nothing is committed until every check has passed: on any error the pool is
// untouched, including its counters.
func (p *Pool) Receive(qty, cost int64) error {
	if !p.method.Valid() {
		return ErrBadMethod
	}
	if qty <= 0 {
		return ErrBadQty
	}
	if cost < 0 {
		return ErrBadCost
	}
	if p.nextSeq == maxInt64 {
		return ErrSeqExhausted
	}
	if p.recvQty > maxInt64-qty {
		return ErrOverflow
	}
	if p.recvCost > maxInt64-cost {
		return ErrOverflow
	}

	// Stage the lot the receipt produces, without touching the pool.
	var staged []Lot
	if p.method == WAVG && len(p.lots) > 0 {
		// WAVG holds at most one lot by construction — the method is
		// immutable and this branch is the only way a second one could
		// arrive — so merging into index 0 is merging into the only lot.
		// The guard is kept because that argument is about the whole
		// package rather than about this function.
		if len(p.lots) != 1 {
			return ErrBadMethod
		}
		cur := p.lots[0]
		rem := cur.Remaining()
		remCost, err := cur.RemainingCost()
		if err != nil {
			return err
		}
		if rem > maxInt64-qty {
			return ErrOverflow
		}
		if remCost > maxInt64-cost {
			return ErrOverflow
		}
		merged := Lot{Qty: rem + qty, Cost: remCost + cost, Seq: cur.Seq}
		if err := merged.check(); err != nil {
			return err
		}
		staged = []Lot{merged}
	} else {
		if len(p.lots) >= p.maxLots {
			return ErrPoolFull
		}
		fresh, err := NewLot(qty, cost)
		if err != nil {
			return err
		}
		fresh.Seq = p.nextSeq
		staged = make([]Lot, 0, len(p.lots)+1)
		staged = append(staged, p.lots...)
		staged = append(staged, fresh)
	}

	// Commit.
	p.lots = staged
	p.nextSeq++
	p.recvQty += qty
	p.recvCost += cost
	return nil
}

// Consume ships qty units and returns what they cost.
//
// The cost is derived from the lots the units came out of, in the pool's
// declared order, and is never a parameter. Lots that the shipment exhausts
// are dropped, which is cost-neutral because [Lot.CostAt] is exact at Qty.
//
// It is all-or-nothing in both senses. A shipment larger than
// [Pool.QtyOnHand] is [ErrInsufficient] with the pool untouched — there is no
// partial fill — and the whole effect is staged on a copy and committed only
// after the last lot has been taken from successfully, because an error return
// does not revert a Gno transaction. A pool left half-consumed with its
// counters unmoved would state a cost on hand its lots contradict, detectable
// only by a cross-foot.
func (p *Pool) Consume(qty int64) (int64, error) {
	if !p.method.Valid() {
		return 0, ErrBadMethod
	}
	if qty <= 0 {
		return 0, ErrBadQty
	}
	if qty > p.QtyOnHand() {
		return 0, ErrInsufficient
	}

	staged := make([]Lot, len(p.lots))
	copy(staged, p.lots)

	total := int64(0)
	left := qty
	for _, i := range p.order() {
		if left == 0 {
			break
		}
		avail := staged[i].Remaining()
		if avail <= 0 {
			continue
		}
		take := avail
		if left < take {
			take = left
		}
		advanced, charge, err := staged[i].Take(take)
		if err != nil {
			return 0, err
		}
		// Cannot overflow: the sum of charges is bounded by the pool's
		// cost on hand, itself bounded by recvCost. Checked anyway, for
		// the reason given on CostOnHand.
		if total > maxInt64-charge {
			return 0, ErrOverflow
		}
		staged[i] = advanced
		total += charge
		left -= take
	}
	if left != 0 {
		// Unreachable: the QtyOnHand check above established that the live
		// lots hold at least qty units. Reported rather than ignored,
		// because reaching it would mean QtyOnHand and the lots disagree,
		// which is exactly what a cross-foot exists to catch.
		return 0, ErrInsufficient
	}

	// Checked rather than argued, and placed before the first commit so a
	// refusal still leaves the pool exactly as it was.
	//
	// The invariants consQty <= recvQty and chgCost <= recvCost do hold over
	// this package's public API — both counters are unexported with no setter,
	// and Receive refuses a receipt at either ceiling — so neither add can
	// overflow today. That is an argument about the *current* call graph, and
	// it is the same argument CostOnHand declines to rest on twenty lines up:
	// "unreachable" is a claim about code that may be edited, and these two
	// adds were the only running sums in the package without a guard in front
	// of them. The cost of being wrong is a negative quantity consumed and a
	// negative cost of goods sold, which a cross-foot would then report as the
	// pool's own failure.
	if p.consQty > maxInt64-qty {
		return 0, ErrOverflow
	}
	if p.chgCost > maxInt64-total {
		return 0, ErrOverflow
	}

	// Commit.
	p.lots = dropExhausted(staged)
	p.consQty += qty
	p.chgCost += total
	return total, nil
}

// order returns the indices of p.lots in consumption order. FIFO and WAVG
// consume in receipt order; LIFO reverses it. WAVG holds one lot, so the two
// orders coincide for it and it is grouped with FIFO rather than given a case
// that could never be distinguished by a test.
func (p *Pool) order() []int {
	out := make([]int, len(p.lots))
	for i := range p.lots {
		if p.method == LIFO {
			out[i] = len(p.lots) - 1 - i
		} else {
			out[i] = i
		}
	}
	return out
}

// dropExhausted returns the lots with the exhausted ones removed, preserving
// receipt order.
//
// It is cost-neutral, and that is a property of [Lot.CostAt] rather than of
// this function: an exhausted lot has Consumed == Qty, so its consumed cost is
// Cost*Qty/Qty — exactly Cost, in integers, with no remainder — and its
// remaining cost is therefore exactly zero. Dropping it removes a zero from
// the sum [Pool.CostOnHand] walks. Were the cost function inexact at the
// endpoint, this housekeeping would quietly destroy value, which is why the
// endpoint is asserted in the suite rather than assumed here.
//
// An **invalid** lot is not dropped. [Lot.Exhausted] requires validity, so a
// malformed lot survives housekeeping and keeps failing [Pool.CostOnHand],
// rather than being silently swept out of a pool whose counters still count it.
func dropExhausted(in []Lot) []Lot {
	out := make([]Lot, 0, len(in))
	for _, l := range in {
		if l.Exhausted() {
			continue
		}
		out = append(out, l)
	}
	return out
}

// CrossFootCost reports the pool's cost identity:
//
//	cost received == cost charged out + cost on hand
//
// The left side and the first right-hand term are cumulative counters; the
// second is a walk of the live lots. So this compares two independent
// derivations, and it is the strong one of the pair: it is what proves the WAVG
// re-anchor loses nothing, that dropping exhausted lots is cost-neutral, and
// that no shipment charged cost that was never received.
//
// foots is false if the identity fails **or if the walk failed**, and onHand is
// zero in the second case. A caller that wants to tell those apart calls
// [Pool.CostOnHand] directly; a caller that only wants to know whether the
// sub-ledger is sound does not need to, because neither is sound.
func (p *Pool) CrossFootCost() (received, charged, onHand int64, foots bool) {
	onHand, err := p.CostOnHand()
	if err != nil {
		return p.recvCost, p.chgCost, 0, false
	}
	return p.recvCost, p.chgCost, onHand, p.recvCost == p.chgCost+onHand
}

// CrossFootQty reports the pool's quantity identity:
//
//	quantity received == quantity consumed + quantity on hand
//
// It is the weaker of the pair and is **not implied** by [Pool.CrossFootCost],
// which is why both exist. Costs are derived from quantities, so a quantity
// that went missing in a way that preserved its own lot's cost arithmetic — a
// lot dropped while still holding units it had charged nothing for, say —
// foots perfectly on cost and fails here. A realm's invariant should assert
// both.
func (p *Pool) CrossFootQty() (received, consumed, onHand int64, foots bool) {
	onHand = p.QtyOnHand()
	return p.recvQty, p.consQty, onHand, p.recvQty == p.consQty+onHand
}
