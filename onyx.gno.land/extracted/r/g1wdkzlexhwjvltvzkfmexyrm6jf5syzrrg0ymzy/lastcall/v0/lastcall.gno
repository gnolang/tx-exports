// Package lastcall is a price prediction game settled by Tapster.
//
// Every new Tapster answer for a feed opens a game. While that answer is
// the latest one, anyone can bet GNOT that the price will be higher (UP) or
// lower (DOWN) a few oracle rounds later. Once Tapster has published an
// answer at least settleAfter rounds newer, anyone can settle the game and
// earns a small tip for doing it. Winners split the whole pot in
// proportion to their bets. Ties, games with only one side and games
// nobody settled in time are refunded in full.
//
// There is no keeper, no house edge and no admin over the funds: the only
// inputs are bets and Tapster prices.
package lastcall

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapmath/v0"
	"gno.land/r/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapster/v0"
)

const (
	ugnot = "ugnot"

	minBet      int64 = 100000      // 0.1 GNOT
	maxBet      int64 = 100000000   // 100 GNOT per address per game
	maxPot      int64 = 10000000000 // 10,000 GNOT per game keeps payout math in int64
	maxPriceAge int64 = 600         // a game only opens on a price at most 10 minutes old

	settleAfter = 3  // settle on an answer at least 3 oracle rounds after the game's
	voidAfter   = 12 // after 12 rounds without settlement the game is refunded

	tipBps int64 = 50      // settler earns 0.5% of the pot...
	maxTip int64 = 1000000 // ...capped at 1 GNOT
)

// Outcomes.
const (
	Open      = "open"
	Up        = "up"
	Down      = "down"
	Tie       = "tie"       // refunded
	OneSided  = "one-sided" // refunded
	Unsettled = "expired"   // refunded
)

// Position is one address's bet in a game.
type Position struct {
	Addr    address
	Up      bool
	Amount  int64
	Claimed bool
	Payout  int64
}

// Game is one prediction round for one feed.
type Game struct {
	Pair       string
	Round      int64 // Tapster round the game opened on
	StartPrice int64
	Decimals   int
	OpenedAt   int64
	UpPot      int64
	DownPot    int64
	Bettors    int

	Outcome   string
	EndRound  int64
	EndPrice  int64
	SettledAt int64
	Settler   address
	Tip       int64
	Payable   int64 // pot minus tip, shared by the winners

	bets *avl.Tree // address -> *Position
}

// Player keeps lifetime stats for the leaderboard.
type Player struct {
	Addr    address
	Bets    int
	Wagered int64
	Won     int64 // total payouts received, including returned stakes
	Wins    int
}

var (
	games   = avl.NewTree() // gameKey -> *Game
	players = avl.NewTree() // address -> *Player
	open    = avl.NewTree() // gameKey of unsettled games

	totalGames   int
	totalBets    int
	totalVolume  int64
	totalSettled int
	settledLog   []string // gameKeys in settlement order, newest last (max 100)
)

func init(cur realm) {
	tapster.RegisterConsumer(cross(cur), "Last Call: UP/DOWN price game")
}

func now() int64 { return time.Now().Unix() }

func gameKey(pair string, round int64) string {
	return pair + ":" + ufmt.Sprintf("%016d", round)
}

func mustGame(pair string, round int64) *Game {
	v := games.Get(gameKey(pair, round))
	if v == nil {
		panic("no such game")
	}
	return v.(*Game)
}

func assertCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
}

func player(a address) *Player {
	if v := players.Get(a.String()); v != nil {
		return v.(*Player)
	}
	p := &Player{Addr: a}
	players.Set(a.String(), p)
	return p
}

// mulDiv returns a*b/c for 0 <= a <= maxBet and 0 <= b, c <= maxPot
// without overflowing int64.
func mulDiv(a, b, c int64) int64 {
	q, r := b/c, b%c
	return a*q + a*r/c
}

// ----------------------------------------------------------------------
// Playing

// Bet stakes the GNOT sent with the call on the price of pair going up
// (up=true) or down by the time the game settles. The game is the one for
// the latest Tapster answer; adding to an existing bet is allowed, but not
// switching sides. Returns the Tapster round of the game.
func Bet(cur realm, pair string, up bool) int64 {
	assertCurrent(cur)
	// IsUserCall + OriginSend are a pair: only for a direct call from an
	// account are the -send coins guaranteed to have reached this realm.
	if !cur.Previous().IsUserCall() {
		panic("bet directly from an account")
	}
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != ugnot {
			panic("only ugnot is accepted")
		}
	}
	amount := sent.AmountOf(ugnot)
	if amount < minBet {
		panic("minimum bet is 0.1 GNOT (100000ugnot)")
	}

	price, dec, at, round, ok := tapster.Latest(pair)
	if !ok {
		panic("Tapster has no price for " + pair + " yet")
	}
	if now()-at > maxPriceAge {
		panic("the " + pair + " price is stale; games open again when Tapster updates")
	}

	key := gameKey(pair, round)
	var g *Game
	if v := games.Get(key); v != nil {
		g = v.(*Game)
	} else {
		g = &Game{Pair: pair, Round: round, StartPrice: price, Decimals: dec, OpenedAt: now(), Outcome: Open, bets: avl.NewTree()}
	}
	if g.Outcome != Open {
		panic("game already settled")
	}
	if g.UpPot+g.DownPot+amount > maxPot {
		panic("this game's pot is full")
	}
	caller := cur.Previous().Address()
	var b *Position
	if v := g.bets.Get(caller.String()); v != nil {
		b = v.(*Position)
		if b.Up != up {
			panic("you already bet the other way in this game")
		}
	}
	if b == nil {
		if amount > maxBet {
			panic("maximum bet is 100 GNOT per game")
		}
	} else if b.Amount+amount > maxBet {
		panic("maximum bet is 100 GNOT per game")
	}

	// All checks passed: write state.
	if !games.Has(key) {
		games.Set(key, g)
		open.Set(key, true)
		totalGames++
	}
	if b == nil {
		b = &Position{Addr: caller, Up: up}
		g.bets.Set(caller.String(), b)
		g.Bettors++
	}
	b.Amount += amount
	if up {
		g.UpPot += amount
	} else {
		g.DownPot += amount
	}
	p := player(caller)
	p.Bets++
	p.Wagered += amount
	totalBets++
	totalVolume += amount
	chain.Emit("Bet", "pair", pair, "round", strconv.FormatInt(round, 10), "up", strconv.FormatBool(up),
		"amount", strconv.FormatInt(amount, 10), "bettor", caller.String())
	return round
}

// Settle closes a game once Tapster has an answer at least settleAfter
// rounds newer than the game's. The caller earns 0.5% of the pot (max
// 1 GNOT) when there are winners to pay. Anyone can call it.
func Settle(cur realm, pair string, round int64) string {
	assertCurrent(cur)
	g := mustGame(pair, round)
	if g.Outcome != Open {
		panic("game already settled")
	}
	price, _, _, latest, ok := tapster.Latest(pair)
	if !ok || latest < g.Round+settleAfter {
		panic(ufmt.Sprintf("too early: this game settles once Tapster reaches round %d (now %d)", g.Round+settleAfter, latest))
	}
	g.EndRound = latest
	g.EndPrice = price
	g.SettledAt = now()
	g.Settler = cur.Previous().Address()
	open.Remove(gameKey(pair, round))
	totalSettled++
	settledLog = append(settledLog, gameKey(pair, round))
	if len(settledLog) > 100 {
		settledLog = settledLog[len(settledLog)-100:]
	}

	switch {
	case latest > g.Round+voidAfter:
		g.Outcome = Unsettled
	case g.UpPot == 0 || g.DownPot == 0:
		g.Outcome = OneSided
	case price == g.StartPrice:
		g.Outcome = Tie
	case price > g.StartPrice:
		g.Outcome = Up
	default:
		g.Outcome = Down
	}

	pot := g.UpPot + g.DownPot
	g.Payable = pot
	if g.Outcome == Up || g.Outcome == Down {
		tip := tapmath.ApplyBps(pot, tipBps)
		if tip > maxTip {
			tip = maxTip
		}
		g.Tip = tip
		g.Payable = pot - tip
		send(cur, g.Settler, tip)
	}
	chain.Emit("Settle", "pair", pair, "round", strconv.FormatInt(round, 10), "outcome", g.Outcome,
		"endPrice", strconv.FormatInt(price, 10))
	return g.Outcome
}

// Claim pays the caller's winnings, or refund, from a settled game.
func Claim(cur realm, pair string, round int64) int64 {
	assertCurrent(cur)
	g := mustGame(pair, round)
	if g.Outcome == Open {
		panic("game not settled yet")
	}
	caller := cur.Previous().Address()
	v := g.bets.Get(caller.String())
	if v == nil {
		panic("you have no bet in this game")
	}
	b := v.(*Position)
	if b.Claimed {
		panic("already claimed")
	}
	payout := payoutFor(g, b)
	if payout == 0 {
		panic("this bet lost")
	}
	b.Claimed = true
	b.Payout = payout
	p := player(caller)
	p.Won += payout
	if g.Outcome == Up || g.Outcome == Down {
		p.Wins++
	}
	send(cur, caller, payout)
	chain.Emit("Claim", "pair", pair, "round", strconv.FormatInt(round, 10), "amount", strconv.FormatInt(payout, 10))
	return payout
}

func payoutFor(g *Game, b *Position) int64 {
	switch g.Outcome {
	case Tie, OneSided, Unsettled:
		return b.Amount
	case Up:
		if !b.Up {
			return 0
		}
		return mulDiv(b.Amount, g.Payable, g.UpPot)
	case Down:
		if b.Up {
			return 0
		}
		return mulDiv(b.Amount, g.Payable, g.DownPot)
	}
	return 0
}

func send(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.Coins{{ugnot, amount}})
}

// ----------------------------------------------------------------------
// Reads

// Odds returns the current pots of the open game for pair and its round,
// or ok=false when there is none.
func Odds(pair string) (round int64, upPot int64, downPot int64, ok bool) {
	_, _, _, r, has := tapster.Latest(pair)
	if !has {
		return 0, 0, 0, false
	}
	v := games.Get(gameKey(pair, r))
	if v == nil {
		return r, 0, 0, true
	}
	g := v.(*Game)
	return r, g.UpPot, g.DownPot, true
}

// Owed returns what addr can claim from a settled game.
func Owed(pair string, round int64, addr address) int64 {
	v := games.Get(gameKey(pair, round))
	if v == nil {
		return 0
	}
	g := v.(*Game)
	if g.Outcome == Open {
		return 0
	}
	bv := g.bets.Get(addr.String())
	if bv == nil {
		return 0
	}
	b := bv.(*Position)
	if b.Claimed {
		return 0
	}
	return payoutFor(g, b)
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func gnot(u int64) string { return tapmath.FormatRounded(u, 6, 3) + " GNOT" }
