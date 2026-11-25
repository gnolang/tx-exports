package core

import (
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
	"gno.land/p/nt/avl/v0"
)

func MustBounty(db *State, id int) *Bounty {
	b, ok := db.Bounties.Get(textfmt.Key(id)).(*Bounty)
	if !ok || b == nil {
		panic("bounty not found")
	}
	return b
}

func AgentOf(db *State, addr address) *Agent {
	return db.Agents.Get(addr.String()).(*Agent)
}

// reindex applies change to an agent and keeps the leaderboard index in sync.
func Reindex(db *State, a *Agent, change func()) {
	if a.Entries > 0 {
		db.Board.Remove(boardKey(a))
	} else {
		defer func() {
			if a.Entries > 0 {
				db.Competing++
			}
		}()
	}
	change()
	if a.Entries > 0 {
		db.Board.Set(boardKey(a), a)
	}
}

// boardKey sorts by earned desc, then wins desc, then address.
func boardKey(a *Agent) string {
	return textfmt.Pad(9223372036854775807-a.Earned, 19) + textfmt.Pad(int64(2147483647-a.Wins), 10) + a.Addr.String()
}

func AddID(t *avl.Tree, a address, id int) {
	ids, _ := t.Get(a.String()).([]int)
	t.Set(a.String(), append(ids, id))
}

func Phase(b *Bounty) string {
	if b.Status != StatusOpen {
		return b.Status
	}
	now := time.Now()
	if now.Before(b.Deadline) {
		return StatusOpen
	}
	if now.Before(b.JudgeBy) {
		return StatusJudging
	}
	return "awaiting-fallback"
}
