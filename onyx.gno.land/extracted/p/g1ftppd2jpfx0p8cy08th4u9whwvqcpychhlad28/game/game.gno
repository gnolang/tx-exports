// Package game is the match engine: the board, the coins and the rules for
// one turn. It has no idea where moves come from, so the arena and bot
// authors (for local testing) can both drive it.
//
// A game is stored compactly: the seed plus one byte per move. Everything
// else (positions, gold, coins, replays) is rebuilt from those, because the
// rules are deterministic. That keeps on-chain storage, which is paid per
// byte, to a few hundred bytes per match.
package game

import (
	"strings"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
)

const (
	// CoinCount is how many coins a board starts with.
	CoinCount = 9
	// RespawnEvery is how often (in turns) a new mirrored pair of coins
	// appears, so the board never runs dry.
	RespawnEvery = 5
	// MaxCoins caps how many coins can be on the board at once.
	MaxCoins = 12
)

// Game is one match in progress. Side 0 starts top-left, side 1 bottom-right.
type Game struct {
	Seed  int
	Turn  int
	CellA int    // side 0's square, as X*Size+Y
	CellB int    // side 1's square
	GoldA int    // side 0's gold
	GoldB int    // side 1's gold
	Coins string // one byte per coin still on the board, X*Size+Y
	Moves string // two bytes per turn played: side 0's action, side 1's action
}

// Events is what happened in one turn besides the moves themselves.
type Events struct {
	Stole   [2]bool // side took a coin from the enemy with an attack
	Parried [2]bool // side defended against an attack and took a coin back
	Spawned int     // coins that appeared at the end of the turn
}

// Snapshot is the board after some turn, for replays.
type Snapshot struct {
	Turn   int
	Pos    [2]bot.Pos
	Gold   [2]int
	Coins  []bot.Pos
	Act    [2]bot.Action // actions of this turn (zero at turn 0)
	Events Events        // what happened this turn
}

func cell(p bot.Pos) int      { return p.X*bot.Size + p.Y }
func pos(c int) bot.Pos       { return bot.Pos{c / bot.Size, c % bot.Size} }
func coinByte(p bot.Pos) byte { return byte(cell(p)) }

// New makes a board from seed. Coins are placed point-symmetric around the
// centre, so neither starting corner has an advantage.
func New(seed int) *Game {
	return &Game{
		Seed:  seed,
		CellA: cell(bot.Pos{0, 0}),
		CellB: cell(bot.Pos{bot.Size - 1, bot.Size - 1}),
		Coins: startCoins(seed),
	}
}

func startCoins(seed int) string {
	mid := bot.Size / 2
	coins := []bot.Pos{{mid, mid}}
	r := uint32(seed)*2654435761 + 12345
	for len(coins) < CoinCount {
		r = r*1103515245 + 12345
		x := int((r >> 8) % bot.Size)
		r = r*1103515245 + 12345
		y := int((r >> 8) % bot.Size)
		p := bot.Pos{x, y}
		mirror := bot.Pos{bot.Size - 1 - x, bot.Size - 1 - y}
		if p == mirror || isCorner(p) || containsPos(coins, p) {
			continue
		}
		coins = append(coins, p, mirror)
	}
	var sb strings.Builder
	for _, c := range coins {
		sb.WriteByte(coinByte(c))
	}
	return sb.String()
}

func isCorner(p bot.Pos) bool {
	return (p.X == 0 || p.X == bot.Size-1) && (p.Y == 0 || p.Y == bot.Size-1)
}

func containsPos(ps []bot.Pos, p bot.Pos) bool {
	for _, q := range ps {
		if q == p {
			return true
		}
	}
	return false
}

// Pos returns side's square.
func (g *Game) Pos(side int) bot.Pos {
	if side == 0 {
		return pos(g.CellA)
	}
	return pos(g.CellB)
}

// Gold returns side's gold.
func (g *Game) Gold(side int) int {
	if side == 0 {
		return g.GoldA
	}
	return g.GoldB
}

// CoinList returns the coins still on the board.
func (g *Game) CoinList() []bot.Pos {
	out := make([]bot.Pos, 0, len(g.Coins))
	for i := 0; i < len(g.Coins); i++ {
		out = append(out, pos(int(g.Coins[i])))
	}
	return out
}

// Over reports whether all turns have been played.
func (g *Game) Over() bool { return g.Turn >= bot.Turns }

// View is what side sees: a fresh copy of the board from its point of view.
func (g *Game) View(matchID, side int) bot.State {
	other := 1 - side
	var last [2]bot.Action
	if n := len(g.Moves); n >= 2 {
		last = [2]bot.Action{bot.Action(g.Moves[n-2]), bot.Action(g.Moves[n-1])}
	}
	return bot.State{
		Match:     matchID,
		Turn:      g.Turn,
		Me:        g.Pos(side),
		Enemy:     g.Pos(other),
		MyGold:    g.Gold(side),
		EnemyGold: g.Gold(other),
		Coins:     g.CoinList(),
		MyLast:    last[side],
		EnemyLast: last[other],
	}
}

// Step plays one turn and reports what happened. The rules, in order:
//  1. Invalid actions count as Stay.
//  2. Fights, only when the two bots are adjacent:
//     - Attack against anything but Defend steals one coin from the enemy.
//     - Attack against Defend is parried: the defender takes one coin from
//       the attacker instead.
//     - Two attacks both land, so they cancel out.
//     A bot with no gold has nothing to lose.
//  3. Moves: both bots move at the same time, and never share a square. If
//     both step onto the same square, the bot with priority this turn gets it
//     (PriorityAt: side 0 on even turns, side 1 on odd turns) and the other
//     stays put. A bot can't step into the other's square or swap with it.
//  4. Pickup: a bot on a coin takes it.
//  5. Every RespawnEvery turns a new mirrored pair of coins appears on free
//     squares, up to MaxCoins on the board.
func (g *Game) Step(a, b bot.Action) (ev Events) {
	if g.Over() {
		panic("game is over")
	}
	act := [2]bot.Action{a, b}
	for i := range act {
		if !act[i].Valid() {
			act[i] = bot.Stay
		}
	}
	p := [2]bot.Pos{g.Pos(0), g.Pos(1)}
	gold := [2]int{g.GoldA, g.GoldB}

	if bot.Adjacent(p[0], p[1]) {
		var gain [2]int // coins each side takes from the other
		for side := 0; side < 2; side++ {
			other := 1 - side
			if act[side] != bot.Attack {
				continue
			}
			if act[other] == bot.Defend {
				if gold[side] > 0 {
					gain[other]++
					ev.Parried[other] = true
				}
			} else if gold[other] > 0 {
				gain[side]++
				ev.Stole[side] = true
			}
		}
		gold[0] += gain[0] - gain[1]
		gold[1] += gain[1] - gain[0]
	}

	p = g.move(p, act)

	coins := g.Coins
	for side := 0; side < 2; side++ {
		var got bool
		if coins, got = takeCoin(coins, p[side]); got {
			gold[side]++
		}
	}

	g.CellA, g.CellB = cell(p[0]), cell(p[1])
	g.GoldA, g.GoldB = gold[0], gold[1]
	g.Moves += string([]byte{byte(act[0]), byte(act[1])})
	g.Turn++
	if g.Turn%RespawnEvery == 0 && g.Turn < bot.Turns {
		before := len(coins)
		coins = g.spawn(coins, p)
		ev.Spawned = len(coins) - before
	}
	g.Coins = coins
	return ev
}

// PriorityAt is the side that wins a contested square on turn t.
func PriorityAt(t int) int { return t % 2 }

// move resolves both moves so the bots never share a square.
func (g *Game) move(p [2]bot.Pos, act [2]bot.Action) [2]bot.Pos {
	t := [2]bot.Pos{bot.Apply(p[0], act[0]), bot.Apply(p[1], act[1])}
	if t[0] == p[1] && t[1] == p[0] {
		return p // swapping places: both blocked
	}
	if t[0] == t[1] {
		// both want the same square, or one steps into a bot that stays
		mover0, mover1 := t[0] != p[0], t[1] != p[1]
		switch {
		case mover0 && mover1:
			loser := 1 - PriorityAt(g.Turn)
			t[loser] = p[loser]
		case mover0:
			t[0] = p[0]
		default:
			t[1] = p[1]
		}
	}
	// a bot stepping into the square the other one keeps is blocked
	if t[0] == t[1] {
		if t[0] != p[0] {
			t[0] = p[0]
		} else {
			t[1] = p[1]
		}
	}
	return t
}

// spawn adds one mirrored pair of coins on free squares, chosen from the seed
// and the turn so replays are exact.
func (g *Game) spawn(coins string, bots [2]bot.Pos) string {
	if len(coins)+2 > MaxCoins {
		return coins
	}
	r := uint32(g.Seed)*2654435761 + uint32(g.Turn)*40503 + 7
	for tries := 0; tries < 30; tries++ {
		r = r*1103515245 + 12345
		x := int((r >> 8) % bot.Size)
		r = r*1103515245 + 12345
		y := int((r >> 8) % bot.Size)
		p := bot.Pos{x, y}
		m := bot.Pos{bot.Size - 1 - x, bot.Size - 1 - y}
		if p == m || p == bots[0] || p == bots[1] || m == bots[0] || m == bots[1] {
			continue
		}
		if strings.IndexByte(coins, coinByte(p)) >= 0 || strings.IndexByte(coins, coinByte(m)) >= 0 {
			continue
		}
		return coins + string([]byte{coinByte(p), coinByte(m)})
	}
	return coins
}

func takeCoin(coins string, p bot.Pos) (string, bool) {
	if i := strings.IndexByte(coins, coinByte(p)); i >= 0 {
		return coins[:i] + coins[i+1:], true
	}
	return coins, false
}

// Winner returns 0 or 1 for the side with more gold, or -1 for a draw.
func (g *Game) Winner() int {
	switch {
	case g.GoldA > g.GoldB:
		return 0
	case g.GoldB > g.GoldA:
		return 1
	}
	return -1
}

// Timeline replays the match once and returns what happened on each turn:
// element i is turn i+1.
func (g *Game) Timeline() []Events {
	r := New(g.Seed)
	out := make([]Events, 0, g.Turn)
	for i := 0; i < g.Turn; i++ {
		out = append(out, r.Step(bot.Action(g.Moves[2*i]), bot.Action(g.Moves[2*i+1])))
	}
	return out
}

// At rebuilds the board after turn t (0 is the starting board) by replaying
// the recorded moves on a fresh board with the same seed.
func (g *Game) At(t int) Snapshot {
	if t > g.Turn {
		t = g.Turn
	}
	if t < 0 {
		t = 0
	}
	r := New(g.Seed)
	var s Snapshot
	for i := 0; i < t; i++ {
		a, b := bot.Action(g.Moves[2*i]), bot.Action(g.Moves[2*i+1])
		s.Events = r.Step(a, b)
		s.Act = [2]bot.Action{a, b}
	}
	s.Turn = t
	s.Pos = [2]bot.Pos{r.Pos(0), r.Pos(1)}
	s.Gold = [2]int{r.GoldA, r.GoldB}
	s.Coins = r.CoinList()
	return s
}
