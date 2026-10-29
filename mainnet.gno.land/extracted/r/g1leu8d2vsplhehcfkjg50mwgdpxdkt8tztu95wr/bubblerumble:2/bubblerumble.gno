// Package bubblerumble is a last-bidder-wins game in GNOT.
//
// A pool has a pot and a clock. Every bid goes into the pot and resets the
// clock; the Nth bid costs BasePrice·√N. When the clock runs out, the last
// bidder takes the whole pot. Anyone can open a pool, and the coins sent with
// CreatePool seed its pot.
//
// Paying more than the price buys a shorter clock: k× the price gives that bid
// a clock of window/k, never below a tenth of the window. The whole amount goes
// into the pot, and the next bid runs the full window again.
package bubblerumble

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"math"
	"strconv"
	"strings"
	"time"
)

const (
	MinWindow    int64 = 10                // seconds
	MaxWindow    int64 = 30 * 24 * 3600    // 30 days
	MinBasePrice int64 = 1_000             // ugnot, 0.001 GNOT
	MaxBasePrice int64 = 1_000_000_000_000 // ugnot, 1,000,000 GNOT
	MaxNameLen         = 40
	HistoryLen         = 50 // bids kept per pool for the feed
	MaxBoost     int64 = 10 // the shortest clock a bid can buy is window/MaxBoost
)

type Entry struct {
	N      int64
	Bidder address
	Price  int64 // what was paid; at least the price at the time
	Clock  int64 // seconds this bid had to stand
	Pot    int64 // pot right after this bid
	At     time.Time
}

type Pool struct {
	ID         int64
	Name       string
	Creator    address
	Window     int64 // seconds the last bid must stand to win
	BasePrice  int64 // ugnot; the Nth bid costs BasePrice·√N
	Seed       int64
	Pot        int64
	Bids       int64
	LastBidder address
	LastBidAt  time.Time
	Clock      int64 // seconds the current top bid has to stand: Window, or less if it paid for it
	CreatedAt  time.Time
	Paid       bool // the pot went to the winner, or the seed back to the creator
	Cancelled  bool
	History    []Entry
}

// pkgPath must match gnomod.toml: the realm's own address derives from it.
const pkgPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble"

var (
	pools     []*Pool
	realmAddr = chain.PackageAddress(pkgPath)
)

// Price of the next bid in a pool with the given base price and n bids so far.
// Sublinear in n: bid 1 costs base, bid 4 costs 2·base, bid 100 costs 10·base.
func Price(base, n int64) int64 {
	return int64(math.Ceil(float64(base) * math.Sqrt(float64(n+1))))
}

// Deadline is when the pool closes if nobody else bids. Meaningless before the first bid.
func (p *Pool) Deadline() time.Time {
	return p.LastBidAt.Add(time.Duration(p.Clock) * time.Second)
}

// ClockFor is the clock a bid buys by paying sent against a price: the window
// divided by the multiple paid, never below window/MaxBoost.
func ClockFor(window, price, sent int64) int64 {
	c := int64(float64(window) * float64(price) / float64(sent))
	if c < window/MaxBoost {
		c = window / MaxBoost
	}
	if c < 1 {
		c = 1
	}
	return c
}

// Over reports whether the clock has run out, which is the moment a pool has a winner.
func (p *Pool) Over() bool {
	return p.Bids > 0 && !time.Now().Before(p.Deadline())
}

// NextPrice is what the next bid costs.
func (p *Pool) NextPrice() int64 {
	return Price(p.BasePrice, p.Bids)
}

// CreatePool opens a pool. Any ugnot sent with the call seeds its pot.
// Returns the new pool's id.
func CreatePool(cur realm, name string, window int64, basePrice int64) int64 {
	creator := userCaller(cur)
	name = cleanName(name)
	if window < MinWindow || window > MaxWindow {
		panic("window must be between 10s and 30d")
	}
	if basePrice < MinBasePrice || basePrice > MaxBasePrice {
		panic("base price must be between 0.001 and 1,000,000 GNOT")
	}
	seed := ugnotSent()
	p := &Pool{
		ID: int64(len(pools)) + 1, Name: name, Creator: creator, Window: window,
		BasePrice: basePrice, Seed: seed, Pot: seed, CreatedAt: time.Now(),
	}
	pools = append(pools, p)
	chain.Emit("PoolCreated", "id", itoa(p.ID), "creator", creator.String(), "seed", itoa(seed))
	return p.ID
}

// Bid pays at least the current price into a pool's pot and resets its clock;
// paying k× the price makes this bid's clock window/k (see ClockFor).
func Bid(cur realm, id int64) {
	bidder := userCaller(cur)
	p := pool(id)
	if p.Cancelled {
		panic("pool was cancelled")
	}
	if p.Over() {
		panic("pool is closed")
	}
	if p.LastBidder == bidder {
		panic("you are already the last bidder")
	}
	price := p.NextPrice()
	sent := ugnotSent()
	if sent < price {
		panic("send at least " + itoa(price) + "ugnot, got " + itoa(sent) + "ugnot")
	}
	p.Pot += sent
	p.Bids++
	p.LastBidder = bidder
	p.LastBidAt = time.Now()
	p.Clock = ClockFor(p.Window, price, sent)
	p.History = append(p.History, Entry{N: p.Bids, Bidder: bidder, Price: sent, Clock: p.Clock, Pot: p.Pot, At: p.LastBidAt})
	if len(p.History) > HistoryLen {
		p.History = p.History[len(p.History)-HistoryLen:]
	}
	chain.Emit("Bid", "id", itoa(id), "n", itoa(p.Bids), "bidder", bidder.String(), "paid", itoa(sent), "clock", itoa(p.Clock), "pot", itoa(p.Pot))
}

// Claim sends a finished pool's pot to its winner. Anyone may call it.
func Claim(cur realm, id int64) {
	p := pool(id)
	if p.Cancelled {
		panic("pool was cancelled")
	}
	if !p.Over() {
		panic("clock still running")
	}
	if p.Paid {
		panic("already paid out")
	}
	p.Paid = true
	send(cur, p.LastBidder, p.Pot)
	chain.Emit("Paid", "id", itoa(id), "winner", p.LastBidder.String(), "pot", itoa(p.Pot))
}

// Cancel lets the creator take the seed back from a pool nobody has bid on.
func Cancel(cur realm, id int64) {
	caller := userCaller(cur)
	p := pool(id)
	if p.Creator != caller {
		panic("only the creator can cancel")
	}
	if p.Bids > 0 {
		panic("pool already has bids")
	}
	if p.Cancelled {
		panic("already cancelled")
	}
	p.Cancelled = true
	p.Paid = true
	if p.Pot > 0 {
		send(cur, caller, p.Pot)
	}
	chain.Emit("Cancelled", "id", itoa(id))
}

func send(cur realm, to address, ugnot int64) {
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(realmAddr, to, chain.Coins{{"ugnot", ugnot}})
}

func pool(id int64) *Pool {
	if id < 1 || id > int64(len(pools)) {
		panic("no such pool")
	}
	return pools[id-1]
}

// userCaller is the signer of the transaction, refusing calls relayed through
// another realm so nobody can bid on someone else's behalf.
func userCaller(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("must be a direct user call")
	}
	return prev.Address()
}

func ugnotSent() int64 {
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != "ugnot" {
			panic("only ugnot is accepted")
		}
	}
	return sent.AmountOf("ugnot")
}

func cleanName(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || len(s) > MaxNameLen {
		panic("name must be 1-40 characters")
	}
	for _, c := range s {
		if c < 0x20 || c == 0x7f {
			panic("name has control characters")
		}
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func parseID(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("bad pool id")
	}
	return n
}

// GNOT formats ugnot as GNOT with the trailing zeros trimmed.
func GNOT(ugnot int64) string {
	whole, frac := ugnot/1_000_000, ugnot%1_000_000
	if frac == 0 {
		return itoa(whole) + " GNOT"
	}
	f := strconv.FormatInt(1_000_000+frac, 10)[1:] // six digits, zero padded
	return itoa(whole) + "." + strings.TrimRight(f, "0") + " GNOT"
}

func short(a address) string {
	s := a.String()
	if len(s) < 12 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func dur(sec int64) string {
	if sec <= 0 {
		return "0s"
	}
	d, h, m, s := sec/86400, sec%86400/3600, sec%3600/60, sec%60
	out := ""
	if d > 0 {
		out += itoa(d) + "d "
	}
	if d > 0 || h > 0 {
		out += itoa(h) + "h "
	}
	if d > 0 || h > 0 || m > 0 {
		out += itoa(m) + "m "
	}
	return out + itoa(s) + "s"
}

// --- rendering ---------------------------------------------------------------

// Render serves gnoweb ("" and "<id>") and the web page ("json" and "json/<id>").
func Render(path string) string {
	path = strings.Trim(path, "/")
	switch {
	case path == "json":
		return jsonAll()
	case strings.HasPrefix(path, "json/"):
		return pool(parseID(path[5:])).json(true)
	case path == "":
		return markdownAll()
	default:
		return pool(parseID(path)).markdown()
	}
}

func unix(t time.Time) string {
	if t.IsZero() {
		return "0"
	}
	return itoa(t.Unix())
}

func jbool(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func (p *Pool) json(withHistory bool) string {
	var b strings.Builder
	b.WriteString("{\"id\":" + itoa(p.ID))
	b.WriteString(",\"name\":" + strconv.Quote(p.Name))
	b.WriteString(",\"creator\":\"" + p.Creator.String() + "\"")
	b.WriteString(",\"window\":" + itoa(p.Window))
	b.WriteString(",\"basePrice\":" + itoa(p.BasePrice))
	b.WriteString(",\"seed\":" + itoa(p.Seed))
	b.WriteString(",\"pot\":" + itoa(p.Pot))
	b.WriteString(",\"bids\":" + itoa(p.Bids))
	b.WriteString(",\"nextPrice\":" + itoa(p.NextPrice()))
	b.WriteString(",\"lastBidder\":\"" + p.LastBidder.String() + "\"")
	b.WriteString(",\"lastBidAt\":" + unix(p.LastBidAt))
	b.WriteString(",\"clock\":" + itoa(p.Clock))
	b.WriteString(",\"createdAt\":" + unix(p.CreatedAt))
	b.WriteString(",\"over\":" + jbool(p.Over()))
	b.WriteString(",\"paid\":" + jbool(p.Paid))
	b.WriteString(",\"cancelled\":" + jbool(p.Cancelled))
	if withHistory {
		b.WriteString(",\"history\":[")
		for i := len(p.History) - 1; i >= 0; i-- { // newest first
			h := p.History[i]
			if i < len(p.History)-1 {
				b.WriteString(",")
			}
			b.WriteString("{\"n\":" + itoa(h.N) + ",\"bidder\":\"" + h.Bidder.String() + "\",\"price\":" + itoa(h.Price) + ",\"clock\":" + itoa(h.Clock) + ",\"pot\":" + itoa(h.Pot) + ",\"at\":" + unix(h.At) + "}")
		}
		b.WriteString("]")
	}
	b.WriteString("}")
	return b.String()
}

func jsonAll() string {
	var b strings.Builder
	b.WriteString("{\"now\":" + itoa(time.Now().Unix()) + ",\"realm\":\"" + pkgPath + "\",\"pools\":[")
	for i, p := range pools {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(p.json(false))
	}
	b.WriteString("]}")
	return b.String()
}

func (p *Pool) status() string {
	switch {
	case p.Cancelled:
		return "cancelled"
	case p.Over():
		s := "won by " + short(p.LastBidder)
		if !p.Paid {
			s += " (unclaimed)"
		}
		return s
	case p.Bids == 0:
		return "no bids yet · " + dur(p.Window) + " window · next " + GNOT(p.NextPrice())
	default:
		left := p.Deadline().Unix() - time.Now().Unix()
		s := dur(left) + " left"
		if p.Clock < p.Window {
			s += " of a " + dur(p.Clock) + " clock"
		}
		return s + " · " + short(p.LastBidder) + " on top · next " + GNOT(p.NextPrice())
	}
}

func markdownAll() string {
	var b strings.Builder
	b.WriteString("# Bubble Rumble\n\n")
	b.WriteString("Every bid goes into a pool's pot and resets its clock. The Nth bid costs base·√N. ")
	b.WriteString("When the clock runs out, the last bidder takes the whole pot. Play at [bubblerumble.net](https://bubblerumble.net).\n\n")
	if len(pools) == 0 {
		b.WriteString("_No pools yet._\n")
		return b.String()
	}
	b.WriteString("## Pools\n\n")
	for i := len(pools) - 1; i >= 0; i-- {
		p := pools[i]
		b.WriteString("- [" + p.Name + "](?" + itoa(p.ID) + ") — **" + GNOT(p.Pot) + "** · " + itoa(p.Bids) + " bids · " + p.status() + "\n")
	}
	return b.String()
}

func (p *Pool) markdown() string {
	var b strings.Builder
	b.WriteString("# " + p.Name + "\n\n")
	b.WriteString("**" + GNOT(p.Pot) + "** in the pot · " + p.status() + "\n\n")
	b.WriteString("Opened by " + short(p.Creator) + " · " + dur(p.Window) + " window · base " + GNOT(p.BasePrice) + " · seed " + GNOT(p.Seed) + "\n\n")
	if len(p.History) > 0 {
		b.WriteString("## Bids\n\n")
		for i := len(p.History) - 1; i >= 0; i-- {
			h := p.History[i]
			b.WriteString("- #" + itoa(h.N) + " " + short(h.Bidder) + " paid " + GNOT(h.Price) + " → pot " + GNOT(h.Pot) + "\n")
		}
	}
	return b.String()
}
