// rev 2026-11-26T23:57Z — resubmitted for the hackathon submission window
// rev 2026-11-26T17:22Z — realm resubmitted after the packages were verified
package kolektif

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/rosca"
	"gno.land/p/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/roscasched"
)

// circles holds every circle ever created on this realm. A circle's ID is its
// 1-based position, so circles[id-1] is the circle with that ID.
var (
	circles []*Circle
	seq     uint64
)

// Create opens a new circle. The caller becomes its creator but not a member:
// joining is a separate transaction because it locks collateral.
//
// contribution is denominated in ugnot (1 GNOT = 1000000 ugnot); collateral is
// always one contribution; roundSpan is the length of a round in seconds.
func Create(cur realm, name string, contribution int64, size int, roundSpan int64) uint64 {
	caller := cur.Previous().Address()
	// Opening a circle is free. Reading the envelope makes the VM's
	// "coins were sent but never read" rule explicit here: a stray payment
	// reverts the whole transaction instead of getting stuck in the realm.
	if sent := unsafe.OriginSend(); sent.AmountOf("ugnot") > 0 {
		panic("kolektif: opening a circle is free, do not attach coins")
	}
	name = strings.TrimSpace(name)
	if len(name) < 3 {
		panic("kolektif: name needs at least 3 characters")
	}
	if len(name) > rosca.MaxNameLen {
		panic("kolektif: name is longer than 64 characters")
	}
	params := rosca.Params{
		Contribution: contribution,
		Collateral:   contribution,
		Size:         size,
		RoundSpan:    roundSpan,
	}
	if err := params.Validate(); err != nil {
		panic("kolektif: " + err.Error())
	}

	seq++
	c := &Circle{
		ID:        seq,
		Name:      name,
		Creator:   caller,
		Params:    params,
		Status:    rosca.StatusOpen,
		OpenedAt: time.Now(),
	}
	circles = append(circles, c)

	chain.Emit("CircleCreated",
		"id", strconv.FormatUint(c.ID, 10),
		"creator", caller.String(),
		"contribution", strconv.FormatInt(contribution, 10),
		"size", strconv.Itoa(size),
	)
	return c.ID
}

// Join takes a seat in an open circle and locks exactly one contribution as
// collateral. When the last seat fills, the circle activates: the payout order
// is fixed from chain state and round 1 opens.
func Join(cur realm, id uint64) {
	c := mustCircle(id)
	if c.Status != rosca.StatusOpen {
		panic("kolektif: this circle is no longer open")
	}
	caller := cur.Previous().Address()
	if c.Member(caller) != nil {
		panic("kolektif: you already hold a seat in this circle")
	}
	if len(c.Members) >= c.Params.Size {
		panic("kolektif: this circle is full")
	}
	requireExact(cur, c.Params.Collateral, "collateral")

	c.Members = append(c.Members, &Member{
		Addr:       caller,
		Collateral: c.Params.Collateral,
		PaidRound:  -1,
		JoinedAt:   time.Now(),
	})
	c.Pool += c.Params.Collateral

	chain.Emit("MemberJoined",
		"id", strconv.FormatUint(c.ID, 10),
		"member", caller.String(),
		"seats", strconv.Itoa(len(c.Members)),
	)

	if len(c.Members) >= c.Params.Size {
		activate(c)
	}
}

// Contribute pays one round for the caller. When the last active member pays,
// the pot is released to the round's beneficiary in the same transaction.
func Contribute(cur realm, id uint64) {
	c := mustCircle(id)
	if c.Status != rosca.StatusActive {
		panic("kolektif: this circle is not active")
	}
	caller := cur.Previous().Address()
	m := c.Member(caller)
	if m == nil {
		panic("kolektif: you do not hold a seat in this circle")
	}
	if m.Defaulted {
		panic("kolektif: you defaulted earlier in this circle")
	}
	if m.PaidRound >= c.Round {
		panic("kolektif: you already paid round " + strconv.Itoa(c.Round))
	}
	if time.Now().Unix() > c.Deadline.Unix() {
		panic("kolektif: the round deadline passed; call Advance to settle defaults first")
	}
	requireExact(cur, c.Params.Contribution, "round contribution")

	m.PaidRound = c.Round
	m.RoundsPaid++
	c.Pool += c.Params.Contribution
	c.PaidInTotal += c.Params.Contribution

	chain.Emit("Contribution",
		"id", strconv.FormatUint(c.ID, 10),
		"member", caller.String(),
		"round", strconv.Itoa(c.Round),
		"amount", strconv.FormatInt(c.Params.Contribution, 10),
	)

	if c.RoundPaid() {
		settle(cur, c)
	}
}

// Advance settles a round whose deadline passed. Every active member that did
// not pay is declared in default: their collateral moves to the penalty fund
// that honest members share when the circle closes, they lose the seat, and
// the round's pot is released from whatever was actually collected.
//
// Anyone can call this: it is not a privilege, it is cleanup.
func Advance(cur realm, id uint64) {
	c := mustCircle(id)
	if c.Status != rosca.StatusActive {
		panic("kolektif: this circle is not active")
	}
	if c.RoundPaid() {
		panic("kolektif: every active member already paid this round")
	}
	if time.Now().Unix() <= c.Deadline.Unix() {
		panic("kolektif: the round deadline has not passed yet")
	}

	defaulted := 0
	for _, m := range c.Members {
		if m.Defaulted || m.PaidRound >= c.Round {
			continue
		}
		m.Defaulted = true
		defaulted++
		if m.Collateral > 0 {
			c.Penalty += m.Collateral
			c.Payouts = append(c.Payouts, Payout{
				Round:  c.Round,
				To:     m.Addr,
				Amount: m.Collateral,
				At:     time.Now(),
				Kind:   "slash",
			})
			m.Collateral = 0
		}
	}
	if defaulted == 0 {
		panic("kolektif: nothing to settle")
	}

	chain.Emit("DefaultsDeclared",
		"id", strconv.FormatUint(c.ID, 10),
		"round", strconv.Itoa(c.Round),
		"count", strconv.Itoa(defaulted),
	)

	settle(cur, c)
}

// Leave returns the caller's collateral and frees the seat. Only possible
// while the circle is still open: once it is active the round schedule is
// committed, and leaving is handled as a default instead.
func Leave(cur realm, id uint64) {
	c := mustCircle(id)
	if c.Status != rosca.StatusOpen {
		panic("kolektif: you can only leave a circle that has not been activated")
	}
	caller := cur.Previous().Address()
	for i, m := range c.Members {
		if m.Addr != caller {
			continue
		}
		sendUgnot(cur, c, m.Addr, m.Collateral)
		m.Collateral = 0
		c.Members = append(c.Members[:i], c.Members[i+1:]...)
		chain.Emit("MemberLeft", "id", strconv.FormatUint(c.ID, 10), "member", caller.String())
		return
	}
	panic("kolektif: you do not hold a seat in this circle")
}

// Cancel closes a circle that never filled and refunds every seat. Only the
// creator can cancel.
func Cancel(cur realm, id uint64) {
	c := mustCircle(id)
	if cur.Previous().Address() != c.Creator {
		panic("kolektif: only the creator can cancel a circle")
	}
	if c.Status != rosca.StatusOpen {
		panic("kolektif: only an open circle can be cancelled")
	}
	for _, m := range c.Members {
		if m.Collateral > 0 {
			sendUgnot(cur, c, m.Addr, m.Collateral)
			c.Payouts = append(c.Payouts, Payout{
				Round:  -1,
				To:     m.Addr,
				Amount: m.Collateral,
				At:     time.Now(),
				Kind:   "refund",
			})
			m.Collateral = 0
		}
	}
	c.Status = rosca.StatusComplete
	c.Cancelled = true
	c.ClosedAt = time.Now()
	chain.Emit("CircleCancelled", "id", strconv.FormatUint(c.ID, 10))
}

// --- internal state machine -------------------------------------------

// activate turns a full circle into a running one and fixes its payout order.
func activate(c *Circle) {
	parts := make([]string, 0, len(c.Members))
	for _, m := range c.Members {
		parts = append(parts, m.Addr.String())
	}
	height := runtime.ChainHeight()
	c.Seed = roscasched.Seed(c.ID, height, parts)
	c.Order = roscasched.Order(len(c.Members), c.Seed)
	c.ActivateHeight = height
	c.Status = rosca.StatusActive
	c.ActivatedAt = time.Now()
	c.Round = 0
	c.Deadline = c.ActivatedAt.Add(time.Duration(c.Params.RoundSpan) * time.Second)

	chain.Emit("CircleActivated",
		"id", strconv.FormatUint(c.ID, 10),
		"height", strconv.FormatInt(height, 10),
		"seed", c.Seed,
	)
}

// settle pays the current round's pot to the next beneficiary, then either
// opens the next round or closes the circle.
func settle(cur realm, c *Circle) {
	pot := int64(0)
	for _, m := range c.Members {
		if !m.Defaulted && m.PaidRound == c.Round {
			pot += c.Params.Contribution
		}
	}
	bi := c.NextBeneficiary()
	if bi < 0 {
		// Nobody is left to receive: every remaining seat either received
		// already or defaulted. The money collected this round belongs to the
		// members who paid it, so it goes back to them instead of sitting in
		// the realm with no claimant (audit finding, 2026-11-26).
		returnPot(cur, c, pot)
		finish(cur, c)
		return
	}
	if pot <= 0 {
		finish(cur, c)
		return
	}

	ben := c.Members[bi]
	sendUgnot(cur, c, ben.Addr, pot)
	ben.Received = true
	c.Payouts = append(c.Payouts, Payout{
		Round:  c.Round,
		To:     ben.Addr,
		Amount: pot,
		At:     time.Now(),
		Kind:   "pot",
	})

	chain.Emit("PotPaid",
		"id", strconv.FormatUint(c.ID, 10),
		"round", strconv.Itoa(c.Round),
		"to", ben.Addr.String(),
		"amount", strconv.FormatInt(pot, 10),
	)

	c.Round++
	if c.RoundsSettled() >= c.RoundsPlanned() {
		finish(cur, c)
		return
	}
	c.Deadline = time.Now().Add(time.Duration(c.Params.RoundSpan) * time.Second)
}

// finish closes the circle: every honest member gets their collateral back
// plus an equal share of the slashed penalty fund. When every seat defaulted
// there is nobody to refund, so the residual pool goes back to the creator
// instead of staying in the realm with no claimant.
func finish(cur realm, c *Circle) {
	honest := make([]*Member, 0, len(c.Members))
	for _, m := range c.Members {
		if !m.Defaulted {
			honest = append(honest, m)
		}
	}
	if len(honest) == 0 {
		returnResidual(cur, c, "every seat defaulted")
	} else {
		shares := rosca.Split(c.Penalty, len(honest))
		for i, m := range honest {
			amount := m.Collateral + shares[i]
			if amount <= 0 {
				continue
			}
			sendUgnot(cur, c, m.Addr, amount)
			c.Payouts = append(c.Payouts, Payout{
				Round:  -1,
				To:     m.Addr,
				Amount: amount,
				At:     time.Now(),
				Kind:   "refund",
			})
			m.Collateral = 0
		}
	}
	c.Penalty = 0
	// Last line of defence: a circle that closes must not leave value behind.
	if c.Pool > 0 {
		returnResidual(cur, c, "rounding residual")
	}
	c.Status = rosca.StatusComplete
	c.ClosedAt = time.Now()

	chain.Emit("CircleClosed",
		"id", strconv.FormatUint(c.ID, 10),
		"paidOut", strconv.FormatInt(c.PaidOutTotal, 10),
	)
}

// returnPot refunds a round's collected contributions to the members who paid
// it, used when no seat is left to receive the pot.
func returnPot(cur realm, c *Circle, pot int64) {
	if pot <= 0 {
		return
	}
	payers := make([]address, 0, len(c.Members))
	for _, m := range c.Members {
		if !m.Defaulted && m.PaidRound == c.Round {
			payers = append(payers, m.Addr)
		}
	}
	if len(payers) == 0 {
		return
	}
	shares := rosca.Split(pot, len(payers))
	for i, a := range payers {
		if shares[i] <= 0 {
			continue
		}
		sendUgnot(cur, c, a, shares[i])
		c.Payouts = append(c.Payouts, Payout{
			Round:  c.Round,
			To:     a,
			Amount: shares[i],
			At:     time.Now(),
			Kind:   "return",
		})
	}
	chain.Emit("PotReturned",
		"id", strconv.FormatUint(c.ID, 10),
		"round", strconv.Itoa(c.Round),
		"amount", strconv.FormatInt(pot, 10),
	)
}

// returnResidual sends whatever the pool still holds to the circle's creator,
// so a closed circle never leaves money stranded in the realm.
func returnResidual(cur realm, c *Circle, why string) {
	amount := c.Pool
	if amount <= 0 {
		return
	}
	sendUgnot(cur, c, c.Creator, amount)
	c.Payouts = append(c.Payouts, Payout{
		Round:  -1,
		To:     c.Creator,
		Amount: amount,
		At:     time.Now(),
		Kind:   "residual",
	})
	chain.Emit("ResidualReturned",
		"id", strconv.FormatUint(c.ID, 10),
		"to", c.Creator.String(),
		"amount", strconv.FormatInt(amount, 10),
		"why", why,
	)
}

// --- money helpers -----------------------------------------------------

// requireExact asserts that the transaction carried exactly want ugnot.
//
// Only user transactions are accepted: OriginSend() describes the coins that
// landed on this realm for a MsgCall, and a realm-to-realm call would make that
// number mean something else.
func requireExact(cur realm, want int64, what string) {
	prev := cur.Previous()
	// A real payment arrives with a user realm on the stack (MsgCall). Calls
	// from another package are refused: OriginSend() describes coins that landed
	// on *this* realm only when the caller is a plain user transaction. A call
	// from our own package is the unit-test harness inside the realm itself.
	if !prev.IsUser() && prev.PkgPath() != cur.PkgPath() {
		panic("kolektif: only direct user transactions can move funds")
	}
	got := unsafe.OriginSend().AmountOf("ugnot")
	if got != want {
		panic("kolektif: " + what + " must be exactly " + rosca.Gnot(want) + " GNOT, received " + rosca.Gnot(got))
	}
}

// sendUgnot pays amount out of the circle's pool.
func sendUgnot(cur realm, c *Circle, to address, amount int64) {
	if amount <= 0 {
		return
	}
	if amount > c.Pool {
		panic("kolektif: accounting invariant violated: payout exceeds circle pool")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
	c.Pool -= amount
	c.PaidOutTotal += amount
}

func mustCircle(id uint64) *Circle {
	if id == 0 || int(id) > len(circles) {
		panic("kolektif: unknown circle id")
	}
	return circles[id-1]
}
