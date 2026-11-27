// Package reader is a realm bot that learns. Every time it stands next to an
// opponent it writes down what that opponent did, and it keeps those notes
// across matches. Up close it plays the answer to the opponent's habit: parry
// a bot that likes to attack, step around one that likes to parry, and attack
// anyone else. The more it plays a bot, the better it reads it.
package reader

import (
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/strategies"
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// habits is what reader has seen an opponent do when the two were adjacent.
type habits struct {
	Attacks, Defends, Others int
}

func (h *habits) seen() int { return h.Attacks + h.Defends + h.Others }

var (
	notes    = avl.NewTree() // opponent name -> *habits
	wasClose  bool          // adjacent at the end of our last move
	lastMatch int           // match and turn of our last move, to spot new matches
	lastTurn  int
)

func habitsOf(name string) *habits {
	if v := notes.Get(name); v != nil {
		return v.(*habits)
	}
	h := &habits{}
	notes.Set(name, h)
	return h
}

type readerBot struct{}

// Move is called by the arena every turn.
func (readerBot) Move(s bot.State) bot.Action {
	h := habitsOf(s.EnemyBot)
	if wasClose && lastMatch == s.Match && lastTurn == s.Turn-1 {
		switch s.EnemyLast {
		case bot.Attack:
			h.Attacks++
		case bot.Defend:
			h.Defends++
		default:
			h.Others++
		}
	}
	lastMatch, lastTurn = s.Match, s.Turn
	wasClose = bot.Adjacent(s.Me, s.Enemy)

	if wasClose {
		switch {
		case h.Attacks*2 > h.seen() && s.MyGold > 0:
			return bot.Defend // it attacks a lot: parry
		case h.Defends*2 > h.seen():
			return coinMove(s) // it parries a lot: don't attack into it
		case s.EnemyGold > 0:
			return bot.Attack
		}
	}
	return coinMove(s)
}

func coinMove(s bot.State) bot.Action {
	if c, ok := s.NearestCoin(); ok {
		return bot.StepToward(s.Me, c)
	}
	return strategies.Hunter(s)
}

func init(cur realm) {
	arena.RegisterBot(cross(cur), "reader", readerBot{})
}

// Render shows what reader has learned about each opponent.
func Render(path string) string {
	out := "# reader\n\nA realm bot that learns: it notes what each opponent does up close and plays the answer. [Record](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/reader)\n\n"
	if notes.Size() == 0 {
		return out + "No notes yet.\n"
	}
	out += "| Opponent | Attacks | Parries | Other | Reader's answer |\n|---|---|---|---|---|\n"
	notes.Iterate("", "", func(name string, v any) bool {
		h := v.(*habits)
		answer := "attack"
		switch {
		case h.Attacks*2 > h.seen():
			answer = "parry"
		case h.Defends*2 > h.seen():
			answer = "step around it"
		}
		out += ufmt.Sprintf("| %s | %d | %d | %d | %s |\n", name, h.Attacks, h.Defends, h.Others, answer)
		return false
	})
	return out
}
