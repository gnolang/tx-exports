// Package bubblerumble4 is the fourth Bubble Rumble realm. v3's game stays whole:
// of every bid 55% goes to the pot, 30% is credited at once to the pool's earlier
// bidders pro-rata to what they paid in, 10% to whoever invited the bidder, 5% to
// the pool's creator; every pool has a last day, a flag war at the close, credited
// earnings and Withdraw, a clock that can be bought down but never under MinClock.
// What v4 changes is the shot: it can now win the pot.
//
//   - A shot is still extra money on a bid, a chance to pop the bubble at once.
//     The chance is 0.8 × shot / take, at most 1% a shot, where the take is what
//     a pop would pay the shooter right now: the pot less the team's 35%, times the
//     winner's live share (LiveBps). So the pot keeps a fifth of every shot's fair
//     value however far the last day has slid, and a hit pops the bubble: the pool
//     closes with the shooter as its winner and Claim pays it as any pop.
//   - The draw's randomness is a commit-reveal by the keeper — the operator's own
//     box, which also settles pools on time. The keeper publishes sha256 hashes of
//     secrets ahead of time (Commit); a bid with a shot takes the next unused one;
//     the shot is drawn when someone (the keeper, or anyone) reveals that secret
//     (Reveal) in the blocks ShotDelay to ShotDelay+ShotWindow after the bid. The
//     seed is the secret with the shot's own facts and the reveal block's height
//     and time. Nobody without the secret can grind it: not the shooter, not a
//     validator. The secret's holder knows the two candidate block times a block
//     ahead and may pick which of the window's three blocks to reveal in — three
//     rolls, at most 2.4× fair on a 1% shot — which is why the keeper key and its
//     operator never bid or shoot.
//   - A shot not revealed in its window, or on a pool that closed first, is void:
//     it goes into the pot and counts as a miss, as in v3. Nothing is refunded, so
//     withholding a reveal never pays whoever withholds it. What remains is that a
//     keeper who leads a pot could withhold a stranger's hit and let the money fall
//     into the pot it leads: refused shots are counted on the pool for all to see,
//     and so are reveals that came in the window's later blocks (the honest keeper
//     always reveals at the first), so a keeper choosing its block would show.
//   - Shots are sold only while the keeper is alive: a shot needs a free commitment
//     and a sign of life (Commit or Heartbeat) within KeeperFresh. Otherwise the bid
//     stands and the shot's money goes straight back in the same transaction.
//   - Shots are refused in the last quarter of a pool's life (which also keeps every
//     reveal window clear of the last day) and under MinShot. RevealTip is taken
//     from every shot and credited to the keeper whoever sends the reveal (the
//     secret sits in the mempool, and a proposer could copy it), so the keeper
//     pays for itself. The keeper's own shots are refused outright.
//   - Reveals go in shot order, so among two pending shots nobody chooses which pops.
//
// Residuals, stated plainly: the secret holder's three rolls; the keeper-defender
// veto above; a proposer who reads the keeper's reveal in the mempool holds the
// secret too, and proposing the window's blocks could drop the reveal for a roll
// it does not like or leave it out altogether (a void), which Late and Voided
// show; keeper and validator together could grind. SetShots is the switch if any
// of it is seen. SetKeeper drops every unused commitment.
package bubblerumble4

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
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

	ShotMaxBps    int64 = 100     // 1% a shot, whatever is paid
	ShotFair      int64 = 8000    // chance in bps = ShotFair × shot / take (0.8 of fair odds)
	ShotDelay     int64 = 3       // blocks after the shot was paid for before it can be revealed...
	ShotWindow    int64 = 2       // ...and how many more blocks it may still be revealed in: three blocks, as v3 drew; three rolls at most for the secret's holder
	MinShot       int64 = 100_000 // ugnot: no shot under 0.1 GNOT, so dust cannot make reveals cost more than they tip
	RevealTip     int64 = 20_000  // ugnot: off every shot, to whoever reveals it
	KeeperFresh   int64 = 300     // seconds: shots are sold only this soon after the keeper's last sign of life (it heartbeats every two minutes)
	LiveFloor     int64 = 2500    // bps: no shots once the winner's live share has slid under a quarter (which also keeps every reveal window clear of the last day)
	MaxCommits          = 500     // unused commitments the queue holds at most
	CommitBatch         = 100     // hashes one Commit may bring
	CommitCompact       = 200     // used commitments kept before the queue is compacted
)

// admin is the realm's deployer: the only address that may turn shots off.
const admin = address("g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr")

// pkgPath must match gnomod.toml: the realm's own address derives from it.
const pkgPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble4"

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

// Shot is a shot at the bubble waiting to be revealed, or resolved.
type Shot struct {
	N        int64 // 1-based within the pool
	Bidder   address
	Paid     int64    // ugnot paid for it (the tip comes out of this at the reveal)
	Take     int64    // what a pop would have paid the shooter when the odds were set
	Bps      int64    // chance, in basis points
	CommitH  int64    // block height when paid; revealable at CommitH+ShotDelay and the ShotWindow blocks after
	Hash     string   // the commitment it took: sha256 of the secret that decides it, 32 raw bytes
	Resolved bool
	Won      bool
	Void     bool // not revealed in its window, or the pool closed first: a miss
	DrawH    int64
	Revealer address
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
	Misses      int64 // shots resolved and lost, voids included: the scars on the bubble
	Voided      int64 // of those, the shots nobody revealed in time
	Late        int64 // shots revealed in their window but not at its first block: a keeper choosing its block would show here
	ShotEscrow  int64 // shots paid for and not yet resolved: in the pot once they are
	WinnerFlag  string
	TeamPaid    int64 // what the winner's team received at the close
	SharedPaid  int64 // the pro-rata part of the close
	WinnerPaid  int64
	History     []Entry
	Roster      []*Member
	Shots       []*Shot
	Settled     int // shots before this index are all resolved (they resolve strictly in order): where settleShots starts
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
	shotsOn    = true
	keeper     address    // who commits and heartbeats (SetKeeper); the admin may too
	keeperSeen time.Time  // the keeper's last Commit or Heartbeat
	commits    []string   // the hashes of the keeper's secrets (32 raw bytes each), in order; the first head are used
	head       int
	voided     int64 // shots voided over all pools
	late       int64 // shots revealed after the first block of their window, over all pools
	pools      []*Pool
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

// ShotBps is the chance a shot buys against what a pop would pay, in basis points.
func ShotBps(shot, take int64) int64 {
	if shot <= 0 || take <= 0 {
		return 0
	}
	bps := ShotFair * shot / take
	if bps > ShotMaxBps {
		bps = ShotMaxBps
	}
	return bps
}

// Take is the most a pop could pay this shooter if the pool closed now on a pot
// of this size: Claim's own arithmetic, run dry, with the team's share counted
// as the shooter's too — one bid from a friend (or a second address) under a
// flag nobody else flies collects it, so the odds must assume it is collected.
// What is not the shooter's is the slide: the part of the rest that the last
// day has moved to the whole roster by paid-in.
func (p *Pool) Take(shooter address, pot int64) int64 {
	toWinner, cut := p.payout(shooter, pot, false)
	return toWinner + cut
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
	// a pool that closed (or popped) since the bidder looked: the money goes back
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
	price := p.NextPrice()
	bid := sent - shot
	if bid < price {
		panic("send at least " + itoa(price) + "ugnot for the bid, got " + itoa(bid) + "ugnot")
	}
	// shots of earlier bids whose window has passed are settled first
	p.settleShots()
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
	p.Pot += toPot

	m := p.member(bidder, pl.Flag)
	if m.Flag == "" { // a flagless first bid does not lock "no flag": the first flag flown here does
		m.Flag = pl.Flag
	}
	// the shot, if there can be one: else its money goes straight back and the bid stands
	why := ""
	if shot > 0 {
		why = p.shotRefusal(bidder, shot)
	}
	m.Paid += sent
	pl.Bids++
	pl.Paid += sent
	if pl.Flag != "" {
		teamPaid[pl.Flag] += sent
	}
	// the odds, on the pool as it stands with this bid booked (the shooter's own paid-in weighs in the slide):
	// priced here once, and a shot that buys no chance at all is refused like the rest
	var take, bps int64
	if shot > 0 && why == "" {
		take = p.Take(bidder, p.Pot+shot-RevealTip) // the pot a pop would pay from: this bid's share in, the shot itself in, the tip out
		bps = ShotBps(shot-RevealTip, take)
		if bps == 0 {
			why = "too small for any chance at this pot"
		}
	}
	if why != "" {
		m.Paid -= shot
		pl.Paid -= shot
		if pl.Flag != "" {
			teamPaid[pl.Flag] -= shot
		}
		send(cur, bidder, shot)
		chain.Emit("ShotReturned", "id", itoa(id), "bidder", bidder.String(), "ugnot", itoa(shot), "why", why)
		sent -= shot
		shot = 0
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
		t := &Shot{N: int64(len(p.Shots)) + 1, Bidder: bidder, Paid: shot, Take: take, Bps: bps, CommitH: runtime.ChainHeight(), Hash: commits[head]}
		head++
		p.Shots = append(p.Shots, t)
		p.ShotEscrow += shot
		pl.Shots++
		chain.Emit("Shot", "id", itoa(id), "shot", itoa(t.N), "bidder", bidder.String(), "paid", itoa(shot), "take", itoa(take), "bps", itoa(bps), "commit", hex.EncodeToString([]byte(t.Hash)), "revealAt", itoa(t.CommitH+ShotDelay))
	}
}

// shotRefusal is why a shot cannot be sold on this pool right now ("" when it
// can): the checks a bid runs before taking one, in the order the page shows.
// The odds themselves are checked by the caller, on the booked state.
func (p *Pool) shotRefusal(shooter address, shot int64) string {
	switch {
	case !shotsOn:
		return "shots are off"
	case keeper != "" && shooter == keeper:
		return "the keeper never shoots"
	case shot < MinShot:
		return "under the smallest shot, " + GNOT(MinShot)
	case head >= len(commits):
		return "no commitment free: the keeper is away"
	case keeperSeen.IsZero() || time.Now().Unix()-keeperSeen.Unix() > KeeperFresh:
		return "the keeper has not been seen for " + dur(KeeperFresh)
	case p.LiveBps() < LiveFloor:
		return "the winner's share has slid under a quarter"
	}
	return ""
}

// SetShots turns shots off (or on again); only the deployer may.
func SetShots(cur realm, on bool) {
	if userCaller(cur) != admin {
		panic("only the deployer")
	}
	shotsOn = on
	chain.Emit("Shots", "on", jbool(on))
}

// SetKeeper names the address that commits and heartbeats; only the deployer
// may. Every unused commitment is dropped with it: a rotated or compromised
// keeper's secrets never decide a shot.
func SetKeeper(cur realm, addr address) {
	if userCaller(cur) != admin {
		panic("only the deployer")
	}
	if !addr.IsValid() {
		panic("bad address")
	}
	keeper = addr
	commits = commits[:head]
	chain.Emit("Keeper", "addr", addr.String())
}

func keeperCaller(cur realm) address {
	who := userCaller(cur)
	if who == "" || who != keeper {
		panic("only the keeper")
	}
	return who
}

func keeperOrAdmin(cur realm) address {
	who := userCaller(cur)
	if who != admin && (who == "" || who != keeper) {
		panic("only the keeper or the deployer")
	}
	return who
}

// Heartbeat is the keeper's sign of life: shots are sold only within
// KeeperFresh of the last one (a Commit counts too).
func Heartbeat(cur realm) {
	keeperCaller(cur)
	keeperSeen = time.Now()
}

// Commit queues the hashes of secrets the keeper will reveal later, in order,
// as a comma-separated list of 64 hex characters each; only the keeper, whose
// box holds the secrets. A hash still in the queue (used or not) is refused: a
// repeated secret would be public after its first reveal (a safety net against
// the keeper repeating itself; compaction forgets the oldest). The queue holds
// at most MaxCommits unused; the used ones in front of it are compacted away
// past CommitCompact.
func Commit(cur realm, hashes string) {
	keeperCaller(cur)
	keeperSeen = time.Now()
	parts := strings.Split(hashes, ",")
	if len(parts) == 0 || len(parts) > CommitBatch {
		panic("1 to " + strconv.Itoa(CommitBatch) + " hashes")
	}
	if len(commits)-head+len(parts) > MaxCommits {
		panic("the queue holds " + strconv.Itoa(MaxCommits) + " unused commitments at most")
	}
	if head > CommitCompact {
		commits = append([]string(nil), commits[head:]...)
		head = 0
	}
	for _, part := range parts {
		b, err := hex.DecodeString(strings.TrimSpace(part))
		if err != nil || len(b) != 32 {
			panic("a hash is 64 hex characters")
		}
		h := string(b)
		for _, c := range commits { // a safety net against the keeper repeating itself, over what the queue still holds
			if c == h {
				panic("hash already committed: " + part)
			}
		}
		commits = append(commits, h)
	}
	chain.Emit("Commit", "n", itoa(int64(len(parts))), "free", itoa(int64(len(commits)-head)))
}

// Retire drops the first n unused commitments: a keeper that lost the secrets
// behind them (the box rebuilt, the file gone) clears them so shots can go on.
// The deployer may too. It is not a sign of life.
func Retire(cur realm, n int64) {
	keeperOrAdmin(cur)
	if n <= 0 {
		panic("retire at least one")
	}
	if int(n) > len(commits)-head {
		n = int64(len(commits) - head)
	}
	commits = append(commits[:head], commits[head+int(n):]...)
	chain.Emit("Retire", "n", itoa(n), "free", itoa(int64(len(commits)-head)))
}

// Reveal draws shots with the secrets behind their commitments: a comma-separated
// list of pool:shot:secretHex, any pools, in one transaction — the keeper sends
// every shot that is due in one call, so a run of shots on one block never
// outpaces it. Anyone may call it; the secret is the proof, and the caller is
// tipped RevealTip out of each shot revealed. Shots go in order: an earlier one
// still pending must come first (in the list, or before). An entry not yet due
// is skipped, one with a wrong secret or already resolved is skipped with an
// event, so a stale entry never voids the rest; a malformed one (no such pool
// or shot, a cancelled pool, not pool:shot:secret) aborts the whole call, which
// only the keeper's own bug could send. The reveal must land in the
// blocks CommitH+ShotDelay through CommitH+ShotDelay+ShotWindow; later, or on a
// pool that has closed, the shot is already void (settleShots runs first): into
// the pot as a miss. A hit pops the bubble: the pool closes now with the shooter
// as its winner, settled at Claim.
func Reveal(cur realm, reveals string) {
	who := userCaller(cur)
	h := runtime.ChainHeight()
	done := 0
	for _, entry := range strings.Split(reveals, ",") {
		f := strings.Split(strings.TrimSpace(entry), ":")
		if len(f) != 3 {
			panic("each entry is pool:shot:secret")
		}
		id, n := parseID(f[0]), parseNum(f[1])
		p := pool(id)
		if p.Cancelled {
			panic("pool was cancelled")
		}
		p.settleShots()
		if n < 1 || int(n) > len(p.Shots) {
			panic("no such shot")
		}
		t := p.Shots[n-1]
		if t.Resolved || (n > 1 && !p.Shots[n-2].Resolved) {
			chain.Emit("RevealSkipped", "id", itoa(id), "shot", itoa(n), "why", jif(t.Resolved, "resolved", "earlier shot pending"))
			continue
		}
		if h < t.CommitH+ShotDelay {
			continue // not due yet: the keeper sends a block early to be sure of the window
		}
		secret, err := hex.DecodeString(strings.TrimSpace(f[2]))
		sum := sha256.Sum256(secret)
		if err != nil || string(sum[:]) != t.Hash {
			chain.Emit("RevealSkipped", "id", itoa(id), "shot", itoa(n), "why", "wrong secret")
			continue
		}
		// (a shot past its window, or on a pool that closed, was voided by settleShots above and skipped as resolved)
		done++
		t.Resolved, t.DrawH, t.Revealer = true, h, who
		p.ShotEscrow -= t.Paid
		// the tip is the keeper's whoever sent the reveal: the secret sits in the mempool, and a proposer could
		// copy it into a reveal of its own; the seed does not care who reveals, so nothing else changes
		tip := RevealTip
		if tip > t.Paid {
			tip = t.Paid
		}
		if keeper != "" {
			credit(keeper, tip)
		} else {
			credit(who, tip)
		}
		p.Pot += t.Paid - tip
		if h > t.CommitH+ShotDelay { // revealed in the window but not at its first block: the honest keeper's tell, counted
			p.Late++
			late++
		}
		t.Won = shotHits(seedFor(id, t, secret, h), t.Bps)
		chain.Emit("Revealed", "id", itoa(id), "shot", itoa(n), "bidder", t.Bidder.String(), "hit", jbool(t.Won), "bps", itoa(t.Bps), "by", who.String())
		if !t.Won {
			p.Misses++
			continue
		}
		player(t.Bidder).Hits++
		p.Popped, p.PoppedAt, p.LastBidder = true, time.Now(), t.Bidder
		chain.Emit("Popped", "id", itoa(id), "by", t.Bidder.String(), "pot", itoa(p.Pot))
	}
	if done == 0 {
		panic("nothing revealed")
	}
}

// Settle voids the shots at a pool that nobody revealed in time, or that its
// close overtook. Anyone may call it; every bid, reveal and claim on the pool
// does the same first.
func Settle(cur realm, id int64) {
	pool(id).settleShots()
}

// settleShots voids, in order, every pending shot whose window has passed or
// whose pool is over: the shot's money goes into the pot and counts as a miss;
// nobody is tipped.
func (p *Pool) settleShots() {
	h := runtime.ChainHeight()
	over := p.Over()
	for p.Settled < len(p.Shots) && p.Shots[p.Settled].Resolved {
		p.Settled++
	}
	for _, t := range p.Shots[p.Settled:] {
		if t.Resolved || (h <= t.CommitH+ShotDelay+ShotWindow && !over) {
			continue
		}
		t.Resolved, t.Void, t.DrawH = true, true, h
		p.ShotEscrow -= t.Paid
		p.Pot += t.Paid
		p.Misses++
		p.Voided++
		voided++
		chain.Emit("Voided", "id", itoa(p.ID), "shot", itoa(t.N), "bidder", t.Bidder.String(), "why", jif(over, "closed", "unrevealed"))
	}
}

func jif(c bool, a, b string) string {
	if c {
		return a
	}
	return b
}

// seedFor is the draw's seed: the secret with the shot's own facts and the
// reveal block's height and time. Everything but the secret is public, and the
// secret is the keeper's until the reveal; the block's time is the validators'.
func seedFor(poolID int64, t *Shot, secret []byte, h int64) uint64 {
	var b []byte
	b = append(b, pkgPath...)
	b = binary.BigEndian.AppendUint64(b, uint64(poolID))
	b = binary.BigEndian.AppendUint64(b, uint64(t.N))
	b = append(b, t.Bidder.String()...)
	b = binary.BigEndian.AppendUint64(b, uint64(t.CommitH))
	b = append(b, secret...)
	b = binary.BigEndian.AppendUint64(b, uint64(h))
	b = binary.BigEndian.AppendUint64(b, uint64(time.Now().UnixNano()))
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
	p.settleShots()
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
	toWinner, _ := p.payout(winner, p.Pot, true)
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

// payout is the close's arithmetic for a winner and a pot: TeamShare to the
// other roster members under the winner's flag (or, when nobody else flew it,
// to all the others), then the shared part of the rest — what the live share
// has slid away from — to the whole roster pro-rata by paid-in; the winner
// keeps the rest and the rounding. With pay it credits and books the shares;
// dry, it only says what the winner would get and what the team would (Take
// prices shots with both).
func (p *Pool) payout(winner address, pot int64, pay bool) (toWinner, teamCut int64) {
	flag := ""
	if m := p.find(winner); m != nil {
		flag = m.Flag
	}
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
	toWinner = pot
	if team == 0 {
		return toWinner, 0 // alone on the roster: everything
	}
	cut := pot * TeamShare / 100
	for _, m := range p.Roster {
		if m.Addr == winner || (teamFlag != "" && m.Flag != teamFlag) {
			continue
		}
		amt := mulDiv(cut, m.Paid, team)
		if amt > 0 {
			toWinner -= amt
			teamCut += amt
			if pay {
				credit(m.Addr, amt)
				player(m.Addr).Won += amt
				p.TeamPaid += amt
			}
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
				toWinner -= amt
				if pay {
					credit(m.Addr, amt)
					player(m.Addr).Won += amt
					p.SharedPaid += amt
				}
			}
		}
	}
	return toWinner, teamCut
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

func parseNum(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("bad number")
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
	case path == "commits":
		return jsonCommits()
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
	b.WriteString(",\"shots\":" + itoa(int64(len(p.Shots))) + ",\"misses\":" + itoa(p.Misses) + ",\"voided\":" + itoa(p.Voided) + ",\"late\":" + itoa(p.Late) + ",\"pending\":" + itoa(pending) + ",\"escrow\":" + itoa(p.ShotEscrow))
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
			b.WriteString("{\"n\":" + itoa(t.N) + ",\"bidder\":\"" + t.Bidder.String() + "\",\"paid\":" + itoa(t.Paid) + ",\"take\":" + itoa(t.Take) + ",\"bps\":" + itoa(t.Bps) + ",\"commitH\":" + itoa(t.CommitH) + ",\"commit\":\"" + hex.EncodeToString([]byte(t.Hash)) + "\",\"revealAt\":" + itoa(t.CommitH+ShotDelay) + ",\"revealBy\":" + itoa(t.CommitH+ShotDelay+ShotWindow) + ",\"resolved\":" + jbool(t.Resolved) + ",\"hit\":" + jbool(t.Won) + ",\"void\":" + jbool(t.Void) + ",\"drawH\":" + itoa(t.DrawH) + "}")
		}
		b.WriteString("]")
	}
	b.WriteString("}")
	return b.String()
}

// jsonCommits lists the unused commitments in order, hex, so a keeper that
// starts can tell which of them it holds the secrets for and Retire the rest.
func jsonCommits() string {
	var b strings.Builder
	b.WriteString("{\"height\":" + itoa(runtime.ChainHeight()) + ",\"commits\":[")
	for i := head; i < len(commits); i++ {
		if i > head {
			b.WriteString(",")
		}
		b.WriteString("\"" + hex.EncodeToString([]byte(commits[i])) + "\"")
	}
	b.WriteString("]}")
	return b.String()
}

// commitHead is the next commitment a shot would take, hex, "" when none is free.
func commitHead() string {
	if head >= len(commits) {
		return ""
	}
	return hex.EncodeToString([]byte(commits[head]))
}

func jsonAll() string {
	var b strings.Builder
	b.WriteString("{\"now\":" + itoa(time.Now().Unix()) + ",\"height\":" + itoa(runtime.ChainHeight()) + ",\"realm\":\"" + pkgPath + "\"")
	b.WriteString(",\"split\":{\"pot\":" + itoa(PotShare) + ",\"div\":" + itoa(DivShare) + ",\"ref\":" + itoa(RefShare) + ",\"creator\":" + itoa(CreatorShare) + ",\"team\":" + itoa(TeamShare) + ",\"roster\":" + itoa(int64(RosterMax)) +
		",\"shotMaxBps\":" + itoa(ShotMaxBps) + ",\"shotFair\":" + itoa(ShotFair) + ",\"shotDelay\":" + itoa(ShotDelay) + ",\"shotWindow\":" + itoa(ShotWindow) + ",\"minClock\":" + itoa(MinClock) +
		",\"minShot\":" + itoa(MinShot) + ",\"revealTip\":" + itoa(RevealTip) + ",\"keeperFresh\":" + itoa(KeeperFresh) + ",\"liveFloor\":" + itoa(LiveFloor) + "}")
	b.WriteString(",\"shotsOn\":" + jbool(shotsOn))
	b.WriteString(",\"keeper\":\"" + keeper.String() + "\",\"keeperSeen\":" + unix(keeperSeen) + ",\"commitsFree\":" + itoa(int64(len(commits)-head)) + ",\"commitHead\":\"" + commitHead() + "\",\"voided\":" + itoa(voided) + ",\"late\":" + itoa(late))
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
	b.WriteString("# Bubble Rumble v4\n\n")
	b.WriteString("Last bid standing takes the pot. Of every bid, 55% goes into the pot, 30% is paid at once to the pool's earlier bidders, 10% to whoever invited the bidder and 5% to the pool's creator. ")
	b.WriteString("Earnings are credited and withdrawn with Withdraw. At the close " + itoa(TeamShare) + "% of the pot goes to the other bidders who flew the winner's flag. Every pool has a last day: as it nears, the winner's own share slides toward a split of the pot among all its bidders. A bid may carry a shot at the bubble: a chance of at most " + itoa(ShotMaxBps/100) + "% to pop it and take the pot, drawn by the keeper's commit-reveal a few blocks later (the keeper never bids; a shot it fails to reveal in time is a miss); every miss is counted on the bubble.\n\n")
	b.WriteString("Play at [bubblerumble.net](https://bubblerumble.net).\n\n## Pools\n\n")
	if len(pools) == 0 {
		b.WriteString("_none yet_\n")
	}
	for _, p := range pools {
		b.WriteString("- [#" + itoa(p.ID) + " " + p.Name + "](/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble4:" + itoa(p.ID) + ") · " + GNOT(p.Pot) + " · " + p.status() + "\n")
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
		b.WriteString("- shots: " + itoa(int64(len(p.Shots))) + " · misses: " + itoa(p.Misses) + " · unrevealed: " + itoa(p.Voided) + "\n")
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
