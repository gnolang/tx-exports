// Package bubblerumble3 is the third Bubble Rumble realm. v2's money stays:
// of every bid 55% goes to the pot, 30% is paid at once to the pool's earlier
// bidders pro-rata to what they paid in, 10% to whoever invited the bidder,
// 5% to the pool's creator. What v3 adds:
//
//   - A last day. Every pool has a life (creator-set, 1h..30d) that starts at
//     its first bid. The pool closes when its clock runs out OR its life does,
//     whichever comes first. While the life runs out, the winner's share slides
//     toward nothing and that part of the pot is instead split among all the
//     pool's bidders pro-rata to what they paid in. A pool still contested on
//     its last day ends as a shared pot, so nobody is stuck in a loop and bots
//     gain nothing by outlasting people.
//   - Flag war. At the close, TeamShare of the pot goes to the OTHER bidders
//     who flew the winner's flag, pro-rata by paid-in; the winner never takes
//     it. A winner whose flag nobody else flew hands it to all the other
//     bidders instead, so a private flag buys nothing. A flag is locked per
//     pool at the first bid there. The winner's own part is what slides.
//   - Rebidding on yourself is allowed (it pays the others as any bid does).
//   - Earnings are credited, not pushed: dividends, team shares and the
//     close split accrue to each address and Withdraw sends them, so no bid or
//     close ever loops over a hundred transfers, and nothing can brick a pool.
//   - A bid's clock can be shortened by paying more, but never under MinClock,
//     so paying up is never a way to close a pool before anyone can answer.
//   - Shots. A bid may carry extra money as a shot at the bubble: a chance to
//     pop it at once. The chance is 0.8 × shot / prize, at most 1% a shot,
//     where the prize is the pot or ShotCap, whichever is smaller; a pot over
//     ShotCap pays a ShotCap slice instead of popping. The shot goes into the
//     pot, hit or miss, and every miss is counted on the bubble.
//
//     The draw is the chain's block time, which on tm2 is the median of the
//     validators' vote timestamps for the block before: public one block
//     ahead, and nudgeable by a validator who is the median vote. Two things
//     follow. A shot is drawn only in the blocks ShotDelay to ShotDelay+
//     ShotWindow after it was paid for, by whoever touches the pool then, and
//     is void after that: a shooter cannot wait for a block whose time suits
//     them, and the two blocks of leeway are worth less than the bid a shot
//     must ride on. And the prize is capped at ShotCap, small enough that a
//     validator grinding a timestamp is stealing lunch money, with SetShots as
//     the switch if one does. Raise the cap when gno.land has real randomness.
package bubblerumble3

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/binary"
	"math"
	"math/bits"
	"strconv"
	"strings"
	"time"
)

const (
	MinWindow    int64 = 10                // seconds
	MaxWindow    int64 = 30 * 24 * 3600    // 30 days
	MinLife      int64 = 3600              // an hour
	MaxLife      int64 = 30 * 24 * 3600    // 30 days
	MinBasePrice int64 = 1_000             // ugnot, 0.001 GNOT
	MaxBasePrice int64 = 1_000_000_000_000 // ugnot, 1,000,000 GNOT
	MaxNameLen         = 40
	HistoryLen         = 50  // bids kept per pool for the feed
	RosterMax          = 100 // distinct bidders a pool pays dividends, team shares and the close split to
	MaxBoost     int64 = 10  // the shortest clock a bid can buy is window/MaxBoost...
	MinClock     int64 = 300 // ...and never under five minutes: people must be able to answer

	// where every bid goes, in percent
	PotShare     int64 = 55
	DivShare     int64 = 30 // to earlier bidders of the pool, pro-rata by weight
	RefShare     int64 = 10 // to the bidder's inviter
	CreatorShare int64 = 5
	// of the pot at the close, to the other bidders under the winner's flag
	TeamShare int64 = 35

	ShotCap    int64 = 10_000_000 // ugnot: the most a shot can take, 10 GNOT
	ShotMaxBps int64 = 100        // 1% a shot, whatever is paid
	ShotFair   int64 = 8000       // chance in bps = ShotFair × shot / prize (0.8 of fair odds)
	ShotDelay  int64 = 3          // blocks after the shot was paid for before it can be drawn...
	ShotWindow int64 = 2          // ...and how many more blocks it may still be drawn in
)

// admin is the realm's deployer: the only address that may turn shots off.
const admin = address("g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr")

// pkgPath must match gnomod.toml: the realm's own address derives from it.
const pkgPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble3"

type Entry struct {
	N      int64
	Bidder address
	Flag   string
	Price  int64 // what was paid for the bid itself; at least the price at the time
	Shot   int64 // extra paid for a chance to pop the bubble
	Clock  int64 // seconds this bid had to stand
	Pot    int64 // pot right after this bid
	At     time.Time
}

// Member is a distinct bidder of a pool: dividends, team shares and the close
// split go to the roster. The flag is the one flown at the first bid here.
type Member struct {
	Addr   address
	Flag   string
	Paid   int64 // gross paid into this pool (bids and shots)
	Earned int64 // dividends received from this pool
}

// Shot is a shot at the bubble waiting to be drawn, or drawn.
type Shot struct {
	N        int64 // 1-based within the pool
	Bidder   address
	Paid     int64 // ugnot paid for it
	Prize    int64 // what it plays for: the pot then, or ShotCap
	Bps      int64 // chance, in basis points
	CommitH  int64 // block height when paid
	Resolved bool
	Won      bool
	DrawH    int64
}

type Pool struct {
	ID          int64
	Name        string
	Creator     address
	Window      int64 // seconds the last bid must stand to win
	Life        int64 // seconds from the first bid to the last day
	BasePrice   int64 // ugnot; the Nth bid costs BasePrice·√N
	Seed        int64
	Pot         int64
	Bids        int64
	LastBidder  address
	LastBidAt   time.Time
	FirstBidAt  time.Time
	Clock       int64 // seconds the current top bid has to stand
	CreatedAt   time.Time
	Paid        bool // the pot went out, or the seed back to the creator
	Cancelled   bool
	Popped      bool // a shot ended it
	PoppedAt    time.Time
	DivPaid     int64 // dividends paid out of this pool so far
	RefPaid     int64
	CreatorPaid int64
	ShotPaid    int64 // slices paid to hits while the pool went on
	Misses      int64 // shots drawn and lost: the scars on the bubble
	WinnerFlag  string
	TeamPaid    int64 // what the winner's team received at the close
	SharedPaid  int64 // the pro-rata part of the close
	WinnerPaid  int64
	History     []Entry
	Roster      []*Member
	Shots       []*Shot
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
	Won       int64 // pots, team shares, close splits and shot slices received
	Shots     int64
	Hits      int64
	Owed      int64 // credited and not yet withdrawn
	Withdrawn int64
}

var (
	shotsOn   = true
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

// LastDay is when the pool's life runs out; zero before the first bid.
func (p *Pool) LastDay() time.Time {
	if p.FirstBidAt.IsZero() {
		return time.Time{}
	}
	return p.FirstBidAt.Add(time.Duration(p.Life) * time.Second)
}

// Deadline is when the pool closes if nothing changes: the clock or the last
// day, whichever comes first; the pop, if a shot ended it.
func (p *Pool) Deadline() time.Time {
	if p.Popped {
		return p.PoppedAt
	}
	d := p.LastBidAt.Add(time.Duration(p.Clock) * time.Second)
	if last := p.LastDay(); !last.IsZero() && last.Before(d) {
		return last
	}
	return d
}

func (p *Pool) Over() bool       { return p.Bids > 0 && (p.Popped || !time.Now().Before(p.Deadline())) }
func (p *Pool) NextPrice() int64 { return Price(p.BasePrice, p.Bids) }

// LiveBps is how much of the pot still goes the winner's way, in basis points
// of the pot: 10000 at the first bid, sliding to 0 on the last day. Frozen at
// the close.
func (p *Pool) LiveBps() int64 {
	if p.FirstBidAt.IsZero() || p.Life <= 0 {
		return 10000
	}
	at := time.Now()
	if p.Over() {
		at = p.Deadline()
	}
	elapsed := at.Unix() - p.FirstBidAt.Unix()
	if elapsed <= 0 {
		return 10000
	}
	if elapsed >= p.Life {
		return 0
	}
	return 10000 * (p.Life - elapsed) / p.Life
}

// ClockFor is the clock a bid buys by paying sent against a price: the window
// divided by the multiple paid, never below window/MaxBoost.
func ClockFor(window, price, sent int64) int64 {
	c := int64(float64(window) * float64(price) / float64(sent))
	if c < window/MaxBoost {
		c = window / MaxBoost
	}
	if c < MinClock {
		c = MinClock
	}
	if c > window {
		c = window
	}
	return c
}

// mulDiv is a×b/c without overflowing on the way: pots and paid-ins are both
// in ugnot and their product passes int64 at a few thousand GNOT each.
func mulDiv(a, b, c int64) int64 {
	if a < 0 || b < 0 || c <= 0 {
		panic("mulDiv: negative")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(c) {
		panic("mulDiv: overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(c))
	return int64(q)
}

// ShotBps is the chance a shot buys against a prize, in basis points.
func ShotBps(shot, prize int64) int64 {
	if shot <= 0 || prize <= 0 {
		return 0
	}
	bps := ShotFair * shot / prize
	if bps > ShotMaxBps {
		bps = ShotMaxBps
	}
	return bps
}

// CreatePool opens a pool. Any ugnot sent with the call seeds its pot. The
// creator earns CreatorShare of every bid. life is the pool's life in seconds
// from its first bid; 0 means ten windows (at least an hour, at most 30 days).
func CreatePool(cur realm, name string, window int64, basePrice int64, life int64) int64 {
	creator := userCaller(cur)
	name = cleanName(name)
	if window < MinWindow || window > MaxWindow {
		panic("window must be between 10s and 30d")
	}
	if basePrice < MinBasePrice || basePrice > MaxBasePrice {
		panic("base price must be between 0.001 and 1,000,000 GNOT")
	}
	if life == 0 { // ten windows of fighting, within the bounds
		life = 10 * window
		if life < MinLife {
			life = MinLife
		}
		if life > MaxLife {
			life = MaxLife
		}
	}
	if life < MinLife || life > MaxLife {
		panic("life must be between 1h and 30d")
	}
	if life < window {
		panic("life must be at least the window")
	}
	seed := ugnotSent()
	p := newPool(name, creator, window, basePrice, life, seed)
	chain.Emit("PoolCreated", "id", itoa(p.ID), "creator", creator.String(), "seed", itoa(seed))
	return p.ID
}

func newPool(name string, creator address, window, basePrice, life, seed int64) *Pool {
	p := &Pool{
		ID: int64(len(pools)) + 1, Name: name, Creator: creator, Window: window, Life: life,
		BasePrice: basePrice, Seed: seed, Pot: seed, CreatedAt: time.Now(),
	}
	pools = append(pools, p)
	return p
}

// Bid pays at least the current price and resets the clock. ref is the address
// that invited the bidder ("" for none; only the first bid ever sets it), flag
// a two-letter country to play under ("" keeps the last one; the flag is locked
// per pool at the first bid there), shot how much of the money sent is a shot
// at popping the bubble (0 for none): the rest must cover the price, and paying
// more than the price shortens the clock.
func Bid(cur realm, id int64, ref string, flag string, shot int64) {
	bidder := userCaller(cur)
	p := pool(id)
	sent := ugnotSent()
	if p.Cancelled {
		panic("pool was cancelled")
	}
	// shots paid for earlier are drawn first; if one of them pops the bubble,
	// this bid has nothing to bid on and its money goes back
	p.drawShots(cur)
	if p.Over() {
		if sent > 0 {
			send(cur, bidder, sent)
			chain.Emit("Refund", "id", itoa(id), "to", bidder.String(), "ugnot", itoa(sent))
		}
		if p.Popped {
			return
		}
		panic("pool is closed")
	}
	if shot < 0 || shot > sent {
		panic("shot must be between 0 and the amount sent")
	}
	if shot > 0 && !shotsOn {
		panic("shots are off")
	}
	price := p.NextPrice()
	bid := sent - shot
	if bid < price {
		panic("send at least " + itoa(price) + "ugnot for the bid, got " + itoa(bid) + "ugnot")
	}
	if shot > 0 {
		// checked against the most the pot can be after this bid, so a shot that
		// passes here has a chance against the real pot too; nothing has changed yet
		most := p.Pot + bid + shot
		if most > ShotCap {
			most = ShotCap
		}
		if ShotBps(shot, most) == 0 {
			panic("that shot is too small for any chance at " + GNOT(most) + ": send at least " + itoa(most/ShotFair+1) + "ugnot as the shot")
		}
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

	// where the bid goes
	div, refCut, creatorCut := bid*DivShare/100, bid*RefShare/100, bid*CreatorShare/100
	toPot := bid - div - refCut - creatorCut
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
	divPaid := div - p.payDividends(cur, bidder, div)
	toPot += div - divPaid
	// the shot goes into the pot whole, hit or miss: it is what it plays for
	p.Pot += toPot + shot

	m := p.member(bidder, pl.Flag)
	if m.Flag == "" { // a flagless first bid does not lock "no flag": the first flag flown here does
		m.Flag = pl.Flag
	}
	m.Paid += sent
	pl.Bids++
	pl.Paid += sent
	if pl.Flag != "" {
		teamPaid[pl.Flag] += sent
	}
	p.Bids++
	if p.FirstBidAt.IsZero() {
		p.FirstBidAt = time.Now()
	}
	p.LastBidder = bidder
	p.LastBidAt = time.Now()
	p.Clock = ClockFor(p.Window, price, bid)
	p.History = append(p.History, Entry{N: p.Bids, Bidder: bidder, Flag: m.Flag, Price: bid, Shot: shot, Clock: p.Clock, Pot: p.Pot, At: p.LastBidAt})
	if len(p.History) > HistoryLen {
		p.History = p.History[len(p.History)-HistoryLen:]
	}
	chain.Emit("Bid", "id", itoa(id), "n", itoa(p.Bids), "bidder", bidder.String(), "paid", itoa(bid), "shot", itoa(shot), "pot", itoa(p.Pot), "div", itoa(divPaid))

	if shot > 0 {
		prize := p.Pot
		if prize > ShotCap {
			prize = ShotCap
		}
		bps := ShotBps(shot, prize)
		t := &Shot{N: int64(len(p.Shots)) + 1, Bidder: bidder, Paid: shot, Prize: prize, Bps: bps, CommitH: runtime.ChainHeight()}
		p.Shots = append(p.Shots, t)
		pl.Shots++
		chain.Emit("Shot", "id", itoa(id), "shot", itoa(t.N), "bidder", bidder.String(), "paid", itoa(shot), "prize", itoa(prize), "bps", itoa(bps), "drawAt", itoa(t.CommitH+ShotDelay))
	}
}

// SetShots turns shots off (or on again); only the deployer may.
func SetShots(cur realm, on bool) {
	if userCaller(cur) != admin {
		panic("only the deployer")
	}
	shotsOn = on
	chain.Emit("Shots", "on", jbool(on))
}

// Draw draws the shots at a pool that are due. Anyone may call it; every bid
// and claim on the pool does the same first.
func Draw(cur realm, id int64) {
	pool(id).drawShots(cur)
}

// drawShots resolves every shot that is due, oldest first. A shot is drawn in
// the blocks ShotDelay to ShotDelay+ShotWindow after it was paid for, from the
// block's time and height, the shot and its shooter, and the address that sent
// the drawing transaction; a shot those blocks passed by undrawn is void, its
// money stays in the pot, and it counts as a miss. A hit takes ShotCap from a
// pot larger than that and the pool goes on; a pot at or under ShotCap pops:
// the pool closes now with the shooter as its winner, settled at Claim.
func (p *Pool) drawShots(cur realm) {
	h := runtime.ChainHeight()
	for _, t := range p.Shots {
		if t.Resolved || t.CommitH+ShotDelay > h {
			continue
		}
		t.Resolved, t.DrawH = true, h
		if t.CommitH+ShotDelay+ShotWindow < h || p.Over() {
			// too late, or the pool closed first: void
			p.Misses++
			chain.Emit("Drawn", "id", itoa(p.ID), "shot", itoa(t.N), "bidder", t.Bidder.String(), "hit", "false", "void", "true")
			continue
		}
		t.Won = shotHits(seedFor(p.ID, t, h), t.Bps)
		chain.Emit("Drawn", "id", itoa(p.ID), "shot", itoa(t.N), "bidder", t.Bidder.String(), "hit", jbool(t.Won), "bps", itoa(t.Bps))
		if !t.Won {
			p.Misses++
			continue
		}
		player(t.Bidder).Hits++
		if p.Pot > ShotCap {
			credit(t.Bidder, ShotCap)
			p.Pot -= ShotCap
			p.ShotPaid += ShotCap
			player(t.Bidder).Won += ShotCap
			chain.Emit("Slice", "id", itoa(p.ID), "to", t.Bidder.String(), "ugnot", itoa(ShotCap))
			continue
		}
		p.Popped, p.PoppedAt, p.LastBidder = true, time.Now(), t.Bidder
		chain.Emit("Popped", "id", itoa(p.ID), "by", t.Bidder.String(), "pot", itoa(p.Pot))
	}
}

func seedFor(poolID int64, t *Shot, h int64) uint64 {
	var b []byte
	b = append(b, pkgPath...)
	b = binary.BigEndian.AppendUint64(b, uint64(poolID))
	b = binary.BigEndian.AppendUint64(b, uint64(t.N))
	b = append(b, t.Bidder.String()...)
	b = binary.BigEndian.AppendUint64(b, uint64(t.CommitH))
	b = binary.BigEndian.AppendUint64(b, uint64(h))
	b = binary.BigEndian.AppendUint64(b, uint64(time.Now().UnixNano()))
	b = append(b, unsafe.OriginCaller().String()...)
	sum := sha256.Sum256(b)
	return binary.BigEndian.Uint64(sum[:8])
}

// shotHits is the draw: a uniform number in [0, 10000) under the chance.
func shotHits(seed uint64, bps int64) bool {
	return int64(seed%10000) < bps
}

// payDividends credits div to the pool's earlier bidders, pro-rata to what
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
		amt := mulDiv(div, m.Paid, total)
		if amt > 0 {
			credit(m.Addr, amt)
			m.Earned += amt
			player(m.Addr).DivEarned += amt
			paid += amt
		}
	}
	p.DivPaid += paid
	return div - paid
}

// member finds or adds a bidder on the roster; a full roster drops its oldest.
// A new member's flag is the one given; once set it is locked for this pool.
func (p *Pool) member(a address, flag string) *Member {
	for _, m := range p.Roster {
		if m.Addr == a {
			return m
		}
	}
	if len(p.Roster) >= RosterMax {
		p.Roster = p.Roster[1:]
	}
	m := &Member{Addr: a, Flag: flag}
	p.Roster = append(p.Roster, m)
	return m
}

// Claim settles a finished pool: everything is credited, and Withdraw sends
// it. TeamShare of the pot goes to the OTHER roster members flying the
// winner's flag, pro-rata by paid-in — or, when nobody else flew it, to all
// the other roster members. Of the rest, the live part (LiveBps) is the
// winner's and the shared part is split among the whole roster pro-rata by
// paid-in. A pool with a single bidder credits them everything. Rounding goes
// to the winner. Anyone may call it.
func Claim(cur realm, id int64) {
	p := pool(id)
	if p.Cancelled {
		panic("pool was cancelled")
	}
	p.drawShots(cur)
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
	pot := p.Pot

	// the team: the others under the winner's flag, else all the others
	var team int64
	for _, m := range p.Roster {
		if m.Addr != winner && m.Flag == flag && flag != "" {
			team += m.Paid
		}
	}
	teamFlag := flag
	if team == 0 {
		teamFlag = "" // nobody else flew it: every other bidder is the team
		for _, m := range p.Roster {
			if m.Addr != winner {
				team += m.Paid
			}
		}
	}
	toWinner := pot
	if team > 0 {
		cut := pot * TeamShare / 100
		for _, m := range p.Roster {
			if m.Addr == winner || (teamFlag != "" && m.Flag != teamFlag) {
				continue
			}
			amt := mulDiv(cut, m.Paid, team)
			if amt > 0 {
				credit(m.Addr, amt)
				player(m.Addr).Won += amt
				toWinner -= amt
				p.TeamPaid += amt
			}
		}
		// the rest slides: the live part stays the winner's, the shared part is everyone's by paid-in
		rest := pot - cut
		shared := rest - mulDiv(rest, p.LiveBps(), 10000)
		if shared > 0 {
			var total int64
			for _, m := range p.Roster {
				total += m.Paid
			}
			for _, m := range p.Roster {
				amt := mulDiv(shared, m.Paid, total)
				if amt > 0 && m.Addr != winner {
					credit(m.Addr, amt)
					player(m.Addr).Won += amt
					toWinner -= amt
					p.SharedPaid += amt
				}
			}
		}
	}
	if toWinner > 0 {
		credit(winner, toWinner)
		player(winner).Won += toWinner
	}
	p.WinnerPaid = toWinner
	if flag != "" {
		teamWon[flag] += p.Pot
	}
	chain.Emit("Paid", "id", itoa(id), "winner", winner.String(), "pot", itoa(p.Pot), "winnerPaid", itoa(toWinner), "team", itoa(p.TeamPaid), "shared", itoa(p.SharedPaid), "liveBps", itoa(p.LiveBps()))
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

// credit books ugnot to an address; Withdraw pays it out.
func credit(to address, ugnot int64) {
	player(to).Owed += ugnot
}

// Withdraw sends the caller everything credited to them: dividends, team
// shares, close splits, slices and won pots.
func Withdraw(cur realm) int64 {
	who := userCaller(cur)
	pl := player(who)
	amt := pl.Owed
	if amt <= 0 {
		panic("nothing to withdraw")
	}
	pl.Owed = 0
	pl.Withdrawn += amt
	send(cur, who, amt)
	chain.Emit("Withdrawn", "to", who.String(), "ugnot", itoa(amt))
	return amt
}

// Owed is what an address could withdraw right now.
func Owed(a address) int64 { return player(a).Owed }

func pool(id int64) *Pool {
	if id < 1 || id > int64(len(pools)) {
		panic("no such pool")
	}
	return pools[id-1]
}

// userCaller is the signer of the transaction, refusing calls relayed through
// another realm so nobody can bid on someone else's behalf, and so no realm can
// pay for a shot and revert on a miss.
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
	b.WriteString(",\"life\":" + itoa(p.Life))
	b.WriteString(",\"basePrice\":" + itoa(p.BasePrice))
	b.WriteString(",\"seed\":" + itoa(p.Seed))
	b.WriteString(",\"pot\":" + itoa(p.Pot))
	b.WriteString(",\"bids\":" + itoa(p.Bids))
	b.WriteString(",\"nextPrice\":" + itoa(p.NextPrice()))
	b.WriteString(",\"lastBidder\":\"" + p.LastBidder.String() + "\"")
	b.WriteString(",\"lastBidAt\":" + unix(p.LastBidAt))
	b.WriteString(",\"firstBidAt\":" + unix(p.FirstBidAt))
	b.WriteString(",\"deadline\":" + unix(p.Deadline()))
	b.WriteString(",\"lastDay\":" + unix(p.LastDay()))
	b.WriteString(",\"liveBps\":" + itoa(p.LiveBps()))
	b.WriteString(",\"clock\":" + itoa(p.Clock))
	b.WriteString(",\"createdAt\":" + unix(p.CreatedAt))
	b.WriteString(",\"over\":" + jbool(p.Over()))
	b.WriteString(",\"popped\":" + jbool(p.Popped))
	b.WriteString(",\"paid\":" + jbool(p.Paid))
	b.WriteString(",\"cancelled\":" + jbool(p.Cancelled))
	b.WriteString(",\"bidders\":" + itoa(int64(len(p.Roster))))
	b.WriteString(",\"divPaid\":" + itoa(p.DivPaid))
	b.WriteString(",\"refPaid\":" + itoa(p.RefPaid))
	b.WriteString(",\"creatorPaid\":" + itoa(p.CreatorPaid))
	b.WriteString(",\"shotPaid\":" + itoa(p.ShotPaid))
	b.WriteString(",\"teamPaid\":" + itoa(p.TeamPaid))
	b.WriteString(",\"sharedPaid\":" + itoa(p.SharedPaid))
	b.WriteString(",\"winnerPaid\":" + itoa(p.WinnerPaid))
	pending := int64(0)
	for _, t := range p.Shots {
		if !t.Resolved {
			pending++
		}
	}
	b.WriteString(",\"shots\":" + itoa(int64(len(p.Shots))) + ",\"misses\":" + itoa(p.Misses) + ",\"pending\":" + itoa(pending))
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
			b.WriteString("{\"n\":" + itoa(h.N) + ",\"bidder\":\"" + h.Bidder.String() + "\",\"flag\":\"" + h.Flag + "\",\"price\":" + itoa(h.Price) + ",\"shot\":" + itoa(h.Shot) + ",\"clock\":" + itoa(h.Clock) + ",\"pot\":" + itoa(h.Pot) + ",\"at\":" + unix(h.At) + "}")
		}
		b.WriteString("],\"roster\":[")
		for i, m := range p.Roster {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString("{\"addr\":\"" + m.Addr.String() + "\",\"flag\":\"" + m.Flag + "\",\"paid\":" + itoa(m.Paid) + ",\"earned\":" + itoa(m.Earned) + "}")
		}
		b.WriteString("],\"shotlog\":[")
		for i := len(p.Shots) - 1; i >= 0; i-- { // newest first
			t := p.Shots[i]
			if i < len(p.Shots)-1 {
				b.WriteString(",")
			}
			b.WriteString("{\"n\":" + itoa(t.N) + ",\"bidder\":\"" + t.Bidder.String() + "\",\"paid\":" + itoa(t.Paid) + ",\"prize\":" + itoa(t.Prize) + ",\"bps\":" + itoa(t.Bps) + ",\"drawAt\":" + itoa(t.CommitH+ShotDelay) + ",\"resolved\":" + jbool(t.Resolved) + ",\"hit\":" + jbool(t.Won) + "}")
		}
		b.WriteString("]")
	}
	b.WriteString("}")
	return b.String()
}

func jsonAll() string {
	var b strings.Builder
	b.WriteString("{\"now\":" + itoa(time.Now().Unix()) + ",\"height\":" + itoa(runtime.ChainHeight()) + ",\"realm\":\"" + pkgPath + "\"")
	b.WriteString(",\"split\":{\"pot\":" + itoa(PotShare) + ",\"div\":" + itoa(DivShare) + ",\"ref\":" + itoa(RefShare) + ",\"creator\":" + itoa(CreatorShare) + ",\"team\":" + itoa(TeamShare) + ",\"roster\":" + itoa(int64(RosterMax)) +
		",\"shotCap\":" + itoa(ShotCap) + ",\"shotMaxBps\":" + itoa(ShotMaxBps) + ",\"shotFair\":" + itoa(ShotFair) + ",\"shotDelay\":" + itoa(ShotDelay) + ",\"shotWindow\":" + itoa(ShotWindow) + ",\"minClock\":" + itoa(MinClock) + "}")
	b.WriteString(",\"shotsOn\":" + jbool(shotsOn))
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
		",\"divEarned\":" + itoa(pl.DivEarned) + ",\"refEarned\":" + itoa(pl.RefEarned) + ",\"won\":" + itoa(pl.Won) +
		",\"shots\":" + itoa(pl.Shots) + ",\"hits\":" + itoa(pl.Hits) + ",\"owed\":" + itoa(pl.Owed) + ",\"withdrawn\":" + itoa(pl.Withdrawn) + "}"
}

func (p *Pool) status() string {
	switch {
	case p.Cancelled:
		return "cancelled"
	case p.Over():
		s := "won by " + short(p.LastBidder)
		if p.Popped {
			s = "popped by " + short(p.LastBidder)
		}
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
			s += " (⚡ " + dur(p.Clock) + " clock)"
		}
		return s + " · " + short(p.LastBidder) + " on top · next " + GNOT(p.NextPrice()) + " · winner's share " + itoa(p.LiveBps()/100) + "%"
	}
}

func markdownAll() string {
	var b strings.Builder
	b.WriteString("# Bubble Rumble v3\n\n")
	b.WriteString("Last bid standing takes the pot. Of every bid, 55% goes into the pot, 30% is paid at once to the pool's earlier bidders, 10% to whoever invited the bidder and 5% to the pool's creator. ")
	b.WriteString("Earnings are credited and withdrawn with Withdraw. At the close " + itoa(TeamShare) + "% of the pot goes to the other bidders who flew the winner's flag. Every pool has a last day: as it nears, the winner's own share slides toward a split of the pot among all its bidders. A bid may carry a shot at the bubble: a chance of at most " + itoa(ShotMaxBps/100) + "% to pop it, or to take a " + GNOT(ShotCap) + " slice of a bigger one; every miss is counted on the bubble.\n\n")
	b.WriteString("Play at [bubblerumble.net](https://bubblerumble.net).\n\n## Pools\n\n")
	if len(pools) == 0 {
		b.WriteString("_none yet_\n")
	}
	for _, p := range pools {
		b.WriteString("- [#" + itoa(p.ID) + " " + p.Name + "](/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble3:" + itoa(p.ID) + ") · " + GNOT(p.Pot) + " · " + p.status() + "\n")
	}
	return b.String()
}

func (p *Pool) markdown() string {
	var b strings.Builder
	b.WriteString("# " + p.Name + "\n\n")
	b.WriteString("- pot: **" + GNOT(p.Pot) + "**\n- status: " + p.status() + "\n- window: " + dur(p.Window) + " · life: " + dur(p.Life) + "\n- base price: " + GNOT(p.BasePrice) + " · next bid: " + GNOT(p.NextPrice()) + "\n- bids: " + itoa(p.Bids) + " · creator: " + short(p.Creator) + "\n")
	if !p.LastDay().IsZero() {
		b.WriteString("- last day: " + p.LastDay().UTC().Format("2006-01-02 15:04 UTC") + " · winner's share now " + itoa(p.LiveBps()/100) + "%\n")
	}
	if len(p.Shots) > 0 {
		b.WriteString("- shots: " + itoa(int64(len(p.Shots))) + " · misses: " + itoa(p.Misses) + "\n")
	}
	b.WriteString("\n## Bids\n\n")
	if len(p.History) == 0 {
		b.WriteString("_none yet_\n")
	}
	for i := len(p.History) - 1; i >= 0; i-- {
		h := p.History[i]
		line := "- #" + itoa(h.N) + " " + short(h.Bidder)
		if h.Flag != "" {
			line += " (" + h.Flag + ")"
		}
		line += " paid " + GNOT(h.Price)
		if h.Shot > 0 {
			line += " + a " + GNOT(h.Shot) + " shot"
		}
		b.WriteString(line + " · pot " + GNOT(h.Pot) + "\n")
	}
	return b.String()
}
