package tapster

import (
	"strings"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/nt/ufmt/v0"
)

// The functions in this file are free, read-only and safe to call from any
// realm. They return plain values, never pointers to internal state.

// Latest returns the latest finalized price for pair, its decimals, the
// unix time it was finalized and its round. ok is false if the feed does
// not exist or has no answer yet.
//
//	price, dec, at, _, ok := tapster.Latest("GNOT-USD")
func Latest(pair string) (price int64, decimals int, updatedAt int64, round int64, ok bool) {
	v := feeds.Get(pair)
	if v == nil {
		return 0, 0, 0, 0, false
	}
	f := v.(*Feed)
	if !f.hasAnswer {
		return 0, f.Decimals, 0, 0, false
	}
	return f.latest.Price, f.Decimals, f.latest.At, f.latest.Round, true
}

// PriceFresh returns the latest price for pair only if it is at most
// maxAgeSecs old. Use it whenever money moves on the price.
//
//	price, dec, ok := tapster.PriceFresh("GNOT-USD", 600)
//	if !ok { panic("GNOT-USD price is stale") }
func PriceFresh(pair string, maxAgeSecs int64) (price int64, decimals int, ok bool) {
	p, d, at, _, has := Latest(pair)
	if !has {
		return 0, d, false
	}
	if now()-at > maxAgeSecs {
		return 0, d, false
	}
	return p, d, true
}

// MustPriceFresh is PriceFresh that panics when the price is missing or
// stale, which aborts the caller's transaction.
func MustPriceFresh(pair string, maxAgeSecs int64) (price int64, decimals int) {
	p, d, ok := PriceFresh(pair, maxAgeSecs)
	if !ok {
		panic("tapster: no fresh price for " + pair)
	}
	return p, d
}

// Pairs returns the feed names, comma-separated.
func Pairs() string {
	var out []string
	feeds.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return strings.Join(out, ",")
}

// History returns up to n most recent answers for pair as
// "unix:price" pairs, comma-separated, oldest first.
func History(pair string, n int) string {
	f := mustFeed(pair)
	h := f.history
	if n > 0 && n < len(h) {
		h = h[len(h)-n:]
	}
	parts := make([]string, len(h))
	for i, a := range h {
		parts[i] = ufmt.Sprintf("%d:%d", a.At, a.Price)
	}
	return strings.Join(parts, ",")
}

// ReporterStake returns a reporter's current stake and claimable rewards.
func ReporterStake(addr address) (stake int64, rewards int64, active bool) {
	r := getReporter(addr)
	if r == nil {
		return 0, 0, false
	}
	return r.Stake, r.Rewards, r.ExitAt == 0 && r.Stake >= minStake
}

// Admin returns the admin address.
func Admin() address { return admin }

// MinStake returns the minimum stake in ugnot.
func MinStake() int64 { return minStake }

// Consumer is a realm that declared it uses Tapster prices.
type Consumer struct {
	Path  string
	Note  string
	Since int64
}

var consumers = avl.NewTree() // pkgpath -> *Consumer

// RegisterConsumer lists the calling realm on the "Used by" section. It
// must be called by a realm (not an account), typically from its init:
//
//	func init(cur realm) { tapster.RegisterConsumer(cross(cur), "bar tabs in USD") }
func RegisterConsumer(cur realm, note string) {
	assertCurrent(cur)
	prev := cur.Previous()
	if prev.PkgPath() == "" || !strings.HasPrefix(prev.PkgPath(), "gno.land/r/") {
		panic("only realms can register as consumers")
	}
	if len(note) > 80 {
		panic("note too long (max 80)")
	}
	for _, c := range note {
		if c == '[' || c == ']' || c == '(' || c == ')' || c == '<' || c == '>' || c == '|' || c == '`' || c == '\n' {
			panic("note contains characters that are not allowed")
		}
	}
	path := prev.PkgPath()
	if v := consumers.Get(path); v != nil {
		v.(*Consumer).Note = note
		return
	}
	consumers.Set(path, &Consumer{Path: path, Note: note, Since: now()})
	logEvent("consumer", path+" started using Tapster")
}

// Consumers returns the registered consumer realm paths, comma-separated.
func Consumers() string {
	var out []string
	consumers.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return strings.Join(out, ",")
}
