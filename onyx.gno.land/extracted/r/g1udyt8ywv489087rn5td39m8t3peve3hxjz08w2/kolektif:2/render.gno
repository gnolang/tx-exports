package kolektif

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/kolektif/rosca"
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
	out += "**Rotating savings circles, on chain.** Gno.land's first ROSCA: a group locks "
	out += "the same contribution every round, one member takes the whole pot each round, "
	out += "and the payout order is fixed by chain state so nobody can rig it.\n\n"
	out += "> Three neighbours, 1 GNOT per round, three rounds: everyone pays 3 GNOT, everyone "
	out += "takes 3 GNOT home once, nobody needs a bank. Collateral makes skipping a round expensive.\n\n"

	out += ufmt.Sprintf("**%d circles** · **%d running** · **%s sitting in circle pools** · **%s moved through circles**\n\n",
		count, active, money(escrowed), money(paidOut))

	out += "## Take a seat\n\n"
	out += "- **Open a circle** — [transaction](" + helpLink("Create") + ") · arguments: name, contribution in ugnot, seats (3-50), round length in seconds\n"
	out += "- **Join an open circle** — [transaction](" + helpLink("Join") + ") · argument: id · locks exactly one contribution as collateral\n"
	out += "- **Pay a round** — [transaction](" + helpLink("Contribute") + ") · argument: id · releases the pot when the last member pays\n"
	out += "- **Settle a stalled round** — [transaction](" + helpLink("Advance") + ") · argument: id · only after the deadline, anyone may call it\n"
	out += "- **[How it works](" + pkgPath + ":about)** — collateral, defaults, payout order, and why it always balances\n\n"

	out += "---\n\n## Circles\n\n"
	if len(circles) == 0 {
		out += "_No circle yet. Open the first one._\n\n"
		out += "```sh\n" + createCLI() + "\n```\n"
		return out
	}
	for i := len(circles) - 1; i >= 0; i-- {
		out += renderCircleCard(circles[i])
	}
	return out
}

// renderCircleCard is one entry in the index list: enough state to decide
// whether the circle is worth a click.
func renderCircleCard(c *Circle) string {
	settled, planned := c.Progress()
	out := "### #" + strconv.FormatUint(c.ID, 10) + " · " + c.Name + " · **" + c.Status.String() + "**\n\n"
	out += ufmt.Sprintf("%s per round · %d seats · rounds last %s · full pot %s\n\n",
		money(c.Params.Contribution), c.Params.Size, rosca.HumanDuration(c.Params.RoundSpan), money(c.Params.Pot()))
	if c.Status == rosca.StatusOpen {
		out += ufmt.Sprintf("Seats %s %d/%d · waiting for members\n\n",
			rosca.Bar(c.Seats(), c.Params.Size, 14), c.Seats(), c.Params.Size)
	} else if c.Status == rosca.StatusActive {
		next := "nobody left"
		bi := c.NextBeneficiary()
		if bi >= 0 {
			next = who(c.Members[bi].Addr)
		}
		out += ufmt.Sprintf("Payouts %s %d/%d · next pot to %s\n\n",
			rosca.Bar(settled, planned, 14), settled, planned, next)
	} else {
		out += ufmt.Sprintf("Payouts %s %d/%d settled · closed %s · %s returned to members\n\n",
			rosca.Bar(settled, planned, 14), settled, planned, c.ClosedAt.Format("02 Jan 2006"), money(c.PaidOutTotal))
	}
	out += "[Enter circle](" + pkgPath + ":circle/" + strconv.FormatUint(c.ID, 10) + ")\n\n---\n\n"
	return out
}

func renderCirclePath(rest string) string {
	rest = strings.Trim(rest, "/")
	parts := strings.Split(rest, "/")
	id := parseID(parts[0])
	if id == 0 {
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
	out += ufmt.Sprintf("Circle #%d · created by %s on %s · status **%s**\n\n",
		c.ID, who(c.Creator), c.OpenedAt.Format("02 Jan 2006 15:04"), c.Status.String())

	out += ufmt.Sprintf("- Contribution: **%s per member per round**\n", money(c.Params.Contribution))
	out += ufmt.Sprintf("- Seats: **%d** (joined %d)\n", c.Params.Size, c.Seats())
	out += ufmt.Sprintf("- Round length: **%s**\n", rosca.HumanDuration(c.Params.RoundSpan))
	out += ufmt.Sprintf("- Collateral per seat: **%s**, returned when the circle closes\n\n", money(c.Params.Collateral))

	switch c.Status {
	case rosca.StatusOpen:
		out += openBody(c)
	case rosca.StatusActive:
		out += activeBody(c, now)
	case rosca.StatusComplete:
		out += completeBody(c)
	}

	out += "\n---\n\n## Members\n\n"
	out += memberTable(c)

	if len(c.Payouts) > 0 {
		out += "\n## Activity\n\n"
		out += payoutList(c)
	}

	out += "\n## Actions\n\n"
	out += actionLinks(c)
	out += "\n## Client\n\n```sh\n" + clientCLI(c) + "\n```\n"
	out += "\n_Secrets of the schedule: seed `" + c.Seed + "`_\n"
	return out
}

func openBody(c *Circle) string {
	seats := c.Seats()
	out := "\n"
	out += ufmt.Sprintf("**Collecting members** %s %d/%d\n\n", rosca.Bar(seats, c.Params.Size, 12), seats, c.Params.Size)
	out += ufmt.Sprintf("The circle activates automatically when the last seat is taken. Pot at activation: **%s**.\n\n",
		money(c.Params.Pot()))
	out += ufmt.Sprintf("[Join with %s collateral](%s) · [Leave and take collateral back](%s) · [Cancel circle](%s)\n",
		money(c.Params.Collateral), helpLink2("Join", "id", c.ID), helpLink2("Leave", "id", c.ID), helpLink2("Cancel", "id", c.ID))
	if seats >= c.Params.Size {
		out += "\n_Circle is full: activation happens on the next join attempt or page render cycle._\n"
	}
	return out
}

func activeBody(c *Circle, now time.Time) string {
	settled, planned := c.Progress()
	out := "\n"
	out += ufmt.Sprintf("**Rounds** %s %d/%d settled · now paying round **%d**\n\n",
		rosca.Bar(settled, planned, 12), settled, planned, c.Round+1)

	bi := c.NextBeneficiary()
	if bi >= 0 {
		out += ufmt.Sprintf("**Pot due this round:** %s → released to %s when the last member pays\n\n",
			money(c.Params.Pot()), who(c.Members[bi].Addr))
	}

	rem := c.Remaining(now)
	if rem > 0 {
		out += ufmt.Sprintf("**Deadline:** %s (in %s) · block time %s\n\n",
			c.Deadline.Format("02 Jan 2006 15:04"), rosca.HumanDuration(rem), now.Format("02 Jan 2006 15:04"))
	} else {
		out += ufmt.Sprintf("**Deadline passed** %s ago · anyone may settle the round\n\n", rosca.HumanDuration(-rem))
	}

	paid := 0
	for _, m := range c.Members {
		if !m.Defaulted && m.PaidRound >= c.Round {
			paid++
		}
	}
	out += ufmt.Sprintf("**Paid this round:** %d of %d active members %s\n\n", paid, c.Active(), rosca.Bar(paid, c.Active(), 12))
	out += ufmt.Sprintf("[Pay %s now](%s)", money(c.Params.Contribution), helpLink2("Contribute", "id", c.ID))
	if rem <= 0 {
		out += ufmt.Sprintf(" · [Settle defaults](%s)\n", helpLink2("Advance", "id", c.ID))
	} else {
		out += " · _settling opens when the deadline passes_\n"
	}
	return out
}

func completeBody(c *Circle) string {
	out := "\n"
	if c.Cancelled {
		out += "**Circle cancelled.** Every seat was refunded; nothing was ever paid out as a pot.\n\n"
		return out
	}
	tmpl := "**Circle complete** on %s. Every member received the pot once, collateral came back, and the penalty fund was shared among honest members.\n\n"
	out += ufmt.Sprintf(tmpl, c.ClosedAt.Format("02 Jan 2006 15:04"))
	out += ufmt.Sprintf("Paid in %s · paid out %s · residual in realm %s\n\n",
		money(c.PaidInTotal), money(c.PaidOutTotal), money(c.Pool))
	return out
}

func memberTable(c *Circle) string {
	out := "| seat | member | paid rounds | collateral | pot received | status |\n"
	out += "| --- | --- | --- | --- | --- | --- |\n"
	for i, m := range c.Members {
		status := "on track"
		if m.Defaulted {
			status = "**defaulted**"
		} else if m.Received {
			status = "**paid out**"
		} else if c.Status == rosca.StatusActive && m.PaidRound < c.Round {
			status = "pending this round"
		}
		got := "—"
		if m.Received {
			got = "yes"
		}
		collat := money(m.Collateral)
		if m.Collateral == 0 {
			if m.Defaulted {
				collat = "slashed"
			} else {
				collat = "returned"
			}
		}
		out += ufmt.Sprintf("| %d | %s | %d | %s | %s | %s |\n",
			i+1, who(m.Addr), m.RoundsPaid, collat, got, status)
	}
	return out
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
			label = "pot, round " + strconv.Itoa(py.Round+1)
		case "slash":
			label = "collateral slashed, round " + strconv.Itoa(py.Round+1)
		case "refund":
			label = "refund"
		}
		out += ufmt.Sprintf("- %s · **%s** → %s · _%s_\n",
			label, money(py.Amount), who(py.To), py.At.Format("02 Jan 15:04"))
	}
	return out + "\n"
}

func actionLinks(c *Circle) string {
	out := ""
	if c.Status == rosca.StatusComplete {
		if c.Cancelled {
			out += "_This circle was cancelled; every seat was refunded. Nothing left to do._\n"
		} else {
			out += "_This circle is closed: every member received the pot once and collateral came back. Nothing left to do._\n"
		}
		out += ufmt.Sprintf("\n[Start a new circle](%s) · [Rules and guarantees](%s:circle/%d/rules)\n", helpLink("Create"), pkgPath, c.ID)
		return out
	}
	if c.Status == rosca.StatusOpen {
		out += ufmt.Sprintf("- [Join this circle](%s) — locks %s\n", helpLink2("Join", "id", c.ID), money(c.Params.Collateral))
		out += ufmt.Sprintf("- [Leave this circle](%s) — refunds your collateral\n", helpLink2("Leave", "id", c.ID))
		out += ufmt.Sprintf("- [Cancel this circle](%s) — creator only, refunds every seat\n", helpLink2("Cancel", "id", c.ID))
		return out
	}
	out += ufmt.Sprintf("- [Pay %s for round %d](%s)\n", money(c.Params.Contribution), c.Round+1, helpLink2("Contribute", "id", c.ID))
	if c.Remaining(time.Now()) <= 0 {
		out += ufmt.Sprintf("- [Settle defaults](%s) — the deadline has passed\n", helpLink2("Advance", "id", c.ID))
	} else {
		out += "- _Settle defaults opens when this round's deadline passes_\n"
	}
	out += ufmt.Sprintf("- [Rules and guarantees](%s:circle/%d/rules)\n", pkgPath, c.ID)
	return out
}

func renderRules(c *Circle) string {
	out := "# How circle #" + strconv.FormatUint(c.ID, 10) + " settles\n\n"
	out += "This page is generated from the same code that runs the circle, not from a document "
	out += "someone edited after the fact.\n\n"
	out += "## The rotation\n\n"
	out += ufmt.Sprintf("1. **Join** locks %s of collateral, exactly one contribution.\n", money(c.Params.Collateral))
	out += "2. When the last seat fills, the circle **activates**. The payout order is a Fisher-Yates "
	out += "shuffle seeded with `sha256(circle id | activation height | sorted member addresses)`, so the "
	out += "creator cannot pick who gets paid first and every node derives the same order.\n"
	tmpl := "3. Each round, every active member pays **%s**. The moment the last one pays, the pot of **%s** is sent to the next member in the order — one transaction, no keeper.\n"
	out += ufmt.Sprintf(tmpl, money(c.Params.Contribution), money(c.Params.Pot()))
	out += "4. When every active member has received the pot once, the circle closes: collateral is returned "
	out += "and the penalty fund is split evenly among the members who never defaulted.\n\n"
	out += "## Defaults\n\n"
	tmplD := "- After the round deadline, **anyone** can call `Advance`. Every active member who did not pay is marked in default and their %s collateral moves to the penalty fund.\n"
	out += ufmt.Sprintf(tmplD, money(c.Params.Collateral))
	out += "- A defaulted member loses the seat, is skipped in the payout order, and gets no refund.\n"
	out += "- The pot released is what was actually collected, so the realm never pays out money it does not hold.\n\n"
	out += "## Why it balances\n\n"
	tmplB := "A member pays one contribution per round plus one collateral, receives the pot once, and gets the collateral back: net %s. Collateral exists only to make a skipped round cost more than the round itself.\n\n"
	out += ufmt.Sprintf(tmplB, money(c.Params.NetPerMember()))
	out += "Every payout is subtracted from that circle's own pool before the transfer, and the realm "
	out += "panics if a payout would ever exceed it.\n"
	return out
}

func renderAbout() string {
	out := "# How Kolektif works\n\n"
	out += "A ROSCA (rotating savings and credit association) is how most of the world saves without a bank: "
	out += "a group agrees on a fixed amount, everyone pays it every round, and each round one member takes "
	out += "the whole pot. Repeat until everyone has had a turn.\n\n"
	out += "Kolektif puts that on Gno.land, where it finally has the two things a group of neighbours cannot "
	out += "give each other: an escrow that nobody can walk away with, and a payout order nobody can argue about.\n\n"
	out += "## What the chain enforces\n\n"
	out += "- **Custody.** Contributions land on the realm address. A payout is a `banker.SendCoins` from the "
	out += "circle's own pool, checked before it is sent, so the realm cannot overpay.\n"
	out += "- **Order.** At activation the order is derived from the circle id, the activation height and the "
	out += "sorted member set. Change one member and the order changes; the creator has no lever.\n"
	out += "- **Missed rounds.** Collateral is slashed automatically by `Advance`, which anyone can call after "
	out += "the deadline. No admin decides who defaulted: the clock does.\n"
	out += "- **Balance.** With no defaults a member pays exactly what they receive. The penalty fund is the "
	out += "only thing that moves value between members, and it moves from defaulters to the honest.\n\n"
	out += "## Why a circle and not a loan\n\n"
	out += "There is no interest, no oracle, no collateral liquidation and no counterparty risk beyond the "
	out += "group: the pot is the group's own money, rotating. That is why ROSCAs survive in places with no "
	out += "credit infrastructure, and why they are a better first app for a chain than another AMM.\n\n"
	out += "## For builders\n\n"
	out += "The economics live in a pure package, `rosca`, that any realm can import: the payout schedule, "
	out += "the split of a penalty fund, the GNOT formatting, the progress bar. This realm is the reference "
	out += "implementation of that package, and the read-only API (`CircleSummary`, `IsMember`, `Standing`) "
	out += "lets another realm gate on membership without touching this realm's state.\n\n"
	out += "[Back to the circles](" + pkgPath + ")\n"
	return out
}

func renderMember(a address) string {
	if !a.IsValid() {
		return notFound("member/" + a.String())
	}
	out := "# " + who(a) + "\n\n"
	out += "`" + a.String() + "`\n\n"

	found := false
	for _, c := range circles {
		m := c.Member(a)
		if m == nil {
			continue
		}
		if !found {
			out += "## Seats\n\n| circle | paid | collateral | pot | status |\n| --- | --- | --- | --- | --- |\n"
			found = true
		}
		status := "on track"
		if m.Defaulted {
			status = "**defaulted**"
		}
		pot := "—"
		if m.Received {
			pot = "received"
		}
		out += ufmt.Sprintf("| [%s](%s:circle/%d) | %d | %s | %s | %s |\n",
			c.Name, pkgPath, c.ID, m.RoundsPaid, money(m.Collateral), pot, status)
	}
	if !found {
		out += "_No seat in any circle yet._\n"
	}
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
	return "# Not found\n\nNo page for `" + path + "`.\n\n[Back to the circles](" + pkgPath + ")\n"
}

func createCLI() string {
	return "gnokey maketx call -pkgpath \"gno.land" + pkgPath + "\" \\\n" +
		"  -func \"Create\" -args \"Warung Crew\" -args 1000000 -args 3 -args 300 \\\n" +
		"  -gas-fee 1000000ugnot -gas-wanted 50000000 \\\n" +
		"  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 chime"
}

func clientCLI(c *Circle) string {
	base := "gnokey maketx call -pkgpath \"gno.land" + pkgPath + "\" \\\n  -func \"Contribute\" -args " + strconv.FormatUint(c.ID, 10) + " \\\n" +
		"  -send \"" + strconv.FormatInt(c.Params.Contribution, 10) + "ugnot\" \\\n" +
		"  -gas-fee 1000000ugnot -gas-wanted 50000000 \\\n" +
		"  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 chime"
	return base
}
