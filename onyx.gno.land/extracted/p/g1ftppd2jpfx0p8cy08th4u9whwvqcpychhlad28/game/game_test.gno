package game

import (
	"testing"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
)

// set places both bots, their gold and the coins, for rule tests.
func set(g *Game, a, b bot.Pos, ga, gb int, coins ...bot.Pos) {
	g.CellA, g.CellB = cell(a), cell(b)
	g.GoldA, g.GoldB = ga, gb
	g.Coins = ""
	for _, c := range coins {
		g.Coins += string([]byte{coinByte(c)})
	}
}

func TestNewBoardIsFairAndDeterministic(t *testing.T) {
	for seed := 0; seed < 20; seed++ {
		g := New(seed)
		coins := g.CoinList()
		if len(coins) != CoinCount {
			t.Fatalf("seed %d: %d coins", seed, len(coins))
		}
		for _, c := range coins {
			mirror := bot.Pos{bot.Size - 1 - c.X, bot.Size - 1 - c.Y}
			if !containsPos(coins, mirror) {
				t.Fatalf("seed %d: coin %v has no mirror", seed, c)
			}
			if isCorner(c) {
				t.Fatalf("seed %d: coin on a corner", seed)
			}
		}
		if New(seed).Coins != g.Coins {
			t.Fatalf("seed %d: board not deterministic", seed)
		}
	}
	if New(1).Coins == New(2).Coins {
		t.Error("different seeds should give different boards")
	}
}

func TestPickupAndInvalidActions(t *testing.T) {
	g := New(1)
	set(g, bot.Pos{0, 0}, bot.Pos{8, 8}, 0, 0, bot.Pos{1, 0})
	g.Step(bot.Right, bot.Action(99))
	if g.GoldA != 1 || g.Coins != "" {
		t.Fatalf("pickup failed: gold %d coins %q", g.GoldA, g.Coins)
	}
	if g.Pos(1) != (bot.Pos{8, 8}) || bot.Action(g.Moves[1]) != bot.Stay {
		t.Fatal("invalid action should be recorded as stay")
	}
}

func TestAttackDefendAndSteal(t *testing.T) {
	g := New(1)
	set(g, bot.Pos{4, 4}, bot.Pos{4, 5}, 2, 3)

	if ev := g.Step(bot.Attack, bot.Defend); !ev.Parried[1] || g.GoldA != 1 || g.GoldB != 4 {
		t.Fatalf("defend should parry and take a coin back: %d-%d", g.GoldA, g.GoldB)
	}
	if ev := g.Step(bot.Attack, bot.Stay); !ev.Stole[0] || g.GoldA != 2 || g.GoldB != 3 {
		t.Fatal("attack should steal")
	}
	g.Step(bot.Attack, bot.Attack)
	if g.GoldA != 2 || g.GoldB != 3 {
		t.Fatal("mutual attacks cancel out")
	}
	set(g, bot.Pos{0, 0}, bot.Pos{5, 5}, 3, 2)
	g.Step(bot.Attack, bot.Defend)
	if g.GoldA != 3 || g.GoldB != 2 {
		t.Fatal("attack out of range must do nothing")
	}
	set(g, bot.Pos{4, 4}, bot.Pos{4, 5}, 0, 0)
	if ev := g.Step(bot.Attack, bot.Stay); ev.Stole[0] {
		t.Fatal("nothing to steal from an empty enemy")
	}
	set(g, bot.Pos{4, 4}, bot.Pos{4, 5}, 0, 3)
	if ev := g.Step(bot.Attack, bot.Defend); ev.Parried[1] || g.GoldB != 3 {
		t.Fatal("parrying an attacker with no gold takes nothing")
	}
}

func TestBotsNeverShareASquare(t *testing.T) {
	// both step onto the same coin: priority alternates by turn
	g := New(1)
	set(g, bot.Pos{3, 4}, bot.Pos{5, 4}, 0, 0, bot.Pos{4, 4})
	g.Step(bot.Right, bot.Left) // turn 0: side 0 has priority
	if g.Pos(0) != (bot.Pos{4, 4}) || g.Pos(1) != (bot.Pos{5, 4}) || g.GoldA != 1 || g.GoldB != 0 {
		t.Fatalf("turn 0 contest: %v %v gold %d-%d", g.Pos(0), g.Pos(1), g.GoldA, g.GoldB)
	}
	set(g, bot.Pos{3, 4}, bot.Pos{5, 4}, 0, 0, bot.Pos{4, 4})
	g.Step(bot.Right, bot.Left) // turn 1: side 1 has priority
	if g.Pos(1) != (bot.Pos{4, 4}) || g.Pos(0) != (bot.Pos{3, 4}) || g.GoldB != 1 {
		t.Fatalf("turn 1 contest: %v %v", g.Pos(0), g.Pos(1))
	}
	// stepping into a bot that stays is blocked
	set(g, bot.Pos{3, 4}, bot.Pos{4, 4}, 0, 0)
	g.Step(bot.Right, bot.Stay)
	if g.Pos(0) != (bot.Pos{3, 4}) {
		t.Fatal("moved into an occupied square")
	}
	// swapping places is blocked
	g.Step(bot.Right, bot.Left)
	if g.Pos(0) != (bot.Pos{3, 4}) || g.Pos(1) != (bot.Pos{4, 4}) {
		t.Fatal("bots swapped places")
	}
	// following a bot that moves away is fine
	g.Step(bot.Right, bot.Right)
	if g.Pos(0) != (bot.Pos{4, 4}) || g.Pos(1) != (bot.Pos{5, 4}) {
		t.Fatalf("follow failed: %v %v", g.Pos(0), g.Pos(1))
	}
	// whatever the moves, they never overlap
	acts := []bot.Action{bot.Up, bot.Down, bot.Left, bot.Right, bot.Stay}
	h := New(2)
	for i := 0; !h.Over(); i++ {
		h.Step(acts[i%5], acts[(i*3+1)%5])
		if h.Pos(0) == h.Pos(1) {
			t.Fatalf("overlap on turn %d", h.Turn)
		}
	}
}

func TestRespawnKeepsBoardAliveAndFair(t *testing.T) {
	g := New(4)
	for !g.Over() {
		before := len(g.Coins)
		ev := g.Step(bot.Stay, bot.Stay)
		if g.Turn%RespawnEvery == 0 && g.Turn < bot.Turns && before <= MaxCoins-2 && ev.Spawned != 2 {
			t.Fatalf("turn %d: expected a pair to spawn", g.Turn)
		}
		coins := g.CoinList()
		if len(coins) > MaxCoins {
			t.Fatalf("turn %d: %d coins", g.Turn, len(coins))
		}
		for _, c := range coins {
			if !containsPos(coins, bot.Pos{bot.Size - 1 - c.X, bot.Size - 1 - c.Y}) {
				t.Fatalf("turn %d: coin %v has no mirror", g.Turn, c)
			}
		}
	}
	// a hungry bot keeps finding coins all game long
	h := New(4)
	lastPickup := 0
	for !h.Over() {
		s := h.View(0, 0)
		a := bot.Stay
		if c, ok := s.NearestCoin(); ok {
			a = bot.StepToward(s.Me, c)
		}
		before := h.GoldA
		h.Step(a, bot.Stay)
		if h.GoldA > before {
			lastPickup = h.Turn
		}
	}
	if lastPickup < 40 {
		t.Fatalf("coins ran out too early: last pickup on turn %d", lastPickup)
	}
}

func TestGameEndsAndWinner(t *testing.T) {
	g := New(3)
	for !g.Over() {
		g.Step(bot.Stay, bot.Stay)
	}
	if g.Turn != bot.Turns || len(g.Moves) != 2*bot.Turns || g.Winner() != -1 {
		t.Fatal("50 idle turns should be a draw")
	}
	defer func() {
		if recover() == nil {
			t.Error("stepping a finished game should panic")
		}
	}()
	g.Step(bot.Stay, bot.Stay)
}

func TestReplayMatchesLiveGame(t *testing.T) {
	g := New(9)
	script := []bot.Action{bot.Right, bot.Down, bot.Attack, bot.Defend, bot.Left, bot.Up}
	var live []Snapshot
	for i := 0; !g.Over(); i++ {
		a, b := script[i%len(script)], script[(i+2)%len(script)]
		g.Step(a, b)
		live = append(live, Snapshot{Turn: g.Turn, Pos: [2]bot.Pos{g.Pos(0), g.Pos(1)}, Gold: [2]int{g.GoldA, g.GoldB}})
	}
	for _, want := range live {
		got := g.At(want.Turn)
		if got.Pos != want.Pos || got.Gold != want.Gold {
			t.Fatalf("turn %d: replay %v %v, live %v %v", want.Turn, got.Pos, got.Gold, want.Pos, want.Gold)
		}
	}
	if start := g.At(0); len(start.Coins) != CoinCount || start.Pos[1] != (bot.Pos{8, 8}) {
		t.Fatal("turn 0 should be the starting board")
	}
}

func TestViewIsACopy(t *testing.T) {
	g := New(5)
	v := g.View(7, 1)
	before := g.Coins
	v.Coins[0] = bot.Pos{0, 0}
	if g.Coins != before {
		t.Fatal("view must not alias the board")
	}
	if v.Me != g.Pos(1) || v.Enemy != g.Pos(0) || v.Match != 7 {
		t.Fatal("view from side 1 is wrong")
	}
	g.Step(bot.Defend, bot.Attack)
	if v := g.View(7, 1); v.MyLast != bot.Attack || v.EnemyLast != bot.Defend {
		t.Fatal("last actions wrong")
	}
}
