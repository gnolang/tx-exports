package coppermug

import (
	"chain/runtime"
)

// openCupErr reports whether a stake can be opened, or why not.
func openCupErr(addr string, stake int64) string {
	a, ok := seats[addr]
	if !ok {
		return "no stool yet: call Join first"
	}
	if a.InCup {
		return "your cup is already on the table: roll or hold"
	}
	if stake < MinStake {
		return "the minimum stake is 10 gold"
	}
	if stake > a.Gold {
		return "you cannot stake gold you do not have"
	}
	return ""
}

// OpenCup puts a stake on the table and starts a run.
//
// The rules are simple: roll a d6.
//   - 1 busts the run and the stake is gone
//   - 2-5 adds half the stake to the pot
//   - 6 multiplies the pot by 1.2
//
// You may Hold at any time and take the pot. Gold is tavern money and is
// worth nothing outside this realm.
func OpenCup(cur realm, stake int64) {
	addr, _ := caller(cur)
	if msg := openCupErr(addr, stake); msg != "" {
		panic(msg)
	}

	a := seats[addr]
	a.Gold -= stake
	a.InCup = true
	a.Stake = stake
	a.Pot = stake
	a.Rolls = 0
	a.CupDice = nil
	a.LastSeen = runtime.ChainHeight()
	touch(addr)

	emit("CupOpen", "addr", addr, "stake", itoa(stake))
}

// rollErr reports whether a cup is on the table.
func rollErr(addr string) string {
	a, ok := seats[addr]
	if !ok {
		return "no stool yet: call Join first"
	}
	if !a.InCup {
		return "no cup on the table: call OpenCup first"
	}
	return ""
}

// Roll throws the die once. It returns the die, the pot after the throw,
// and whether the run busted.
func Roll(cur realm) (int, int64, bool) {
	addr, _ := caller(cur)
	if msg := rollErr(addr); msg != "" {
		panic(msg)
	}

	a := seats[addr]
	d := rollDie(addr)
	a.CupDice = append(a.CupDice, d)
	a.Rolls++
	a.LastSeen = runtime.ChainHeight()
	touch(addr)

	if d == 1 {
		lost := a.Stake
		a.InCup = false
		a.Losses++
		a.CupDice = nil
		a.Pot = 0
		a.Stake = 0
		a.Rolls = 0

		addPost("bust", addr, a, "cups out — the dice take **"+itoa(lost)+" gold**.")
		emit("CupBust", "addr", addr, "lost", itoa(lost))
		return d, 0, true
	}

	if d == 6 {
		a.Pot = a.Pot * 6 / 5
	} else {
		a.Pot += a.Stake / 2
	}

	emit("CupRoll", "addr", addr, "die", itoa(int64(d)), "pot", itoa(a.Pot))
	return d, a.Pot, false
}

// holdErr reports whether a cup can be banked.
func holdErr(addr string) string {
	a, ok := seats[addr]
	if !ok {
		return "no stool yet: call Join first"
	}
	if !a.InCup {
		return "no cup on the table: call OpenCup first"
	}
	if a.Rolls == 0 {
		return "roll at least once before you hold"
	}
	return ""
}

// Hold banks the pot and ends the run.
func Hold(cur realm) (int64, int64) {
	addr, _ := caller(cur)
	if msg := holdErr(addr); msg != "" {
		panic(msg)
	}

	a := seats[addr]
	payout := a.Pot
	stake := a.Stake
	a.Gold += payout
	a.InCup = false
	a.CupDice = nil
	a.Pot = 0
	a.Stake = 0
	a.Rolls = 0
	a.LastSeen = runtime.ChainHeight()
	touch(addr)

	if payout > stake {
		a.Wins++
		if payout > a.BestPot {
			a.BestPot = payout
		}
		addPost("win", addr, a, "cashes out **"+itoa(payout)+" gold** from a "+itoa(stake)+" gold cup.")
	} else if payout < stake {
		a.Losses++
		addPost("cash", addr, a, "takes **"+itoa(payout)+" gold** off a "+itoa(stake)+" gold cup and calls it a night.")
	} else {
		addPost("cash", addr, a, "walks away with their "+itoa(stake)+" gold stake intact.")
	}

	emit("CupHold", "addr", addr, "payout", itoa(payout), "stake", itoa(stake))
	return payout, a.Gold
}
