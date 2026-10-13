package game29

// ── P2P exchange: escrowed limit-order book (any coin pair) ──────────────────
//
// A maker escrows `give` and asks for `want` at their own price; takers fill
// at the maker's price (fully or partly). Cancel or expiry refunds the
// remaining escrow; the 2-grin posting fee is not refunded. No price bands.
//
// Storage (≈ 200 bytes per open order): no per-order tree node (one avl
// insert costs ~2.1 KB of storage deposit). Each maker has ONE compact string
// holding their ≤ 20 open orders, and each book side (want>give) is ONE
// fixed-width string of sorted 76-byte entries (priceKey24 + id12 + maker40),
// capped at maxSideOrders; when a side is full a new order must beat the
// worst one, which is then refunded to its maker (evicted).

import (
	"std"
	"math/bits"
	"strconv"
	"strings"
	"time"
)

type order struct {
	id               uint64
	maker            string
	give, want       string
	remGive, remWant uint64
	expiry           int64
	pk               string // price key part of the book key
}

func padU(n uint64, w int) string {
	s := strconv.FormatUint(n, 10)
	for len(s) < w {
		s = "0" + s
	}
	return s
}

const hexDigits = "0123456789abcdef"

// priceKey = want-per-give × 1e12 as a fixed-width 24-hex-digit number
// (96 bits; amounts ≤ 1e15 keep it < 2^90). Lexicographic = numeric order,
// so ascending book keys are the cheapest asks first for takers.
func priceKey(wantAmt, giveAmt uint64) string {
	hi, lo := bits.Mul64(wantAmt, 1000000000000)
	qhi := hi / giveAmt
	qlo, _ := bits.Div64(hi%giveAmt, lo, giveAmt)
	if qhi >= 1<<32 {
		panic("price out of range")
	}
	b := make([]byte, 24)
	for i := 7; i >= 0; i-- {
		b[i] = hexDigits[qhi&15]
		qhi >>= 4
	}
	for i := 23; i >= 8; i-- {
		b[i] = hexDigits[qlo&15]
		qlo >>= 4
	}
	return string(b)
}

const (
	sideEntryLen  = 76  // priceKey(24) + id(12) + maker address(40)
	sideSortLen   = 36  // entries sort by priceKey then id (FIFO within a price)
	maxSideOrders = 256 // open orders per book side; bounds every string we rewrite
)

// maker record: id12|give|want|remGive|remWant|expiry|pk
func encodeOrder(o *order) string {
	return padU(o.id, 12) + "|" + o.give + "|" + o.want + "|" + u(o.remGive) + "|" + u(o.remWant) + "|" +
		strconv.FormatInt(o.expiry, 10) + "|" + o.pk
}

func decodeOrder(maker, rec string) *order {
	f := strings.Split(rec, "|")
	if len(f) != 7 {
		panic("corrupt order")
	}
	id, _ := strconv.ParseUint(f[0], 10, 64)
	rg, _ := strconv.ParseUint(f[3], 10, 64)
	rw, _ := strconv.ParseUint(f[4], 10, 64)
	ex, _ := strconv.ParseInt(f[5], 10, 64)
	return &order{id: id, maker: maker, give: f[1], want: f[2], remGive: rg, remWant: rw, expiry: ex, pk: f[6]}
}

func makerRecs(maker string) []string {
	if !makerBooks.Has(maker) {
		return nil
	}
	v := makerBooks.Get(maker).(string)
	if v == "" {
		return nil
	}
	return strings.Split(v, ";")
}

func setMakerRecs(maker string, recs []string) {
	if len(recs) == 0 {
		makerBooks.Remove(maker)
		return
	}
	makerBooks.Set(maker, strings.Join(recs, ";"))
}

// loadOrderOf finds one of maker's open orders (≤ 20 records scanned).
func loadOrderOf(maker string, id uint64) *order {
	pre := padU(id, 12) + "|"
	for _, r := range makerRecs(maker) {
		if strings.HasPrefix(r, pre) {
			return decodeOrder(maker, r)
		}
	}
	return nil
}

func saveOrder(o *order) {
	recs := makerRecs(o.maker)
	pre := padU(o.id, 12) + "|"
	for i, r := range recs {
		if strings.HasPrefix(r, pre) {
			recs[i] = encodeOrder(o)
			setMakerRecs(o.maker, recs)
			return
		}
	}
	panic("invariant: order not found")
}

func sideKey(want, give string) string { return want + ">" + give }

func sideEntry(o *order) string { return o.pk + padU(o.id, 12) + o.maker }

func sideStr(k string) string {
	if !sides.Has(k) {
		return ""
	}
	return sides.Get(k).(string)
}

// sideSearch returns the index of the first entry whose sort key is ≥ key.
func sideSearch(s, key string) int {
	lo, hi := 0, len(s)/sideEntryLen
	for lo < hi {
		mid := (lo + hi) / 2
		if s[mid*sideEntryLen:mid*sideEntryLen+sideSortLen] < key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

func sideInsert(o *order) {
	k := sideKey(o.want, o.give)
	s := sideStr(k)
	e := sideEntry(o)
	i := sideSearch(s, e[:sideSortLen]) * sideEntryLen
	sides.Set(k, s[:i]+e+s[i:])
}

func sideRemove(o *order) {
	k := sideKey(o.want, o.give)
	s := sideStr(k)
	e := sideEntry(o)
	i := sideSearch(s, e[:sideSortLen]) * sideEntryLen
	if i+sideEntryLen > len(s) || s[i:i+sideEntryLen] != e {
		panic("invariant: book entry missing")
	}
	s = s[:i] + s[i+sideEntryLen:]
	if s == "" {
		sides.Remove(k)
	} else {
		sides.Set(k, s)
	}
}

// iterSide walks a taker's side (pays `pay`, gets `get`) best price first.
func iterSide(pay, get string, fn func(maker string, id uint64) bool) {
	s := sideStr(sideKey(pay, get))
	for i := 0; i+sideEntryLen <= len(s); i += sideEntryLen {
		e := s[i : i+sideEntryLen]
		id, _ := strconv.ParseUint(e[24:36], 10, 64)
		if fn(e[36:], id) {
			return
		}
	}
}

func sideCount(pay, get string) int { return len(sideStr(sideKey(pay, get))) / sideEntryLen }

// grinValueMilli = amt × reference value (milli-grin), saturating at 2^64-1.
func grinValueMilli(coin string, amt uint64) uint64 {
	hi, lo := bits.Mul64(amt, prefMilli[requireCoin(coin)])
	if hi != 0 {
		return ^uint64(0)
	}
	return lo
}

func openOrderCount(maker string) uint64 { return uint64(len(makerRecs(maker))) }

// PlaceOrder escrows giveAmt of `give` and lists it for wantAmt of `want`
// (any pair). Costs 2 grin (protocol fee, not refunded). Returns the id.
// expirySecs 0 = 72 h; max 7 days.
func PlaceOrder(cur realm, give string, giveAmt uint64, want string, wantAmt uint64, expirySecs int64) uint64 {
	caller := exchangeCaller(cur)
	requireMarketOpen(caller)
	requireCoin(give)
	requireCoin(want)
	if give == want {
		panic("give and want must differ")
	}
	requireAmount("giveAmt", giveAmt)
	requireAmount("wantAmt", wantAmt)
	if grinValueMilli(give, giveAmt) < minOrderGrinX1k {
		panic("order too small: minimum is 50 grin of value")
	}
	if expirySecs == 0 {
		expirySecs = defaultExpiry
	}
	if expirySecs < 60 || expirySecs > maxExpiry {
		panic("expiry must be between 60 s and 7 days")
	}
	if openOrderCount(caller) >= maxOpenOrders {
		panic("max 20 open orders")
	}
	if len(caller) != 40 {
		panic("invalid maker address")
	}
	pk := priceKey(wantAmt, giveAmt)
	nextId := addChk(nextOrderId, 1)
	// A full side only takes an order that beats its worst one (which is then
	// refunded to its maker): spam can't lock the book with absurd prices.
	var evict *order
	if sideCount(want, give) >= maxSideOrders {
		s := sideStr(sideKey(want, give))
		w := s[len(s)-sideEntryLen:]
		if pk+padU(nextId, 12) >= w[:sideSortLen] {
			panic("book side full: price must beat the worst open order")
		}
		wid, _ := strconv.ParseUint(w[24:36], 10, 64)
		evict = loadOrderOf(w[36:], wid)
		if evict == nil {
			panic("invariant: book entry without order")
		}
	}
	if give == hubCoin {
		requireBalance(caller, hubCoin, addChk(giveAmt, postFeeGrin))
	} else {
		requireBalance(caller, hubCoin, postFeeGrin)
		requireBalance(caller, give, giveAmt)
	}
	// ── all checks passed; writes start here ──
	debitBal(caller, hubCoin, postFeeGrin)
	accrueProtocolFee(hubCoin, postFeeGrin)
	debitBal(caller, give, giveAmt) // escrow

	if evict != nil {
		closeOrder(evict, "evicted")
	}
	nextOrderId = nextId
	o := &order{id: nextId, maker: caller, give: give, want: want, remGive: giveAmt, remWant: wantAmt,
		expiry: time.Now().Unix() + expirySecs, pk: pk}
	setMakerRecs(caller, append(makerRecs(caller), encodeOrder(o)))
	sideInsert(o)
	openOrderTotal = addChk(openOrderTotal, 1)
	std.Emit("OrderPlaced", "id", u(o.id), "maker", caller, "give", give, "giveAmt", u(giveAmt),
		"want", want, "wantAmt", u(wantAmt), "expiry", strconv.FormatInt(o.expiry, 10))
	return o.id
}

// closeOrder refunds the remaining escrow to the MAKER (never anyone else)
// and deletes the order. Every close path goes through here.
func closeOrder(o *order, reason string) {
	refund := o.remGive
	if refund > 0 {
		creditBal(o.maker, o.give, refund)
		o.remGive = 0
	}
	sideRemove(o)
	recs := makerRecs(o.maker)
	pre := padU(o.id, 12) + "|"
	for i, r := range recs {
		if strings.HasPrefix(r, pre) {
			recs = append(recs[:i], recs[i+1:]...)
			break
		}
	}
	setMakerRecs(o.maker, recs)
	openOrderTotal = subChk(openOrderTotal, 1)
	std.Emit("OrderClosed", "id", u(o.id), "maker", o.maker, "reason", reason, "refund", u(refund))
}

// CancelOrder: the maker gets the remaining escrow back. Works while paused
// and for banned makers; only the maker can cancel.
func CancelOrder(cur realm, id uint64) {
	caller := exchangeCaller(cur)
	// Lookup is by the caller's own orders only: nobody can name someone
	// else's order here.
	o := loadOrderOf(caller, id)
	if o == nil {
		panic("no such open order (or not your order)")
	}
	closeOrder(o, "cancel")
}

// SweepExpiredOrders closes up to maxScanPerTx expired orders of one book
// side, refunding each maker. Anyone may call it (also while paused).
func SweepExpiredOrders(cur realm, pay string, get string) int {
	exchangeCaller(cur)
	now := time.Now().Unix()
	var expired []*order
	scanned := 0
	iterSide(pay, get, func(maker string, id uint64) bool {
		scanned++
		if scanned > maxScanPerTx {
			return true
		}
		o := loadOrderOf(maker, id)
		if o != nil && o.expiry < now {
			expired = append(expired, o)
		}
		return false
	})
	for _, o := range expired {
		closeOrder(o, "expired")
	}
	return len(expired)
}

type fillStep struct {
	o    *order
	x, g uint64 // taker pays x (+fee) of `pay`, receives g of `get`
}

// planFills walks the book for a taker (read-only). budget is the most the
// taker will spend INCLUDING the taker fee. Own orders are skipped (no
// self-match); expired orders are returned for closing.
func planFills(caller, pay, get string, budget uint64, maxFills int, now int64) ([]fillStep, []*order, uint64, uint64) {
	if maxFills <= 0 || maxFills > maxFillsPerTx {
		maxFills = maxFillsPerTx
	}
	var steps []fillStep
	var expired []*order
	remaining := budget
	spent, got := uint64(0), uint64(0)
	scanned := 0
	iterSide(pay, get, func(maker string, id uint64) bool {
		scanned++
		if scanned > maxScanPerTx || len(steps) >= maxFills || remaining == 0 {
			return true
		}
		o := loadOrderOf(maker, id)
		if o == nil {
			return false
		}
		if o.expiry < now {
			expired = append(expired, o)
			return false
		}
		if o.maker == caller {
			return false // no self-match: skip, never touch the taker's own order
		}
		// largest x with x + ceil(x × takerFee) ≤ remaining
		x := mulDiv(remaining, 10000, 10000+takerFeeBps)
		for i := 0; i < 4 && x > 0 && addChk(x, mulDivUp(x, takerFeeBps, 10000)) > remaining; i++ {
			x--
		}
		if x > o.remWant {
			x = o.remWant
		}
		if x == 0 {
			return true
		}
		g := o.remGive
		if x < o.remWant {
			g = mulDiv(x, o.remGive, o.remWant) // floor: the maker never sells below their price
		}
		if g == 0 {
			return true
		}
		cost := addChk(x, mulDivUp(x, takerFeeBps, 10000))
		steps = append(steps, fillStep{o: o, x: x, g: g})
		remaining = subChk(remaining, cost)
		spent = addChk(spent, cost)
		got = addChk(got, g)
		return false
	})
	return steps, expired, spent, got
}

// executeFills applies a plan: the taker pays each maker x and the protocol
// fee, receives g from escrow. Returns the total received.
func executeFills(caller, pay string, steps []fillStep) uint64 {
	got := uint64(0)
	for _, st := range steps {
		o := st.o
		fee := mulDivUp(st.x, takerFeeBps, 10000)
		debitBal(caller, pay, addChk(st.x, fee))
		accrueProtocolFee(pay, fee)
		creditBal(o.maker, pay, st.x)
		o.remWant = subChk(o.remWant, st.x)
		o.remGive = subChk(o.remGive, st.g)
		got = addChk(got, st.g)
		std.Emit("OrderFilled", "id", u(o.id), "maker", o.maker, "taker", caller,
			"paid", u(st.x), "fee", u(fee), "got", u(st.g))
		if o.remWant == 0 || o.remGive == 0 {
			closeOrder(o, "filled")
		} else if grinValueMilli(o.give, o.remGive) < minOrderGrinX1k {
			closeOrder(o, "dust")
		} else {
			saveOrder(o)
		}
	}
	return got
}

// FillOrders: spend at most payAmt of `pay` (taker fee included) on the
// best-priced orders that give `get`; receive at least minGet or revert.
// ≤ 10 fills and ≤ 20 scanned entries per call.
func FillOrders(cur realm, pay string, get string, payAmt uint64, minGet uint64, maxFills int, deadline int64) uint64 {
	caller := exchangeCaller(cur)
	requireMarketOpen(caller)
	requireDeadline(deadline)
	requireCoin(pay)
	requireCoin(get)
	requireAmount("payAmt", payAmt)
	steps, expired, spent, planned := planFills(caller, pay, get, payAmt, maxFills, time.Now().Unix())
	if planned == 0 || planned < minGet {
		panic("slippage: received below minimum")
	}
	requireBalance(caller, pay, spent)
	// ── all checks passed; writes start here ──
	for _, o := range expired {
		closeOrder(o, "expired")
	}
	got := executeFills(caller, pay, steps)
	if got != planned {
		panic("invariant: fill plan mismatch")
	}
	creditBal(caller, get, got)
	return got
}

// ── views ────────────────────────────────────────────────────────────────────

func orderJSON(o *order) string {
	return `{"id":"` + u(o.id) + `","maker":"` + o.maker + `","give":` + jsonStr(o.give) + `,"want":` + jsonStr(o.want) +
		`,"remGive":"` + u(o.remGive) + `","remWant":"` + u(o.remWant) + `","expiry":` + strconv.FormatInt(o.expiry, 10) + `}`
}

// Order shows one open order of `maker` (lookups are per maker by design).
func Order(maker string, id uint64) string {
	o := loadOrderOf(maker, id)
	if o == nil {
		return `{"id":"` + u(id) + `","open":false}`
	}
	return orderJSON(o)
}

// OrdersOf lists an address's open orders (≤ 20 by construction).
func OrdersOf(addr string) string {
	out := "["
	for i, r := range makerRecs(addr) {
		if i > 0 {
			out += ","
		}
		out += orderJSON(decodeOrder(addr, r))
	}
	return out + "]"
}

// BookDepth lists asks for a taker who pays `pay` and gets `get`, best price
// first (≤ 50 rows; offset < maxSideOrders).
func BookDepth(pay string, get string, limit int, offset int) string {
	if limit <= 0 || limit > maxViewLimit {
		limit = maxViewLimit
	}
	if offset < 0 || offset >= maxSideOrders {
		offset = 0
	}
	out := "["
	i, n := 0, 0
	iterSide(pay, get, func(maker string, id uint64) bool {
		if i < offset {
			i++
			return false
		}
		if o := loadOrderOf(maker, id); o != nil {
			if n > 0 {
				out += ","
			}
			out += orderJSON(o)
			n++
		}
		return n >= limit
	})
	return out + "]"
}

// QuoteFill previews FillOrders for a budget (fee included): {"spent","got"}.
func QuoteFill(caller string, pay string, get string, payAmt uint64, maxFills int) string {
	if payAmt == 0 || payAmt > maxAmount {
		return `{"spent":"0","got":"0","fills":0}`
	}
	steps, _, spent, got := planFills(caller, pay, get, payAmt, maxFills, time.Now().Unix())
	return `{"spent":"` + u(spent) + `","got":"` + u(got) + `","fills":` + strconv.Itoa(len(steps)) + `}`
}
