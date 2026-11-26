// Package gun runs rotating savings circles ("altın günü") on gno.land.
//
// A group of friends agrees on a contribution and a schedule. Every round
// each member pays the contribution and the whole pot goes to one member,
// in turn, until everyone has received it once. The realm holds the coins,
// keeps the books in the open, and pays out only to whoever is owed.
//
// The rules live in gno.land/p/g1k0pgsw39lh0a6mama0qh0lxa6vphd4yc2w9gqw/rosca,
// which holds no coins; this realm moves them.
package gun

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1k0pgsw39lh0a6mama0qh0lxa6vphd4yc2w9gqw/rosca"
)

const (
	denom        = "ugnot"
	maxPerMember = 200 // circles listed on one member's page
)

var (
	circles   = newTree() // padded id -> *rosca.Circle
	byMember  = newTree() // address -> []int (circle ids)
	lastID    = 0
	totalHeld = int64(0) // sum of Held() over all circles
)

// Create starts a new circle in the forming state and returns its id. The
// caller is the organizer and must be one of the members. members is a
// comma- or space-separated list of addresses in turn order: the first one
// receives the first pot.
func Create(cur realm, name string, contributionUgnot int64, periodSeconds int64,
	collateralRounds int, joinWindowSeconds int64, members string,
) int {
	organizer := cur.Previous().Address()
	addrs := parseMembers(members)
	c, err := rosca.New(rosca.Config{
		Name:             name,
		Contribution:     contributionUgnot,
		Period:           periodSeconds,
		CollateralRounds: collateralRounds,
		JoinWindow:       joinWindowSeconds,
		Members:          addrs,
	}, organizer, now())
	if err != nil {
		panic(err)
	}
	lastID++
	id := lastID
	circles.Set(key(id), c)
	index(organizer, id)
	chain.Emit("CircleCreated",
		"id", strconv.Itoa(id),
		"organizer", organizer.String(),
		"members", strconv.Itoa(len(addrs)),
		"contribution", strconv.FormatInt(contributionUgnot, 10))
	return id
}

// Join locks the caller's collateral. Send exactly the collateral shown on
// the circle's page (nothing when it says 0). The last member to join starts
// the first round.
func Join(cur realm, id int) {
	// The EOA guard and the OriginSend read below are a pair: only a direct
	// user call guarantees the sent coins landed at this realm.
	if !cur.Previous().IsUserCall() {
		panic("gun: call Join directly from your account")
	}
	who := cur.Previous().Address()
	c := mustGet(id)
	before := c.Held()
	if err := c.Join(who, sentUgnot(), now()); err != nil {
		panic(err)
	}
	settleBooks(c, before)
	if who != c.Organizer() {
		index(who, id)
	}
	chain.Emit("Joined", "id", strconv.Itoa(id), "member", who.String(),
		"status", c.Status().String())
}

// Pay pays the caller's contribution for the current round. Send exactly the
// contribution. When the last member pays, the pot is credited to this
// round's recipient, who collects it with Withdraw.
func Pay(cur realm, id int) {
	if !cur.Previous().IsUserCall() { // pairs with sentUgnot, see Join
		panic("gun: call Pay directly from your account")
	}
	who := cur.Previous().Address()
	c := mustGet(id)
	before, round := c.Held(), c.Round()
	if err := c.Pay(who, sentUgnot(), now()); err != nil {
		panic(err)
	}
	settleBooks(c, before)
	chain.Emit("Paid", "id", strconv.Itoa(id), "member", who.String(),
		"round", strconv.Itoa(round+1), "mark", string(c.MarkOf(who)))
	if c.Round() != round {
		emitRoundClosed(id, c, round)
	}
}

// Settle closes an overdue round. Anyone can call it once the round is due.
// Members who did not pay are covered from their collateral; a member with
// no collateral left breaks the circle, which then winds down.
func Settle(cur realm, id int) {
	c := mustGet(id)
	before, round := c.Held(), c.Round()
	if err := c.Settle(now()); err != nil {
		panic(err)
	}
	settleBooks(c, before)
	if c.Status() == rosca.Broken {
		chain.Emit("CircleBroken", "id", strconv.Itoa(id), "round", strconv.Itoa(round+1))
		return
	}
	emitRoundClosed(id, c, round)
}

// ProposeSwap offers to trade turns with another member. Both turns must
// still be ahead of the current round.
func ProposeSwap(cur realm, id int, with address) {
	if err := mustGet(id).ProposeSwap(cur.Previous().Address(), with); err != nil {
		panic(err)
	}
}

// AcceptSwap accepts a member's swap proposal and trades turns with them.
func AcceptSwap(cur realm, id int, from address) {
	who := cur.Previous().Address()
	if err := mustGet(id).AcceptSwap(who, from); err != nil {
		panic(err)
	}
	chain.Emit("TurnsSwapped", "id", strconv.Itoa(id), "a", from.String(), "b", who.String())
}

// Cancel stops a circle that has not started. The organizer can cancel any
// time before it starts; anyone can once the join window has closed.
// Locked collateral becomes withdrawable.
func Cancel(cur realm, id int) {
	c := mustGet(id)
	before := c.Held()
	if err := c.Cancel(cur.Previous().Address(), now()); err != nil {
		panic(err)
	}
	settleBooks(c, before)
	chain.Emit("CircleCancelled", "id", strconv.Itoa(id))
}

// Withdraw sends the caller everything the circle owes them: pots, refunds
// and collateral that has been released.
func Withdraw(cur realm, id int) {
	who := cur.Previous().Address()
	c := mustGet(id)
	before := c.Held()
	amt, err := c.Withdraw(who)
	if err != nil {
		panic(err)
	}
	settleBooks(c, before)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), who, chain.NewCoins(chain.NewCoin(denom, amt)))
	chain.Emit("Withdrawn", "id", strconv.Itoa(id), "member", who.String(),
		"amount", strconv.FormatInt(amt, 10))
}

// ---------------------------------------------------------------- helpers

func now() int64 { return time.Now().Unix() }

func newTree() *avl.Tree { return avl.NewTree() }

func key(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func get(id int) (*rosca.Circle, bool) {
	v := circles.Get(key(id))
	if v == nil {
		return nil, false
	}
	return v.(*rosca.Circle), true
}

func mustGet(id int) *rosca.Circle {
	c, ok := get(id)
	if !ok {
		panic("gun: no circle with id " + strconv.Itoa(id))
	}
	return c
}

// sentUgnot returns the ugnot attached to this call and rejects anything
// else, so no other denom can get stuck here.
func sentUgnot() int64 {
	sent := unsafe.OriginSend()
	total := int64(0)
	for _, coin := range sent {
		if coin.Denom != denom {
			panic("gun: only ugnot is accepted")
		}
		total += coin.Amount
	}
	return total
}

// settleBooks keeps totalHeld in step with the circles' books.
func settleBooks(c *rosca.Circle, before int64) {
	totalHeld += c.Held() - before
}

func index(who address, id int) {
	k := who.String()
	var ids []int
	if v := byMember.Get(k); v != nil {
		ids = v.([]int)
	}
	if len(ids) >= maxPerMember {
		panic("gun: this address is already in " + strconv.Itoa(maxPerMember) + " circles")
	}
	byMember.Set(k, append(ids, id))
}

func parseMembers(s string) []address {
	s = strings.ReplaceAll(s, ",", " ")
	var out []address
	for _, f := range strings.Fields(s) {
		if len(out) > rosca.MaxMembers {
			break // rosca.New rejects the count; stop parsing early
		}
		out = append(out, address(f))
	}
	return out
}

func emitRoundClosed(id int, c *rosca.Circle, round int) {
	h := c.History()
	r := h[len(h)-1]
	chain.Emit("RoundClosed", "id", strconv.Itoa(id), "round", strconv.Itoa(round+1),
		"recipient", r.Recipient.String(), "pot", strconv.FormatInt(r.Pot, 10),
		"marks", r.Marks, "status", c.Status().String())
}
