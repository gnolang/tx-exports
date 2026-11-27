package arena

import (
	"testing"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/game"
)

func TestCodecRoundTrip(t *testing.T) {
	g := game.New(77)
	for i := 0; i < 23; i++ {
		g.Step(bot.Action(i%7), bot.Action((i+3)%7))
	}
	m := &Match{
		ID: 42, BotA: "alpha-1", BotB: "zeta", Status: Stepping, Game: *g,
		Challenger: address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
		Created:    123456789012, Rated: true, Waiting: 1, Held: bot.Defend, Deadline: 123456789112,
		Winner: 1, Forfeit: true, Reason: "zeta missed its move deadline on turn 24", Delta: -17, Settled: 99,
	}
	got := decode(42, m.encode())
	if got.encode() != m.encode() {
		t.Fatal("round trip changed the record")
	}
	if got.Game.Moves != g.Moves || got.Game.Coins != g.Coins || got.Game.Turn != 23 {
		t.Fatal("game state lost")
	}
	if got.Challenger != m.Challenger || got.Held != bot.Defend || got.Delta != -17 || !got.Rated || got.Created != 123456789012 {
		t.Fatalf("fields lost: %+v", got)
	}
	// the replay rebuilt from the decoded record matches the live game
	if got.Game.At(23).Pos != g.At(23).Pos {
		t.Fatal("replay differs after decoding")
	}
}

func TestCodecRejectsCorruptRecords(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected a panic")
		}
	}()
	decode(1, "garbage")
}
