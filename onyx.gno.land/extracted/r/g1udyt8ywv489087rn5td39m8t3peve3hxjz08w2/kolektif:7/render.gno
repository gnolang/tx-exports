// rev 2026-11-26T18:05Z — pixel-arcade dashboard + audit fixes
package kolektif

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/rosca"
	"gno.land/p/nt/ufmt/v0"
)

// pkgPath is the URL form of this realm's path, used to build links: gnoweb
// serves a realm at /r/<pkgpath>, so a bare "gno.land/r/..." href would be
// resolved as a relative URL by the browser and 404.
const pkgPath = "/r/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/kolektif"

// Render is the gnoweb view of the realm. Every page is Markdown that gnoweb
// renders directly, so the app ships with no frontend at all: the "UI" is
// computed from chain state, and every button is a link that prepares a
// transaction for the visitor's wallet.
//
// The look is a text-mode arcade: frames, HP bars and loot lines are plain
// ASCII inside fenced blocks, so they survive any monospace font gnoweb is
// served with (Unicode block glyphs render as hatched boxes).
func Render(path string) string {
	p := strings.Trim(path, "/")
	switch {
	case p == "":
		return renderIndex()
	case p == "about":
		return renderAbout()
	case strings.HasPrefix(p, "circle/"):
		return renderCirclePath(strings.TrimPrefix(p, "circle/"))
	case strings.HasPrefix(p, "member/"):
		return renderMember(address(strings.TrimPrefix(p, "member/")))
	}
	return notFound(p)
}

// --- pages -------------------------------------------------------------

func renderIndex() string {
	count, active, escrowed, paidOut := GlobalStats()

	out := "# Kolektif\n\n"
	out += banner()
	out += hud(count, active, escrowed, paidOut)
	out += "## Quest board\n\n"
	if len(circles) == 0 {
		out += emptyBoard()
		out += "\n## Controls\n\n"
		out += actionMenu(nil, false)
		return out
	}
	for i := len(circles) - 1; i >= 0; i-- {
		out += renderCircleCard(circles[i])
	}
	out += "\n## Controls\n\n"
	out += actionMenu(nil, false)
	return out
}

// banner is the title screen.
func banner() string {
	out := "```\n"
	out += "  ==============================================================\n"
	out += "    K O L E K T I F   ::   A R I S A N   A R C A D E\n"
	out += "    rotating savings circles, run by the chain\n"
	out += "  ==============================================================\n"
	out += "    ^                                  ^\n"
	out += "   /@\\    pay every round, one         /$\\   no bank, no\n"
	out += "  /   \\   player takes the pot         /   \\  keeper, no\n"
	out += "  |   |   the chain holds it           |   |  arguing\n"
	out += "  |___|                                |___|\n"
	out += "```\n\n"
	return out
}

// hud is the arcade status readout at the top of the title screen.
func hud(count, active int, escrowed, paidOut int64) string {
	out := "```\n"
	out += ufmt.Sprintf("   VAULT ...................... %s\n", money(escrowed))
	out += ufmt.Sprintf("   RUNS OPENED ................ %d\n", count)
	out += ufmt.Sprintf("   RUNS LIVE .................. %d\n", active)
	out += ufmt.Sprintf("   LOOT SETTLED ............... %s\n", money(paidOut))
	out += "```\n\n"
	out += "> **How to play.** Open a run, seat your party, pay every round.\n"
	out += "> When the last player pays, the pot drops on the next player in the\n"
	out += "> order. Collateral is your shield: miss a round and it is slashed.\n\n"
	return out
}

func emptyBoard() string {
	out := "```\n"
	out += "   +-- NO RUNS ON THE BOARD --------------------------------+\n"
	out += "   |  the arcade is empty. open the first run and seat it.  |\n"
	out += "   +--------------------------------------------------------+\n"
	out += "```\n\n"
	out += "**[+ OPEN A RUN](" + helpLink("Create") + ")** · arguments: name, contribution in ugnot, seats (3-50), round seconds\n\n"
	out += "```sh\n" + createCLI() + "\n```\n"
	return out
}

// renderCircleCard is one entry in the quest board: a framed run card plus its
// enter link. Padding is done by hand: gno's ufmt has no "%-14s" verbs.
func renderCircleCard(c *Circle) string {
	settled, planned := c.Progress()
	id := strconv.FormatUint(c.ID, 10)

	out := "```\n"
	out += "   +-- RUN #" + id + " " + strings.Repeat("-", maxInt(4, 30-len(id))) + "[" + pad(statusWord(c), 8) + "]" + strings.Repeat("-", 6) + "+\n"
	out += cardLine(c.Name)
	out += cardLine("STAKE " + money(c.Params.Contribution) + "   SEATS " + strconv.Itoa(c.Seats()) + "/" + strconv.Itoa(c.Params.Size) + "   POT " + money(c.Params.Pot()))
	if c.Status == rosca.StatusOpen {
		out += cardLine("PARTY " + rosca.Bar(c.Seats(), c.Params.Size, 14) + " " + strconv.Itoa(c.Seats()) + "/" + strconv.Itoa(c.Params.Size) + " seats")
	} else if c.Status == rosca.StatusActive {
		next := "nobody left"
		if bi := c.NextBeneficiary(); bi >= 0 {
			next = rosca.ShortAddr(c.Members[bi].Addr.String())
		}
		out += cardLine("LOOT  " + rosca.Bar(settled, planned, 14) + " " + strconv.Itoa(settled) + "/" + strconv.Itoa(planned) + " paid out")
		out += cardLine("NEXT  " + next + " takes the pot")
	} else {
		state := "cancelled, every seat refunded"
		if !c.Cancelled {
			state = "closed " + c.ClosedAt.Format("02 Jan 2006") + " · " + money(c.PaidOutTotal) + " paid out"
		}
		out += cardLine("LOOT  " + rosca.Bar(settled, planned, 14) + " " + strconv.Itoa(settled) + "/" + strconv.Itoa(planned) + " paid out")
		out += cardLine(state)
	}
	out += "   +" + strings.Repeat("-", 60) + "+\n"
	out += "```\n"
	out += "**[>> ENTER RUN #" + id + "](" + pkgPath + ":circle/" + id + ")**"
	if c.Status == rosca.StatusOpen {
		out += " · [join](" + helpLink2("Join", "id", c.ID) + ")"
	}
	out += "\n\n---\n\n"
	return out
}

// statusWord is the arcade label for a run state: short enough to sit inside a
// fixed-width tag without being truncated.
func statusWord(c *Circle) string {
	switch c.Status {
	case rosca.StatusOpen:
		return "OPEN"
	case rosca.StatusActive:
		return "ACTIVE"
	}
	if c.Cancelled {
		return "CANCELLED"
	}
	return "CLEARED"
}

// cardLine pads one row of a run card to the frame width.
func cardLine(s string) string {
	return "   |  " + pad(s, 57) + " |\n"
}

func renderCirclePath(rest string) string {
	rest = strings.Trim(rest, "/")
	parts := strings.Split(rest, "/")
	id := parseID(parts[0])
	if id == 0 || int(id) > len(circles) {
		return notFound("circle/" + rest)
	}
	if len(parts) > 1 && parts[1] == "rules" {
		return renderRules(mustCircle(id))
	}
	return renderCircle(id)
}

func renderCircle(id uint64) string {
	c := mustCircle(id)
	now := time.Now()

	out := "# " + c.Name + "\n\n"
	out += runFrame(c, now)

	out += ufmt.Sprintf("- Stake: **%s** per player per round · **%d** seats · round **%s**\n",
		money(c.Params.Contribution), c.Params.Size, rosca.HumanDuration(c.Params.RoundSpan))
	out += ufmt.Sprintf("- Shield (collateral): **%s** per seat, returned when the run closes\n", money(c.Params.Collateral))
	out += ufmt.Sprintf("- Opened by %s on %s\n\n", who(c.Creator), c.OpenedAt.Format("02 Jan 2006 15:04"))

	switch c.Status {
	case rosca.StatusOpen:
		out += openBody(c)
	case rosca.StatusActive:
		out += activeBody(c, now)
	case rosca.StatusComplete:
		out += completeBody(c)
	}

	out += "\n## Members\n\n"
	out += memberTable(c)

	if len(c.Payouts) > 0 {
		out += "\n## Battle log\n\n"
		out += payoutList(c)
	}

	out += "\n## Controls\n\n"
	out += actionMenu(c, true)
	out += "\n## Client\n\n```sh\n" + clientCLI(c) + "\n```\n"
	out += "\n_Seed of this run's order: `" + c.Seed + "`_\n"
	return out
}

// runFrame is the arcade header for one circle: the state a player needs at a
// glance, framed like a cabinet panel.
func runFrame(c *Circle, now time.Time) string {
	settled, planned := c.Progress()

	out := "```\n"
	out += "  +-- RUN #" + strconv.FormatUint(c.ID, 10) + " " + strings.Repeat("-", 26) + "[" + pad(statusWord(c), 8) + "]" + strings.Repeat("-", 8) + "+\n"
	out += panelLine("POT " + money(c.Params.Pot()) + "   ROUND " + strconv.Itoa(c.Round+1) + "   SEATS " + strconv.Itoa(c.Seats()) + "/" + strconv.Itoa(c.Params.Size))
	if c.Status == rosca.StatusActive {
		next := "nobody left to pay"
		if bi := c.NextBeneficiary(); bi >= 0 {
			next = rosca.ShortAddr(c.Members[bi].Addr.String())
		}
		out += panelLine("LOOT DROPS ON " + next)
		rem := c.Remaining(now)
		if rem > 0 {
			out += panelLine("TIMER " + rosca.Bar(planned-settled, planned, 10) + " " + rosca.HumanDuration(rem) + " left")
		} else {
			out += panelLine("TIMER " + rosca.Bar(planned-settled, planned, 10) + " deadline passed: settle is open")
		}
	} else if c.Status == rosca.StatusOpen {
		out += panelLine("PARTY " + rosca.Bar(c.Seats(), c.Params.Size, 14) + " " + strconv.Itoa(c.Seats()) + "/" + strconv.Itoa(c.Params.Size) + " seats filled")
	} else {
		when := "cancelled"
		if !c.Cancelled {
			when = "closed " + c.ClosedAt.Format("02 Jan 2006")
		}
		out += panelLine(when + " · " + money(c.PaidOutTotal) + " paid out")
	}
	out += "  +" + strings.Repeat("-", 61) + "+\n"
	out += "```\n\n"
	return out
}

// panelLine pads one row of the circle panel.
func panelLine(s string) string {
	return "  |  " + pad(s, 57) + " |\n"
}

func openBody(c *Circle) string {
	out := "\n"
	out += ufmt.Sprintf("**Recruiting.** %d of %d seats filled. The run starts by itself when the last seat is taken.\n\n",
		c.Seats(), c.Params.Size)
	out += rosca.Bar(c.Seats(), c.Params.Size, 20) + " seat " + strconv.Itoa(c.Seats()) + "/" + strconv.Itoa(c.Params.Size) + "\n\n"
	out += ufmt.Sprintf("**[+ JOIN (%s shield)](%s)** · [leave](%s) · [cancel](%s)\n",
		money(c.Params.Collateral), helpLink2("Join", "id", c.ID),
		helpLink2("Leave", "id", c.ID), helpLink2("Cancel", "id", c.ID))
	return out
}

func activeBody(c *Circle, now time.Time) string {
	settled, planned := c.Progress()
	out := "\n"
	out += ufmt.Sprintf("**Round %d of %d.** %s %d/%d loot drops settled.\n\n",
		c.Round+1, planned, rosca.Bar(settled, planned, 16), settled, planned)

	if bi := c.NextBeneficiary(); bi >= 0 {
		out += ufmt.Sprintf("**Loot this round:** %s → %s, released the moment the last player pays.\n\n",
			money(c.Params.Pot()), who(c.Members[bi].Addr))
	}

	rem := c.Remaining(now)
	if rem > 0 {
		out += ufmt.Sprintf("**Timer:** %s left (deadline %s).\n\n",
			rosca.HumanDuration(rem), c.Deadline.Format("02 Jan 15:04"))
	} else {
		out += ufmt.Sprintf("**Timer expired** %s ago — anyone can settle the round.\n\n", rosca.HumanDuration(-rem))
	}

	paid := 0
	for _, m := range c.Members {
		if !m.Defaulted && m.PaidRound >= c.Round {
			paid++
		}
	}
	out += ufmt.Sprintf("**Paid this round:** %d/%d  %s\n\n", paid, c.Active(), rosca.Bar(paid, c.Active(), 16))
	out += ufmt.Sprintf("**[>> PAY %s](%s)**", money(c.Params.Contribution), helpLink2("Contribute", "id", c.ID))
	if rem <= 0 {
		out += ufmt.Sprintf(" · **[settle defaults](%s)**\n", helpLink2("Advance", "id", c.ID))
	} else {
		out += " · _settle opens when the timer hits zero_\n"
	}
	return out
}

func completeBody(c *Circle) string {
	out := "\n"
	if c.Cancelled {
		out += "**Run cancelled.** Every seat was refunded; no pot was ever paid.\n\n"
		return out
	}
	out += ufmt.Sprintf("**Run cleared** on %s. Every surviving player took the pot once, shields came back, and the penalty fund was split among the honest.\n\n",
		c.ClosedAt.Format("02 Jan 2006 15:04"))
	out += ufmt.Sprintf("Paid in %s · paid out %s · still in the vault %s\n\n",
		money(c.PaidInTotal), money(c.PaidOutTotal), money(c.Pool))
	return out
}

// memberTable is the party sheet: seat, player, class glyph, HP bar, status.
func memberTable(c *Circle) string {
	out := "```\n"
	out += "   SEAT  PLAYER          CLASS   HP             ROUNDS  STATE\n"
	out += "   ----  --------------  ------  -------------  ------  -------------\n"
	for i, m := range c.Members {
		state := memberState(m, c)
		out += "   " + pad(strconv.Itoa(i+1), 4) + "  " +
			pad(rosca.ShortAddr(m.Addr.String()), 14) + "  " +
			pad(classFor(i), 6) + "  " +
			pad(roundsPaidBar(m, c), 15) + "  " +
			pad(strconv.Itoa(m.RoundsPaid), 6) + "  " + state + "\n"
	}
	out += "```\n\n"
	out += "| seat | player | shield | loot | status |\n| --- | --- | --- | --- | --- |\n"
	for i, m := range c.Members {
		shield := money(m.Collateral)
		if m.Collateral == 0 {
			if m.Defaulted {
				shield = "slashed"
			} else {
				shield = "returned"
			}
		}
		loot := "—"
		if m.Received {
			loot = "taken"
		}
		status := memberState(m, c)
		if m.Defaulted {
			status = "**defaulted**"
		}
		out += "| " + strconv.Itoa(i+1) + " | " + who(m.Addr) + " | " + shield + " | " + loot + " | " + status + " |\n"
	}
	return out
}

// memberState is the one status word both the ASCII and the Markdown table use.
func memberState(m *Member, c *Circle) string {
	switch {
	case m.Defaulted:
		return "DEFAULTED"
	case m.Received:
		return "loot taken"
	case c.Status == rosca.StatusActive && m.PaidRound < c.Round:
		return "must pay"
	case c.Status == rosca.StatusOpen:
		return "seated"
	}
	return "on track"
}

// roundsPaidBar is a member's HP: how many of their own rounds they have paid.
func roundsPaidBar(m *Member, c *Circle) string {
	total := c.RoundsPlanned()
	if total <= 0 {
		total = len(c.Members)
	}
	return rosca.Bar(m.RoundsPaid, total, 13)
}

// classFor gives every seat a stable arcade class, so a party reads like a
// party and not like a list of hashes.
func classFor(seat int) string {
	classes := []string{"Keeper", "Ranger", "Mage", "Bard", "Rogue", "Warden", "Smith", "Pilot"}
	return classes[seat%len(classes)]
}

func payoutList(c *Circle) string {
	out := ""
	n := len(c.Payouts)
	start := 0
	if n > 12 {
		start = n - 12
	}
	if start > 0 {
		out += ufmt.Sprintf("_showing the last 12 of %d entries_\n\n", n)
	}
	for i := start; i < n; i++ {
		py := c.Payouts[i]
		label := py.Kind
		switch py.Kind {
		case "pot":
			label = "LOOT round " + strconv.Itoa(py.Round+1)
		case "slash":
			label = "SHIELD SLASHED round " + strconv.Itoa(py.Round+1)
		case "refund":
			label = "SHIELD RETURNED"
		case "return":
			label = "ROUND REFUNDED"
		case "residual":
			label = "VAULT RESIDUAL"
		}
		out += ufmt.Sprintf("- `%s` · **%s** → %s · _%s_\n",
			label, money(py.Amount), who(py.To), py.At.Format("02 Jan 15:04"))
	}
	return out + "\n"
}

// actionMenu is the control pad. Context: a circle page (full menu) or the
// title screen (open/enter only).
func actionMenu(c *Circle, onPage bool) string {
	out := ""
	if c == nil || !onPage {
		out += "```\n"
		out += "   +---------------------------+   +---------------------------+\n"
		out += "   |  + NEW RUN                |   |  i  HOW TO PLAY           |\n"
		out += "   |  name, stake, seats, time |   |  the rules, in one page   |\n"
		out += "   +---------------------------+   +---------------------------+\n"
		out += "```\n\n"
		out += "**[+ NEW RUN](" + helpLink("Create") + ")** · [how to play](" + pkgPath + ":about)\n"
		if c != nil {
			out += "\n" + rulesLine(c)
		}
		return out
	}
	if c.Status == rosca.StatusComplete {
		if c.Cancelled {
			out += "_This run was cancelled; every shield was returned._\n"
		} else {
			out += "_Run cleared: every player took the loot once and shields came back._\n"
		}
		out += "\n**[+ NEW RUN](" + helpLink("Create") + ")** · " + rulesLine(c)
		return out
	}
	if c.Status == rosca.StatusOpen {
		out += ufmt.Sprintf("- **[+ JOIN THIS RUN](%s)** — locks %s as your shield\n", helpLink2("Join", "id", c.ID), money(c.Params.Collateral))
		out += ufmt.Sprintf("- [leave the run](%s) — refunds your shield\n", helpLink2("Leave", "id", c.ID))
		out += ufmt.Sprintf("- [cancel the run](%s) — creator only, refunds every seat\n", helpLink2("Cancel", "id", c.ID))
		out += "- " + rulesLine(c) + "\n"
		return out
	}
	out += ufmt.Sprintf("- **[>> PAY ROUND %d](%s)** — %s\n", c.Round+1, helpLink2("Contribute", "id", c.ID), money(c.Params.Contribution))
	if c.Remaining(time.Now()) <= 0 {
		out += ufmt.Sprintf("- **[settle defaults](%s)** — the timer has expired\n", helpLink2("Advance", "id", c.ID))
	} else {
		out += "- _settle defaults opens when this round's timer expires_\n"
	}
	out += "- " + rulesLine(c) + "\n"
	return out
}

func rulesLine(c *Circle) string {
	return "[rules and guarantees](" + pkgPath + ":circle/" + strconv.FormatUint(c.ID, 10) + "/rules)"
}

func renderRules(c *Circle) string {
	out := "# How run #" + strconv.FormatUint(c.ID, 10) + " settles\n\n"
	out += "This page is generated from the same code that runs the circle, not from a document someone edited after the fact.\n\n"
	out += "```\n"
	out += "   OPEN --> seat fills --> ACTIVE --> one pot per round --> CLEARED\n"
	out += "     |                        |\n"
	out += "     +-- cancel/refund        +-- miss the timer --> shield slashed\n"
	out += "```\n\n"
	out += "## The rotation\n\n"
	out += ufmt.Sprintf("1. **Join** locks %s of collateral — exactly one stake.\n", money(c.Params.Collateral))
	out += "2. When the last seat fills the run **activates**. The payout order is a Fisher-Yates shuffle seeded with `sha256(circle id | activation height | sorted member addresses)`, so the creator cannot pick who gets paid first and every node derives the same order.\n"
	out += ufmt.Sprintf("3. Each round every active player pays **%s**. The moment the last one pays, the pot of **%s** is sent to the next player in the order — one transaction, no keeper.\n",
		money(c.Params.Contribution), money(c.Params.Pot()))
	out += "4. When every active player has taken the loot once, the run closes: shields come back and the penalty fund is split evenly among the players who never defaulted.\n\n"
	out += "## Defaults\n\n"
	out += ufmt.Sprintf("- After the round timer expires, **anyone** can call `Advance`. Every active player who did not pay is marked in default and their %s shield moves to the penalty fund.\n", money(c.Params.Collateral))
	out += "- A defaulted player loses the seat, is skipped in the payout order, and gets no shield back.\n"
	out += "- The pot released is what was actually collected, so the realm never pays out money it does not hold.\n"
	out += "- If every seat defaults, or a round collects money with nobody left to pay, the pool is returned (to the players who paid it, or to the creator) rather than left in the vault — audited and covered by `TestAllDefaultStrandsPool` and `TestPotReturnedWhenNoBeneficiaryLeft`.\n\n"
	out += "## Why it balances\n\n"
	out += ufmt.Sprintf("A player pays one stake per round plus one shield, takes the pot once, and gets the shield back: net %s. The shield exists only to make a skipped round cost more than the round itself.\n\n", money(c.Params.NetPerMember()))
	out += "Every payout is subtracted from that circle's own pool before the transfer, and the realm panics if a payout would ever exceed it.\n"
	return out
}

func renderAbout() string {
	out := "# How Kolektif works\n\n"
	out += "```\n"
	out += "   +------------------------------------------------------+\n"
	out += "   |  A ROSCA (arisan, tanda, chit fund) is how most of   |\n"
	out += "   |  the world saves without a bank: a group agrees on   |\n"
	out += "   |  a fixed amount, everyone pays every round, and one  |\n"
	out += "   |  player takes the whole pot each round.               |\n"
	out += "   +------------------------------------------------------+\n"
	out += "```\n\n"
	out += "Kolektif puts that on Gno.land, where it finally has the two things a group of neighbours cannot give each other: an escrow nobody can walk away with, and a payout order nobody can argue about.\n\n"
	out += "## What the chain enforces\n\n"
	out += "- **Custody.** Contributions land on the realm address. A payout is a `banker.SendCoins` from the circle's own pool, checked before it is sent, so the realm cannot overpay.\n"
	out += "- **Order.** At activation the order is derived from the circle id, the activation height and the sorted member set. Change one member and the order changes; the creator has no lever.\n"
	out += "- **Missed rounds.** Collateral is slashed automatically by `Advance`, which anyone can call after the deadline. No admin decides who defaulted: the clock does.\n"
	out += "- **Balance.** With no defaults a player pays exactly what they receive. The penalty fund is the only thing that moves value between players, and it moves from defaulters to the honest.\n"
	out += "- **No stranded value.** A run that ends with nobody entitled (every seat defaulted, or a round with no player left to pay) returns the pool instead of leaving it in the realm.\n\n"
	out += "## Why a circle and not a loan\n\n"
	out += "There is no interest, no oracle, no collateral liquidation and no counterparty risk beyond the group: the pot is the group's own money, rotating. That is why ROSCAs survive in places with no credit infrastructure, and why they are a better first app for a chain than another AMM.\n\n"
	out += "## For builders\n\n"
	out += "The economics live in a pure package, `rosca`, that any realm can import: the payout schedule, the split of a penalty fund, the GNOT formatting, the progress bar. This realm is the reference implementation of that package, and the read-only API (`CircleSummary`, `IsMember`, `Standing`) lets another realm gate on membership without touching this realm's state.\n\n"
	out += "[Back to the arcade](" + pkgPath + ")\n"
	return out
}

func renderMember(a address) string {
	if !a.IsValid() {
		return notFound("member/" + a.String())
	}
	joined := 0
	paid := 0
	defaulted := 0
	loot := 0
	for _, c := range circles {
		m := c.Member(a)
		if m == nil {
			continue
		}
		joined++
		paid += m.RoundsPaid
		if m.Defaulted {
			defaulted++
		}
		if m.Received {
			loot++
		}
	}

	out := "# " + who(a) + "\n\n"
	out += "```\n"
	out += "   +-- PLAYER CARD -----------------------------------------+\n"
	out += "   |  " + pad(rosca.ShortAddr(a.String()), 54) + " |\n"
	out += "   |  RUNS " + pad(strconv.Itoa(joined), 4) + "  ROUNDS PAID " + pad(strconv.Itoa(paid), 6) + "  LOOT " + pad(strconv.Itoa(loot), 4) + "  BUSTED " + pad(strconv.Itoa(defaulted), 3) + " |\n"
	out += "   +" + strings.Repeat("-", 57) + "+\n"
	out += "```\n\n"
	out += "`" + a.String() + "`\n\n"

	if joined == 0 {
		out += "_No seat in any circle yet._\n\n"
		out += "[Back to the arcade](" + pkgPath + ")\n"
		return out
	}
	out += "## Seats\n\n| run | paid | shield | loot | status |\n| --- | --- | --- | --- | --- |\n"
	for _, c := range circles {
		m := c.Member(a)
		if m == nil {
			continue
		}
		status := "on track"
		if m.Defaulted {
			status = "**defaulted**"
		}
		lootMark := "—"
		if m.Received {
			lootMark = "taken"
		}
		out += ufmt.Sprintf("| [%s](%s:circle/%d) | %d | %s | %s | %s |\n",
			c.Name, pkgPath, c.ID, m.RoundsPaid, money(m.Collateral), lootMark, status)
	}
	out += "\n[Back to the arcade](" + pkgPath + ")\n"
	return out
}

// --- helpers -----------------------------------------------------------

func money(ugnot int64) string {
	return rosca.Gnot(ugnot) + " GNOT"
}

// who renders an address as a link to its page inside this realm. It
// deliberately does not import gno.land/r/sys/users: that realm's import
// closure drags in gov/dao, which makes the package expensive to verify on a
// chain that typechecks submissions off-chain before enabling them.
func who(a address) string {
	return "[`" + rosca.ShortAddr(a.String()) + "`](" + pkgPath + ":member/" + a.String() + ")"
}

func helpLink(fn string) string {
	return pkgPath + "$help&func=" + fn
}

func helpLink2(fn, key string, id uint64) string {
	return pkgPath + "$help&func=" + fn + "&" + key + "=" + strconv.FormatUint(id, 10)
}

func parseID(s string) uint64 {
	id, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0
	}
	return id
}

func notFound(path string) string {
	return "# Not found\n\nNo page for `" + path + "`.\n\n[Back to the arcade](" + pkgPath + ")\n"
}

// pad right-pads s to n bytes with spaces (ASCII frames assume a monospace
// font and a byte count, not a rune count).
func pad(s string, n int) string {
	if len(s) >= n {
		return s[:n]
	}
	return s + strings.Repeat(" ", n-len(s))
}

// center pads s to width n, centred.
func center(n int, s string) string {
	if len(s) >= n {
		return s[:n]
	}
	left := (n - len(s)) / 2
	return strings.Repeat(" ", left) + s + strings.Repeat(" ", n-len(s)-left)
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func createCLI() string {
	return "PKG=gno.land" + pkgPath + "\n\n" +
		"gnokey maketx call \\\n" +
		"  -pkgpath \"$PKG\" -func \"Create\" \\\n" +
		"  -args \"Warung Crew\" -args 1000000 \\\n" +
		"  -args 3 -args 300 \\\n" +
		"  -gas-fee 1000000ugnot -gas-wanted 50000000 \\\n" +
		"  -chainid onyx-1 \\\n" +
		"  -remote https://rpc.onyx.testnets.gno.land:443 chime"
}

func clientCLI(c *Circle) string {
	base := "PKG=gno.land" + pkgPath + "\n\n" +
		"gnokey maketx call \\\n" +
		"  -pkgpath \"$PKG\" -func \"Contribute\" \\\n" +
		"  -args " + strconv.FormatUint(c.ID, 10) + " \\\n" +
		"  -send \"" + strconv.FormatInt(c.Params.Contribution, 10) + "ugnot\" \\\n" +
		"  -gas-fee 1000000ugnot -gas-wanted 50000000 \\\n" +
		"  -chainid onyx-1 \\\n" +
		"  -remote https://rpc.onyx.testnets.gno.land:443 chime"
	return base
}
