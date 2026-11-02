package sugarproxy

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"math/overflow"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

// Paying sharers. The hub tallies the bytes each sharer's app carried and pays them through Pay, so every payout
// is on chain: who was paid, how much, for how many bytes, in which period. The hub's account is an approved payer;
// it signs with a gno.land session key whose spending the chain caps (only calls to this realm, so much a period),
// so a stolen hub key can pay out at most one period's worth, and only through here, where it shows.

const denom = "ugnot"

// Totals is what a sharer has been paid, all told.
type Totals struct {
	Paid    int64 // ugnot
	Bytes   int64
	Payouts int
	Last    int64 // unix seconds
}

// Payout is one call to Pay.
type Payout struct {
	Time     int64
	Payer    address
	Period   string
	Receipts string // the hex sha256 of the payer's receipts for the period: the confirmed downloads it paid for
	Count    int
	Ugnot    int64
	Bytes    int64
}

var (
	totals  = avl.NewTree() // address -> *Totals
	payouts []*Payout
)

// Pay pays sharers with the GNOT sent along. lines has one sharer a line: "address ugnot bytes"; the amounts must
// add up to what was sent, and a payout is at most 500 lines. period names what it pays for ("2026-11-01", say);
// receipts is the hex sha256 of the payer's receipts for it (one line per confirmed download: its tag, the file's
// sha256 and size, who carried how much), recorded here so the receipts can be checked against it later. Only an
// approved payer may call it; pausing doesn't stop it (sharers are owed for what they carried).
func Pay(cur realm, period, receipts, lines string) {
	payer := mustUser(cur)
	if !payerActive(payer) {
		panic("only an approved payer may pay")
	}
	if len(period) == 0 || len(period) > 40 || strings.ContainsAny(period, "\n\r\t") {
		panic("the period is 1 to 40 characters on one line")
	}
	if !hexOf(receipts, 64) {
		panic("receipts is the receipts' sha256: 64 lowercase hex")
	}
	sent := coinsSent(cur)
	type line struct {
		to           address
		ugnot, bytes int64
	}
	var all []line
	var sum, bytes int64
	for _, l := range strings.Split(strings.TrimSpace(lines), "\n") {
		f := strings.Fields(l)
		if len(f) != 3 {
			panic("each line is: address ugnot bytes")
		}
		to := address(f[0])
		u, err1 := strconv.ParseInt(f[1], 10, 64)
		b, err2 := strconv.ParseInt(f[2], 10, 64)
		if !to.IsValid() || err1 != nil || err2 != nil || u <= 0 || b < 0 {
			panic("a bad line: " + l)
		}
		sum = overflow.Add64p(sum, u)
		bytes = overflow.Add64p(bytes, b)
		all = append(all, line{to, u, b})
	}
	if len(all) == 0 || len(all) > 500 {
		panic("a payout is 1 to 500 lines")
	}
	if sum != sent {
		panic("the amounts add up to " + strconv.FormatInt(sum, 10) + " ugnot, but " + strconv.FormatInt(sent, 10) + " were sent")
	}
	now := time.Now().Unix()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	for _, l := range all {
		bk.SendCoins(cur.Address(), l.to, chain.Coins{chain.NewCoin(denom, l.ugnot)})
		t, _ := totals.Get(l.to.String()).(*Totals)
		if t == nil {
			t = &Totals{}
			totals.Set(l.to.String(), t)
		}
		t.Paid = overflow.Add64p(t.Paid, l.ugnot)
		t.Bytes = overflow.Add64p(t.Bytes, l.bytes)
		t.Payouts++
		t.Last = now
		chain.Emit("Paid", "to", l.to.String(), "ugnot", strconv.FormatInt(l.ugnot, 10), "bytes", strconv.FormatInt(l.bytes, 10), "period", period)
	}
	payouts = append(payouts, &Payout{Time: now, Payer: payer, Period: period, Receipts: receipts, Count: len(all), Ugnot: sum, Bytes: bytes})
	chain.Emit("Payout", "period", period, "receipts", receipts, "sharers", strconv.Itoa(len(all)), "ugnot", strconv.FormatInt(sum, 10))
}

// PaidTo is what a sharer has been paid, all told.
func PaidTo(a address) (ugnot, bytes int64, count int) {
	if t, ok := totals.Get(a.String()).(*Totals); ok && t != nil {
		return t.Paid, t.Bytes, t.Payouts
	}
	return 0, 0, 0
}

func payerActive(a address) bool {
	now := time.Now().Unix()
	for _, it := range items {
		if it.Kind == KindPayer && it.Fields[0] == a.String() && it.State == StateApproved && now >= it.After {
			return true
		}
	}
	return false
}

// coinsSent returns the ugnot sent with a direct call, refusing other denoms. Coins sent with a run go to the run's
// own address, not here, so a run sends none.
func coinsSent(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		return 0
	}
	var n int64
	for _, c := range unsafe.OriginSend() {
		if c.Amount == 0 {
			continue
		}
		if c.Denom != denom || c.Amount < 0 {
			panic("only " + denom + " is taken")
		}
		n = overflow.Add64p(n, c.Amount)
	}
	return n
}
