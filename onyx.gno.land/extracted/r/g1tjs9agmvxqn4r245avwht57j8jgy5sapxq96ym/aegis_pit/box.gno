package aegis_pit

import (
	"strconv"

	core "gno.land/p/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_core"
)

// Box is a budget a human locks for an AI agent.
// The agent can only move funds inside the Policy; the owner can always exit.
type Box struct {
	ID      int
	Owner   address
	Agent   address
	Policy  *core.Policy
	Balance int64
	Spent   int64
	Blocked int
	Closed  bool
}

func getBox(id int) *Box {
	v := boxes.Get(key(id))
	if v == nil {
		panic("aegis: box not found")
	}
	return v.(*Box)
}

// CreateBox locks the attached ugnot under a spending policy.
// allowedTargets / allowedFns are comma-separated; allowedFns "" means any.
// Use this realm's address as a target + fn "PlaceBet" to let the agent bet via BoxBet.
func CreateBox(cur realm, agent address, allowedTargets, allowedFns string, maxPerTx, expireHeight int64) int {
	amt := takeDeposit(cur)
	if amt <= 0 {
		panic("aegis: attach ugnot to fund the box")
	}
	p, err := core.NewPolicy(allowedTargets, allowedFns, maxPerTx, expireHeight)
	if err != nil {
		panic(err.Error())
	}
	nBoxes++
	b := &Box{ID: nBoxes, Owner: caller(cur), Agent: agent, Policy: p, Balance: amt}
	boxes.Set(key(b.ID), b)
	return b.ID
}

// TopUpBox adds the attached ugnot to an open box (owner only).
func TopUpBox(cur realm, boxID int) {
	amt := takeDeposit(cur)
	b := getBox(boxID)
	if caller(cur) != b.Owner || b.Closed {
		panic("aegis: only the owner can top up an open box")
	}
	b.Balance += amt
}

func checkBoxSpend(b *Box, who address, target address, fn string, amount int64) error {
	if b.Closed {
		return errBox("box closed")
	}
	if who != b.Owner && who != b.Agent {
		return errBox("caller is not the box owner or its agent")
	}
	if err := core.ValidateSpend(b.Policy, target, fn, amount, height()); err != nil {
		return err
	}
	if amount > b.Balance {
		return errBox("insufficient box balance")
	}
	return nil
}

// BoxSpend sends ugnot from the box to target. Any policy violation panics,
// so the whole transaction reverts on-chain.
func BoxSpend(cur realm, boxID int, target address, fn string, amount int64) {
	b := getBox(boxID)
	if err := checkBoxSpend(b, caller(cur), target, fn, amount); err != nil {
		panic(err.Error())
	}
	b.Balance -= amount
	b.Spent += amount
	send(cur, target, amount)
}

// GuardedSpend is the "soft" variant used by the Breaker Lab: instead of
// reverting, a violation is recorded publicly and no coin moves.
func GuardedSpend(cur realm, boxID int, target address, fn string, amount int64) bool {
	b := getBox(boxID)
	if err := checkBoxSpend(b, caller(cur), target, fn, amount); err != nil {
		b.Blocked++
		logLab("blocked", "box #"+strconv.Itoa(boxID)+" → "+string(target)+" "+fn+"("+strconv.FormatInt(amount, 10)+" ugnot): "+err.Error())
		return false
	}
	b.Balance -= amount
	b.Spent += amount
	send(cur, target, amount)
	return true
}

// BoxBet lets an agent bet from a box. The policy must allow this realm's
// address as target and "PlaceBet" as fn. The bet belongs to the box owner.
func BoxBet(cur realm, boxID, matchID, side int, amount int64) {
	b := getBox(boxID)
	if err := checkBoxSpend(b, caller(cur), cur.Address(), "PlaceBet", amount); err != nil {
		panic(err.Error())
	}
	b.Balance -= amount
	b.Spent += amount
	placeBet(getMatch(matchID), b.Owner, side, amount)
}

// LogPreflight lets a box owner/agent publish a pre-flight report (qeval/qrender summary).
func LogPreflight(cur realm, boxID int, report string) {
	b := getBox(boxID)
	who := caller(cur)
	if who != b.Owner && who != b.Agent {
		panic("aegis: only the box owner or agent can log preflight")
	}
	if len(report) > 280 {
		report = report[:280]
	}
	logLab("preflight", "box #"+strconv.Itoa(boxID)+": "+report)
}

// EmergencyWithdraw returns the whole box balance to the owner and closes it.
// Reachable straight from gnoweb via Render("exit"); no external website needed.
func EmergencyWithdraw(cur realm, boxID int) int64 {
	b := getBox(boxID)
	if caller(cur) != b.Owner {
		panic("aegis: only the box owner can withdraw")
	}
	amt := b.Balance
	b.Balance = 0
	b.Closed = true
	send(cur, b.Owner, amt)
	logLab("exit", "box #"+strconv.Itoa(boxID)+" emergency-withdrawn: "+strconv.FormatInt(amt, 10)+" ugnot")
	return amt
}

// BoxBalance is a read helper.
func BoxBalance(boxID int) int64 { return getBox(boxID).Balance }

type boxErr struct{ msg string }

func (e boxErr) Error() string { return "aegis: " + e.msg }

func errBox(msg string) error { return boxErr{msg} }
