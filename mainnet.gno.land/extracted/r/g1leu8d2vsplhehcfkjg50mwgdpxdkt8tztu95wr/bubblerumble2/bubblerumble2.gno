// Package bubblerumble2 is the second Bubble Rumble realm: the same last-bidder-
// wins clock as v1, with the money rearranged so that players want company.
//
// Of every bid: 55% goes to the pot, 30% is paid at once to the earlier bidders
// of that pool pro-rata to what they have paid in, 10% goes to whoever first
// invited the bidder (forever, on every bid they make), 5% to the pool's creator.
// When the clock runs out, 80% of the pot goes to the last bidder and 20% is
// shared among everyone who played under the winner's flag — or all of it to the
// winner if nobody else flew that flag.
//
// So the player on top wants more bids (each one pays them), everyone wants
// their invitees to bid (10% of everything), and countries are teams.
package bubblerumble2

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
	HistoryLen         = 50  // bids kept per pool for the feed
	RosterMax          = 200 // distinct bidders a pool pays dividends and team shares to
	MaxBoost     int64 = 10  // the shortest clock a bid can buy is window/MaxBoost

	// where every bid goes, in percent
	PotShare     int64 = 55
	DivShare     int64 = 30 // to earlier bidders of the pool, pro-rata by paid-in
	RefShare     int64 = 10 // to the bidder's inviter
	CreatorShare int64 = 5
	// of the pot at the close: the rest goes to the winner
	TeamShare int64 = 20
)

// pkgPath must match gnomod.toml: the realm's own address derives from it.
const pkgPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble2"

type Entry struct {
	N      int64
	Bidder address
	Flag   string
	Price  int64 // what was paid; at least the price at the time
	Clock  int64 // seconds this bid had to stand
	Pot    int64 // pot right after this bid
	At     time.Time
}

// Member is a distinct bidder of a pool: the roster dividends and team shares go to.
type Member struct {
	Addr   address
	Flag   string
	Paid   int64 // gross paid into this pool; the dividend weight
	Earned int64 // dividends received from this pool
}

type Pool struct {
	ID          int64
	Name        string
	Creator     address
	Window      int64 // seconds the last bid must stand to win
	BasePrice   int64 // ugnot; the Nth bid costs BasePrice·√N
	Seed        int64
	Pot         int64
	Bids        int64
	LastBidder  address
	LastBidAt   time.Time
	Clock       int64 // seconds the current top bid has to stand
	CreatedAt   time.Time
	Paid        bool // the pot went out, or the seed back to the creator
	Cancelled   bool
	DivPaid     int64 // dividends paid out of this pool so far
	RefPaid     int64
	CreatorPaid int64
	WinnerFlag  string
	TeamPaid    int64 // what the winner's team received at the close
	History     []Entry
	Roster      []*Member
}

// Player is what the realm remembers about an address across pools.
type Player struct {
	Referrer  address // set by the first bid, permanent
	Recruits  int64
	Flag      string
	Bids      int64
	Paid      int64
	DivEarned int64
	RefEarned int64
	Won       int64 // pots and team shares received
}

var (
	pools     []*Pool
	players   = map[address]*Player{}
	teamPaid  = map[string]int64{} // flag -> gross bid volume under it
	teamWon   = map[string]int64{} // flag -> pots closed under it
	teamSize  = map[string]int64{} // flag -> players flying it
	realmAddr = chain.PackageAddress(pkgPath)
)

// Price of the next bid in a pool with the given base price and n bids so far.
func Price(base, n int64) int64 {
	return int64(math.Ceil(float64(base) * math.Sqrt(float64(n+1))))
}

func (p *Pool) Deadline() time.Time { return p.LastBidAt.Add(time.Duration(p.Clock) * time.Second) }
func (p *Pool) Over() bool           { return p.Bids > 0 && !time.Now().Before(p.Deadline()) }
func (p *Pool) NextPrice() int64     { return Price(p.BasePrice, p.Bids) }

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

// CreatePool opens a pool. Any ugnot sent with the call seeds its pot. The
// creator earns CreatorShare of every bid.
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

// Bid pays at least the current price and resets the clock. ref is the address
// that invited the bidder ("" for none; only the first bid ever sets it), flag
// a two-letter country to play under ("" keeps the last one).
func Bid(cur realm, id int64, ref string, flag string) {
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
	pl := player(bidder)
	if f := cleanFlag(flag); f != "" && f != pl.Flag {
		if pl.Flag != "" {
			teamSize[pl.Flag]--
		}
		pl.Flag = f
		teamSize[f]++
	}
	if pl.Referrer == "" && ref != "" {
		r := address(ref)
		if r.IsValid() && r != bidder {
			pl.Referrer = r
			player(r).Recruits++
		}
	}

	// where the money goes
	div, refCut, creatorCut := sent*DivShare/100, sent*RefShare/100, sent*CreatorShare/100
	toPot := sent - div - refCut - creatorCut
	if creatorCut > 0 {
		send(cur, p.Creator, creatorCut)
		p.CreatorPaid += creatorCut
	}
	if pl.Referrer != "" && refCut > 0 {
		send(cur, pl.Referrer, refCut)
		p.RefPaid += refCut
		player(pl.Referrer).RefEarned += refCut
	} else {
		toPot += refCut
	}
	toPot += p.payDividends(cur, bidder, div)
	p.Pot += toPot

	m := p.member(bidder)
	m.Paid += sent
	m.Flag = pl.Flag
	pl.Bids++
	pl.Paid += sent
	if pl.Flag != "" {
		teamPaid[pl.Flag] += sent
	}
	p.Bids++
	p.LastBidder = bidder
	p.LastBidAt = time.Now()
	p.Clock = ClockFor(p.Window, price, sent)
	p.History = append(p.History, Entry{N: p.Bids, Bidder: bidder, Flag: pl.Flag, Price: sent, Clock: p.Clock, Pot: p.Pot, At: p.LastBidAt})
	if len(p.History) > HistoryLen {
		p.History = p.History[len(p.History)-HistoryLen:]
	}
	chain.Emit("Bid", "id", itoa(id), "n", itoa(p.Bids), "bidder", bidder.String(), "paid", itoa(sent), "pot", itoa(p.Pot), "div", itoa(div-(toPot-(sent-div-refCut-creatorCut))))
}

// payDividends splits div among the pool's earlier bidders, pro-rata to what
// each has paid in, skipping the bidder; whatever cannot be placed (no earlier
// bidders, rounding) is returned to go into the pot.
func (p *Pool) payDividends(cur realm, bidder address, div int64) int64 {
	var total int64
	for _, m := range p.Roster {
		if m.Addr != bidder {
			total += m.Paid
		}
	}
	if total == 0 || div == 0 {
		return div
	}
	var paid int64
	for _, m := range p.Roster {
		if m.Addr == bidder {
			continue
		}
		amt := div * m.Paid / total
		if amt > 0 {
			send(cur, m.Addr, amt)
			m.Earned += amt
			player(m.Addr).DivEarned += amt
			paid += amt
		}
	}
	p.DivPaid += paid
	return div - paid
}

// member finds or adds a bidder on the roster; a full roster drops its oldest.
func (p *Pool) member(a address) *Member {
	for _, m := range p.Roster {
		if m.Addr == a {
			return m
		}
	}
	if len(p.Roster) >= RosterMax {
		p.Roster = p.Roster[1:]
	}
	m := &Member{Addr: a}
	p.Roster = append(p.Roster, m)
	return m
}

// Claim pays out a finished pool: 80% to the winner, 20% shared among the
// roster members flying the winner's flag (pro-rata by paid-in, the winner
// included) — or everything to the winner when nobody else flew it. Anyone may call it.
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
	winner := p.LastBidder
	flag := ""
	if m := p.find(winner); m != nil {
		flag = m.Flag
	}
	p.WinnerFlag = flag
	var team int64
	var mates int
	if flag != "" {
		for _, m := range p.Roster {
			if m.Flag == flag {
				team += m.Paid
				mates++
			}
		}
	}
	rest := p.Pot
	if mates > 1 && team > 0 {
		cut := p.Pot * TeamShare / 100
		for _, m := range p.Roster {
			if m.Flag != flag {
				continue
			}
			amt := cut * m.Paid / team
			if amt > 0 {
				send(cur, m.Addr, amt)
				player(m.Addr).Won += amt
				rest -= amt
				p.TeamPaid += amt
			}
		}
	}
	send(cur, winner, rest)
	player(winner).Won += rest
	if flag != "" {
		teamWon[flag] += p.Pot
	}
	chain.Emit("Paid", "id", itoa(id), "winner", winner.String(), "pot", itoa(p.Pot), "team", itoa(p.TeamPaid))
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

func (p *Pool) find(a address) *Member {
	for _, m := range p.Roster {
		if m.Addr == a {
			return m
		}
	}
	return nil
}

func player(a address) *Player {
	pl := players[a]
	if pl == nil {
		pl = &Player{}
		players[a] = pl
	}
	return pl
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

// cleanFlag accepts a two-letter country code, upper-cased; anything else is "".
func cleanFlag(s string) string {
	s = strings.ToUpper(strings.TrimSpace(s))
	if len(s) != 2 || s[0] < 'A' || s[0] > 'Z' || s[1] < 'A' || s[1] > 'Z' {
		return ""
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
	f := strconv.FormatInt(1_000_000+frac, 10)[1:]
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

// Render serves gnoweb ("" and "<id>") and the page ("json", "json/<id>",
// "me/<address>", "teams").
func Render(path string) string {
	path = strings.Trim(path, "/")
	switch {
	case path == "json":
		return jsonAll()
	case strings.HasPrefix(path, "json/"):
		return pool(parseID(path[5:])).json(true)
	case strings.HasPrefix(path, "me/"):
		return jsonMe(address(path[3:]))
	case path == "teams":
		return jsonTeams()
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

func (p *Pool) json(detail bool) string {
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
	b.WriteString(",\"bidders\":" + itoa(int64(len(p.Roster))))
	b.WriteString(",\"divPaid\":" + itoa(p.DivPaid))
	b.WriteString(",\"refPaid\":" + itoa(p.RefPaid))
	b.WriteString(",\"creatorPaid\":" + itoa(p.CreatorPaid))
	b.WriteString(",\"teamPaid\":" + itoa(p.TeamPaid))
	flag := p.WinnerFlag
	if m := p.find(p.LastBidder); m != nil && flag == "" {
		flag = m.Flag
	}
	b.WriteString(",\"flag\":\"" + flag + "\"")
	// what each flag has paid into this pool
	b.WriteString(",\"teams\":{")
	seen := map[string]int64{}
	order := []string{}
	for _, m := range p.Roster {
		if m.Flag == "" {
			continue
		}
		if _, ok := seen[m.Flag]; !ok {
			order = append(order, m.Flag)
		}
		seen[m.Flag] += m.Paid
	}
	for i, f := range order {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString("\"" + f + "\":" + itoa(seen[f]))
	}
	b.WriteString("}")
	if detail {
		b.WriteString(",\"history\":[")
		for i := len(p.History) - 1; i >= 0; i-- { // newest first
			h := p.History[i]
			if i < len(p.History)-1 {
				b.WriteString(",")
			}
			b.WriteString("{\"n\":" + itoa(h.N) + ",\"bidder\":\"" + h.Bidder.String() + "\",\"flag\":\"" + h.Flag + "\",\"price\":" + itoa(h.Price) + ",\"clock\":" + itoa(h.Clock) + ",\"pot\":" + itoa(h.Pot) + ",\"at\":" + unix(h.At) + "}")
		}
		b.WriteString("],\"roster\":[")
		for i, m := range p.Roster {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString("{\"addr\":\"" + m.Addr.String() + "\",\"flag\":\"" + m.Flag + "\",\"paid\":" + itoa(m.Paid) + ",\"earned\":" + itoa(m.Earned) + "}")
		}
		b.WriteString("]")
	}
	b.WriteString("}")
	return b.String()
}

func jsonAll() string {
	var b strings.Builder
	b.WriteString("{\"now\":" + itoa(time.Now().Unix()) + ",\"realm\":\"" + pkgPath + "\"")
	b.WriteString(",\"split\":{\"pot\":" + itoa(PotShare) + ",\"div\":" + itoa(DivShare) + ",\"ref\":" + itoa(RefShare) + ",\"creator\":" + itoa(CreatorShare) + ",\"team\":" + itoa(TeamShare) + ",\"roster\":" + itoa(int64(RosterMax)) + "}")
	b.WriteString(",\"pools\":[")
	for i, p := range pools {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(p.json(false))
	}
	b.WriteString("],\"teams\":" + jsonTeams() + "}")
	return b.String()
}

// jsonTeams is the country leaderboard: paid in, won, and players per flag.
func jsonTeams() string {
	var b strings.Builder
	b.WriteString("{")
	i := 0
	for f, paid := range teamPaid {
		if i > 0 {
			b.WriteString(",")
		}
		i++
		b.WriteString("\"" + f + "\":{\"paid\":" + itoa(paid) + ",\"won\":" + itoa(teamWon[f]) + ",\"players\":" + itoa(teamSize[f]) + "}")
	}
	b.WriteString("}")
	return b.String()
}

// jsonMe is what the page shows a connected wallet about itself.
func jsonMe(a address) string {
	pl := players[a]
	if pl == nil {
		pl = &Player{}
	}
	return "{\"addr\":\"" + a.String() + "\",\"referrer\":\"" + pl.Referrer.String() + "\",\"recruits\":" + itoa(pl.Recruits) +
		",\"flag\":\"" + pl.Flag + "\",\"bids\":" + itoa(pl.Bids) + ",\"paid\":" + itoa(pl.Paid) +
		",\"divEarned\":" + itoa(pl.DivEarned) + ",\"refEarned\":" + itoa(pl.RefEarned) + ",\"won\":" + itoa(pl.Won) + "}"
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
	b.WriteString("Every bid goes into a pool's pot and resets its clock; the Nth bid costs base·√N. ")
	b.WriteString("Of every bid, 55% is pot, 30% is paid at once to the pool's earlier bidders, 10% to whoever invited you, 5% to the pool's creator. ")
	b.WriteString("When the clock runs out the last bidder takes 80% and the players under the winner's flag share 20%. Play at [bubblerumble.net](https://bubblerumble.net).\n\n")
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
	b.WriteString("Opened by " + short(p.Creator) + " · " + dur(p.Window) + " window · base " + GNOT(p.BasePrice) + " · seed " + GNOT(p.Seed) + " · " + GNOT(p.DivPaid) + " paid to earlier bidders so far\n\n")
	if len(p.History) > 0 {
		b.WriteString("## Bids\n\n")
		for i := len(p.History) - 1; i >= 0; i-- {
			h := p.History[i]
			b.WriteString("- #" + itoa(h.N) + " " + short(h.Bidder) + " " + h.Flag + " paid " + GNOT(h.Price) + " → pot " + GNOT(h.Pot) + "\n")
		}
	}
	return b.String()
}
