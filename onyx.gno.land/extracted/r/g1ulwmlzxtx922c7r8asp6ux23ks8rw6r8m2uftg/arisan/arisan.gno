// Package arisan implements an on-chain rotating savings club (ROSCA),
// known as "arisan" in Indonesia and Southeast Asia.
//
// A circle works like this:
//   - A creator opens a circle with a fixed per-round contribution and a
//     maximum number of members, and automatically becomes its first member.
//   - Other members join while the circle is open.
//   - The creator starts the circle once at least two members have joined.
//   - Every round, each member contributes exactly the agreed amount of
//     ugnot by attaching it to a Contribute call.
//   - As soon as every member has contributed, the realm pays the whole pot
//     to one member, rotating in join order, and the next round begins.
//   - After every member has received the pot exactly once, the circle is
//     finished. No fees are taken and no funds are ever locked outside a
//     round in progress: a round's pot is paid out the moment it completes.
package arisan

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const (
	// minContribution is the smallest allowed per-round contribution:
	// 1000 ugnot = 0.001 GNOT.
	minContribution int64 = 1000
	// minMembers is the smallest circle that can be started.
	minMembers = 2
	// maxMembersCap is the largest allowed circle size.
	maxMembersCap = 12
	// maxNameLen bounds circle names so Render output stays tidy.
	maxNameLen = 48

	statusOpen      = "open"
	statusActive    = "active"
	statusFinished  = "finished"
	statusCancelled = "cancelled"
)

// Circle is one rotating savings club.
type Circle struct {
	id           int
	name         string
	creator      address
	contribution int64 // ugnot each member pays per round
	maxMembers   int
	members      []address
	round        int // current round, 0-based
	status       string
	paid         map[address]bool // contributions received in the current round
	payouts      []address        // pot recipients, in order
}

var (
	circles []*Circle
	nextID  int
)

// originCaller returns the address that signed the transaction. It requires
// a direct call from a user account (an EOA), so an intermediary realm —
// including an ephemeral `maketx run` script — cannot act on a user's
// behalf. For Contribute this guard pairs with the OriginSend amount check:
// only for a direct user call is it guaranteed that the coins attached to
// the transaction actually landed at this realm's address.
func originCaller(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("arisan: must be called directly by a user account")
	}
	return cur.Previous().Address()
}

// validateName restricts circle names to characters that are safe to print
// verbatim in the Markdown that Render returns: no Markdown control
// characters, so a name cannot inject links, images, or headings into the
// realm's pages.
func validateName(name string) {
	for _, r := range name {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || r == ' ' || r == '-' ||
			r == '\'' || r == '.' || r == ',' || r == '!' ||
			r == '(' || r == ')'
		if !ok {
			panic("arisan: circle name contains unsupported characters")
		}
	}
}

func getCircle(id int) *Circle {
	if id < 0 || id >= len(circles) {
		panic("arisan: circle not found")
	}
	return circles[id]
}

func isMember(c *Circle, who address) bool {
	for _, m := range c.members {
		if m == who {
			return true
		}
	}
	return false
}

// nextRecipient returns the member scheduled to receive the current round's
// pot. Recipients rotate in join order, one per round.
func nextRecipient(c *Circle) address {
	return c.members[c.round%len(c.members)]
}

// CreateCircle opens a new circle and returns its ID. The creator is
// automatically the first member.
func CreateCircle(cur realm, name string, contribution int64, maxMembers int) int {
	return createCircle(originCaller(cur), name, contribution, maxMembers)
}

// createCircle is the internal implementation of CreateCircle, separated
// from the transaction envelope so it can be unit-tested directly.
func createCircle(caller address, name string, contribution int64, maxMembers int) int {
	name = strings.TrimSpace(name)
	if name == "" {
		panic("arisan: circle name must not be empty")
	}
	if len(name) > maxNameLen {
		panic("arisan: circle name too long")
	}
	validateName(name)
	if contribution < minContribution {
		panic("arisan: contribution below minimum of 1000 ugnot")
	}
	if maxMembers < minMembers || maxMembers > maxMembersCap {
		panic("arisan: maxMembers must be between 2 and 12")
	}
	c := &Circle{
		id:           nextID,
		name:         name,
		creator:      caller,
		contribution: contribution,
		maxMembers:   maxMembers,
		members:      []address{caller},
		status:       statusOpen,
		paid:         map[address]bool{},
	}
	circles = append(circles, c)
	nextID++
	return c.id
}

// JoinCircle adds the caller to an open circle that is not yet full.
func JoinCircle(cur realm, id int) {
	joinCircle(originCaller(cur), id)
}

func joinCircle(caller address, id int) {
	c := getCircle(id)
	if c.status != statusOpen {
		panic("arisan: circle is not open for joining")
	}
	if isMember(c, caller) {
		panic("arisan: already a member of this circle")
	}
	if len(c.members) >= c.maxMembers {
		panic("arisan: circle is full")
	}
	c.members = append(c.members, caller)
}

// StartCircle moves an open circle into its first round. Only the creator
// can start it, and at least two members must have joined.
func StartCircle(cur realm, id int) {
	startCircle(originCaller(cur), id)
}

func startCircle(caller address, id int) {
	c := getCircle(id)
	if caller != c.creator {
		panic("arisan: only the creator can start the circle")
	}
	if c.status != statusOpen {
		panic("arisan: circle is not open")
	}
	if len(c.members) < minMembers {
		panic("arisan: need at least 2 members to start")
	}
	c.status = statusActive
}

// CancelCircle cancels an open circle. Only the creator can cancel, and
// only before the circle starts (no contributions exist yet, so nothing
// needs to be refunded).
func CancelCircle(cur realm, id int) {
	cancelCircle(originCaller(cur), id)
}

func cancelCircle(caller address, id int) {
	c := getCircle(id)
	if caller != c.creator {
		panic("arisan: only the creator can cancel the circle")
	}
	if c.status != statusOpen {
		panic("arisan: only an open circle can be cancelled")
	}
	c.status = statusCancelled
}

// Contribute records the caller's contribution for the current round. The
// caller must attach exactly the circle's contribution amount in ugnot to
// the call (gnokey: -send "<amount>ugnot"). When the last member of the
// round contributes, the pot is paid out immediately.
func Contribute(cur realm, id int) {
	caller := originCaller(cur)
	sent := unsafe.OriginSend()
	contribute(cur, getCircle(id), caller, int64(sent.AmountOf("ugnot")))
}

// contribute holds the contribution logic, separated from the transaction
// envelope so it can be unit-tested with arbitrary senders and amounts.
func contribute(cur realm, c *Circle, caller address, sentAmount int64) {
	if c.status != statusActive {
		panic("arisan: circle is not active")
	}
	if !isMember(c, caller) {
		panic("arisan: only members can contribute")
	}
	if c.paid[caller] {
		panic("arisan: already contributed this round")
	}
	if sentAmount != c.contribution {
		panic("arisan: must send exactly the contribution amount")
	}
	c.paid[caller] = true

	for _, m := range c.members {
		if !c.paid[m] {
			return // still waiting on other members
		}
	}
	payout(cur, c)
}

// payout sends the completed round's pot to the scheduled recipient and
// advances the circle: next round, or finished once every member has
// received the pot exactly once.
func payout(cur realm, c *Circle) {
	recipient := nextRecipient(c)
	pot := c.contribution * int64(len(c.members))
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), recipient, chain.Coins{{"ugnot", pot}})
	c.payouts = append(c.payouts, recipient)
	c.round++
	c.paid = map[address]bool{}
	if c.round >= len(c.members) {
		c.status = statusFinished
	}
}

// CircleCount returns how many circles have ever been created.
func CircleCount() int {
	return len(circles)
}

// formatGNOT renders a ugnot amount as a decimal GNOT string.
func formatGNOT(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fs := strconv.FormatInt(frac, 10)
	for len(fs) < 6 {
		fs = "0" + fs
	}
	fs = strings.TrimRight(fs, "0")
	return strconv.FormatInt(whole, 10) + "." + fs + " GNOT"
}

// Render is the realm's gnoweb page. The home page lists all circles;
// "circle/<id>" renders one circle's detail page.
func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "circle" {
		id, err := strconv.Atoi(parts[1])
		if err != nil || id < 0 || id >= len(circles) {
			return "# Arisan Circle\n\nCircle not found."
		}
		return renderCircle(circles[id])
	}
	return "# Arisan Circle\n\nPage not found."
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# Arisan Circle\n\n")
	sb.WriteString("A rotating savings club (ROSCA) on Gno.land, inspired by the Indonesian *arisan*: ")
	sb.WriteString("members contribute a fixed amount every round, and each round one member receives the whole pot, ")
	sb.WriteString("rotating until everyone has received it once. No fees, no custodian — the realm holds a round's ")
	sb.WriteString("contributions only until the round completes, then pays out automatically.\n\n")
	sb.WriteString("## Circles\n\n")
	if len(circles) == 0 {
		sb.WriteString("No circles yet. Create the first one with `CreateCircle`.\n")
	}
	for _, c := range circles {
		sb.WriteString("### [" + c.name + "](circle/" + strconv.Itoa(c.id) + ")\n\n")
		sb.WriteString("- Status: **" + c.status + "**\n")
		sb.WriteString("- Contribution: " + formatGNOT(c.contribution) + " per member, per round\n")
		sb.WriteString("- Members: " + strconv.Itoa(len(c.members)) + "/" + strconv.Itoa(c.maxMembers) + "\n")
		if c.status == statusActive {
			sb.WriteString("- Round: " + strconv.Itoa(c.round+1) + " of " + strconv.Itoa(len(c.members)) +
				" — next pot goes to `" + nextRecipient(c).String() + "`\n")
		}
		sb.WriteString("\n")
	}
	sb.WriteString("## How to take part\n\n")
	sb.WriteString("1. `CreateCircle(name, contributionUgnot, maxMembers)` opens a circle.\n")
	sb.WriteString("2. `JoinCircle(id)` joins an open circle.\n")
	sb.WriteString("3. `StartCircle(id)` (creator only) starts round 1.\n")
	sb.WriteString("4. `Contribute(id)` with exactly the contribution attached pays into the current round.\n")
	sb.WriteString("5. When everyone has paid, the pot is sent to that round's recipient automatically.\n")
	return sb.String()
}

func renderCircle(c *Circle) string {
	var sb strings.Builder
	sb.WriteString("# " + c.name + "\n\n")
	sb.WriteString("- Status: **" + c.status + "**\n")
	sb.WriteString("- Creator: `" + c.creator.String() + "`\n")
	sb.WriteString("- Contribution: " + formatGNOT(c.contribution) + " (" + strconv.FormatInt(c.contribution, 10) + " ugnot) per member, per round\n")
	sb.WriteString("- Pot per round: " + formatGNOT(c.contribution*int64(len(c.members))) + "\n\n")

	sb.WriteString("## Members (in payout order)\n\n")
	for i, m := range c.members {
		line := strconv.Itoa(i+1) + ". `" + m.String() + "`"
		if c.status == statusActive {
			if c.paid[m] {
				line += " — paid this round ✅"
			} else {
				line += " — not yet paid this round"
			}
			if m == nextRecipient(c) {
				line += " — **receives this round's pot**"
			}
		}
		sb.WriteString(line + "\n")
	}

	if c.status == statusActive {
		sb.WriteString("\nRound " + strconv.Itoa(c.round+1) + " of " + strconv.Itoa(len(c.members)) + " is in progress.\n")
	}
	if len(c.payouts) > 0 {
		sb.WriteString("\n## Payout history\n\n")
		for i, p := range c.payouts {
			sb.WriteString("- Round " + strconv.Itoa(i+1) + ": `" + p.String() + "`\n")
		}
	}
	sb.WriteString("\n[← All circles](./)\n")
	return sb.String()
}
