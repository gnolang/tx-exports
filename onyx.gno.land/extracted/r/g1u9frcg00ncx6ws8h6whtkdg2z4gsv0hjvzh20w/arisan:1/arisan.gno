// Package arisan implements a rotating savings circle (arisan) on Gno.land.
//
// Arisan is an Indonesian tradition: a group of people each contribute a
// fixed amount every round, and each round one member — in rotation order —
// takes the whole pot. All rules and all money live on-chain in this realm.
//
// Rules:
//   - Anyone can create a circle (name, contribution per round in ugnot,
//     maximum members). The creator is the organizer.
//   - Members join while the circle is open (before round 1 starts).
//     Join order IS the rotation order: deterministic, no randomness.
//   - Every round, each member deposits exactly the contribution via the
//     -send envelope. A member who has not paid yet is shown as BELUM BAYAR.
//   - The organizer advances the round only when every member has paid.
//     On advance, the pot (members x contribution) is paid from the realm
//     to the member whose turn it is, then the next round begins.
//   - All money accounting is exact int64 ugnot. No fees are taken.
package arisan

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Circle is one arisan group.
type Circle struct {
	ID           int
	Name         string
	Organizer    address
	Contribution int64 // ugnot per member per round
	MaxMembers   int
	Members      []address // join order == rotation order
	Round        int       // current round; 0 = not started
	Started      bool
	Paid         []bool // current-round payment status, aligned with Members
	PaidCount    []int  // total rounds each member has paid
	TurnsTaken   []int  // rounds each member has taken the pot
	Pot          int64  // ugnot currently held for this circle
	TotalPaidOut int64  // total ugnot paid out to turn-takers so far
}

var (
	circles avl.Tree // circle ID (string) -> *Circle
	nextID  int
)

// require panics with msg unless check holds. A panic aborts the whole
// transaction: no state change, no funds move.
func require(check bool, msg string) {
	if !check {
		panic(msg)
	}
}

// mustGetCircle returns the circle with the given ID or panics.
func mustGetCircle(id int) *Circle {
	c := circles.Get(strconv.Itoa(id))
	if c == nil {
		panic("unknown circle ID")
	}
	return c.(*Circle)
}

// memberIndex returns the index of addr in c.Members, or -1.
func memberIndex(c *Circle, a address) int {
	for i, m := range c.Members {
		if m == a {
			return i
		}
	}
	return -1
}

// turnTaker is the member whose turn it is in the current round.
// Round 1 -> Members[0], round 2 -> Members[1], and so on, wrapping around.
func turnTaker(c *Circle) address {
	return c.Members[(c.Round-1)%len(c.Members)]
}

// turnTakerIndex is the index of the current turn-taker in c.Members.
func turnTakerIndex(c *Circle) int {
	return (c.Round - 1) % len(c.Members)
}

// allPaid reports whether every member has paid for the current round.
func allPaid(c *Circle) bool {
	for _, p := range c.Paid {
		if !p {
			return false
		}
	}
	return true
}

// caller returns the address that called this realm function. Only direct
// user calls (maketx call) are accepted: an intermediate realm must not be
// able to act on a user's behalf.
func caller(cur realm) address {
	require(cur.Previous().IsUserCall(), "only direct user calls accepted")
	return cur.Previous().Address()
}

// CreateCircle creates a new arisan circle and returns its ID.
// The caller becomes the organizer.
func CreateCircle(cur realm, name string, contribution int64, maxMembers int) int {
	caller(cur)
	require(name != "", "circle name must not be empty")
	require(contribution > 0, "contribution must be positive (ugnot)")
	require(maxMembers >= 2, "a circle needs at least 2 members")
	nextID++
	c := &Circle{
		ID:           nextID,
		Name:         name,
		Organizer:    cur.Previous().Address(),
		Contribution: contribution,
		MaxMembers:   maxMembers,
		Members:      []address{},
		Round:        0,
		Started:      false,
		Paid:         []bool{},
		PaidCount:    []int{},
		TurnsTaken:   []int{},
		Pot:          0,
		TotalPaidOut: 0,
	}
	circles.Set(strconv.Itoa(c.ID), c)
	return c.ID
}

// JoinCircle adds the caller to a circle. The circle must still be open
// (round 1 has not started) and not full. Join order is rotation order.
func JoinCircle(cur realm, id int) {
	who := caller(cur)
	c := mustGetCircle(id)
	require(!c.Started, "circle already started; joining is closed")
	require(memberIndex(c, who) < 0, "already a member of this circle")
	require(len(c.Members) < c.MaxMembers, "circle is full")
	c.Members = append(c.Members, who)
	c.Paid = append(c.Paid, false)
	c.PaidCount = append(c.PaidCount, 0)
	c.TurnsTaken = append(c.TurnsTaken, 0)
	circles.Set(strconv.Itoa(id), c)
}

// StartCircle starts round 1. Only the organizer can start, and only with
// at least 2 members.
func StartCircle(cur realm, id int) {
	who := caller(cur)
	c := mustGetCircle(id)
	require(who == c.Organizer, "only the organizer can start the circle")
	require(!c.Started, "circle already started")
	require(len(c.Members) >= 2, "need at least 2 members to start")
	c.Started = true
	c.Round = 1
	circles.Set(strconv.Itoa(id), c)
}

// Deposit pays the caller's contribution for the current round.
// The call must carry exactly the contribution in ugnot via -send.
// Anything else (wrong amount, wrong denom, extra coins) aborts.
func Deposit(cur realm, id int) {
	who := caller(cur)
	c := mustGetCircle(id)
	require(c.Started, "circle has not started yet")
	i := memberIndex(c, who)
	require(i >= 0, "only members can deposit")
	require(!c.Paid[i], "already paid for this round")
	sent := unsafe.OriginSend()
	require(len(sent) == 1, "send exactly the contribution (one coin)")
	require(sent[0].Denom == "ugnot", "contribution must be paid in ugnot")
	require(sent[0].Amount == c.Contribution, "send exactly the contribution amount")
	c.Paid[i] = true
	c.PaidCount[i]++
	c.Pot += c.Contribution
	circles.Set(strconv.Itoa(id), c)
}

// AdvanceRound closes the current round and pays the pot to the member
// whose turn it is. Only the organizer can advance, and only when every
// member has paid for the round. The next round then begins.
func AdvanceRound(cur realm, id int) {
	who := caller(cur)
	c := mustGetCircle(id)
	require(who == c.Organizer, "only the organizer can advance the round")
	require(c.Started, "circle has not started yet")
	require(allPaid(c), "not all members have paid for this round")
	takerIdx := turnTakerIndex(c)
	taker := c.Members[takerIdx]
	expectedPot := int64(len(c.Members)) * c.Contribution
	require(c.Pot == expectedPot, "pot accounting mismatch; refusing to pay out")
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	require(b.GetCoin(realmAddr, "ugnot") >= expectedPot, "realm balance below pot; refusing to pay out")
	b.SendCoins(realmAddr, taker, chain.NewCoins(chain.NewCoin("ugnot", expectedPot)))
	c.TurnsTaken[takerIdx]++
	c.TotalPaidOut += expectedPot
	c.Pot = 0
	c.Round++
	for i := range c.Paid {
		c.Paid[i] = false
	}
	circles.Set(strconv.Itoa(id), c)
}

// CircleCount returns how many circles exist.
func CircleCount() int {
	return nextID
}

// CircleInfo returns a one-line summary of a circle.
func CircleInfo(id int) string {
	c := mustGetCircle(id)
	status := "open"
	if c.Started {
		status = "round " + strconv.Itoa(c.Round)
	}
	return ufmt.Sprintf("#%d %s | %s | %d ugnot/round | %d/%d members | pot %d ugnot | paid out %d ugnot",
		c.ID, c.Name, status, c.Contribution, len(c.Members), c.MaxMembers, c.Pot, c.TotalPaidOut)
}

// memberLine renders one member row for Render.
func memberLine(c *Circle, i int) string {
	m := c.Members[i]
	paid := "BELUM BAYAR"
	if c.Started && c.Paid[i] {
		paid = "SUDAH BAYAR"
	} else if !c.Started {
		paid = "menunggu mulai"
	}
	turn := ""
	if c.Started && i == turnTakerIndex(c) {
		turn = " <-- GILIRAN ROUND INI"
	}
	return ufmt.Sprintf("- %s | %s | bayar %d round | ambil pot %d kali%s",
		m.String(), paid, c.PaidCount[i], c.TurnsTaken[i], turn)
}

// renderCircle renders the detail view of one circle.
func renderCircle(c *Circle) string {
	out := ufmt.Sprintf("# Arisan #%d: %s\n\n", c.ID, c.Name)
	out += ufmt.Sprintf("- Penyelenggara (organizer): %s\n", c.Organizer.String())
	out += ufmt.Sprintf("- Iuran per round: %d ugnot\n", c.Contribution)
	out += ufmt.Sprintf("- Anggota: %d / %d\n", len(c.Members), c.MaxMembers)
	if !c.Started {
		out += "- Status: BELUM MULAI (menunggu anggota, organizer memanggil StartCircle)\n"
	} else {
		out += ufmt.Sprintf("- Status: ROUND %d\n", c.Round)
		out += ufmt.Sprintf("- Giliran round ini: %s\n", turnTaker(c).String())
		out += ufmt.Sprintf("- Pot round ini: %d ugnot\n", c.Pot)
	}
	out += ufmt.Sprintf("- Total sudah dibayarkan ke pemenang giliran: %d ugnot\n\n", c.TotalPaidOut)
	out += "## Anggota (urutan gabung = urutan giliran)\n\n"
	for i := range c.Members {
		out += memberLine(c, i) + "\n"
	}
	return out
}

// Render shows the dashboard: all circles, or one circle's detail when the
// path is a circle ID (e.g. /1).
func Render(path string) string {
	if len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}
	if id, err := strconv.Atoi(path); err == nil {
		if c := circles.Get(strconv.Itoa(id)); c != nil {
			return renderCircle(c.(*Circle))
		}
		return "404: circle tidak ditemukan"
	}
	if nextID == 0 {
		return "# Arisan — Rotating Savings Circle\n\nBelum ada circle. Buat circle pertama dengan CreateCircle.\n"
	}
	out := "# Arisan — Rotating Savings Circle\n\n"
	out += "Setiap anggota iuran tiap round; tiap round satu anggota (sesuai urutan gabung) mengambil seluruh pot.\n\n"
	out += "## Circles\n\n"
	for id := 1; id <= nextID; id++ {
		if c := circles.Get(strconv.Itoa(id)); c != nil {
			out += "- " + CircleInfo(id) + "\n"
		}
	}
	return out
}
