package cutpurse

// render_job.gno — the job. Pot, alarm, seats, and exactly one control panel
// for the phase the job is in. Every panel says what the button does to
// your money before you press it.

import (
	"strconv"
	"strings"
)

// renderJobPath routes job/<id>, job/<id>/<you>, and the commit and reveal
// steps under them. j/<id> is the same page.
func renderJobPath(parts []string) string {
	if len(parts) < 2 {
		return renderMissing("job")
	}
	id := atoiOr(parts[1], -1)
	if id < 0 {
		return renderMissing(text(parts[1]))
	}
	at := 2
	you := ""
	if len(parts) > 2 && address(parts[2]).IsValid() {
		you = parts[2]
		at = 3
	}
	if len(parts) <= at {
		parts = append(parts, "")
	}
	rest := parts[at:]
	jv, ok := jobView(id)
	if !ok {
		return pageHead("No such job", "Nothing has been opened under "+
			"`"+strconv.FormatInt(id, 10)+"`.", "Home", hub) +
			notice("WARNING", "Job not found", "") +
			"Try " + md("the board", self("jobs")) + ".\n"
	}
	switch {
	case rest[0] == "":
		return renderJob(jv, you)
	case rest[0] == "commit" && len(rest) == 1:
		return renderCommitChoose(jv, you)
	case rest[0] == "commit":
		return renderCommitHash(jv, you, uint8(atoiOr(rest[1], 1)))
	case rest[0] == "reveal":
		return renderReveal(jv, you)
	}
	return renderJob(jv, you)
}

// ----- the job page -----

func renderJob(jv JobView, you string) string {
	var b strings.Builder
	b.WriteString(pageHeadBare(jobTitle(jv),
		"Job "+strconv.FormatInt(jv.ID, 10)+" · "+phaseBadge(jv.Phase)+roundLabel(jv)))

	if jv.Phase >= uint8(PhaseSettled) {
		b.WriteString(endBody(jv, you))
		return b.String()
	}

	// The numbers a player judges, in one line while the round is running —
	// three picture cards are wasted gas there. Cards stay on the open page,
	// where the join decision is the whole screen.
	if jv.Phase == 0 {
		b.WriteString(cards(
			"**Pot**\n\n"+coins(jv.Pot)+"\n\nSeat fee "+money(jv.Fee)+" GNOT",
			"**Seats**\n\n"+seatStrip(int64(jv.NSeats))+"\n\n"+
				strconv.FormatInt(int64(jv.NSeats), 10)+" of 4 filled",
			"**Clock**\n\n"+clockCell(jv)+"\n\nOn alarm "+alarmMeter(jv.Alarm),
		))
		b.WriteString("\n")
	} else {
		b.WriteString(jobFacts(jv))
		b.WriteString(phaseBanner(jv))
	}

	b.WriteString(traitorPanel(jv))
	b.WriteString(seatTable(jv, you))
	arch, settled := Archived(jv.ID)
	b.WriteString(controlPanel(jv, you, settled, arch))
	b.WriteString(nav("The board", self("jobs"), "Home", self("")))
	return b.String()
}

// jobFacts is the one-line state of a running job: pot, fee, seats, clock,
// alarm. Cheaper than three cards and hard to read past, which is what a
// player in a timed round wants.
func jobFacts(jv JobView) string {
	return "Round " + strconv.FormatInt(int64(jv.Round), 10) + "/3 · pot " + coins(jv.Pot) +
		" · " + seatStrip(int64(jv.NSeats)) + " " +
		strconv.FormatInt(int64(jv.NSeats), 10) + "/4 · " + clockCell(jv) + " · " +
		alarmBars(jv.Alarm) + " · " + money(jv.Secured) + " GNOT secured\n\n"
}

// ----- the two end states -----

// endBody is the job after the last round: verdict, then the money, then who
// took what. The three grey cards go away here — the verdict is the number.
func endBody(jv JobView, you string) string {
	var b strings.Builder
	b.WriteString(endVerdict(jv))
	b.WriteString(takeCards(jv))
	b.WriteString(scoreboard(jv, you))
	arch, _ := Archived(jv.ID)
	b.WriteString(controlPanel(jv, you, jv.Settled, arch))
	b.WriteString(nav("The board", self("jobs"), "Every settled job", self("ledger")))
	return b.String()
}

// endVerdict is the loudest block on the site: who did it, and what it cost.
// Money is written plainly here — coins() already bolds, and bolding a bold
// reads as a mistake.
func endVerdict(jv JobView) string {
	snitch, _, snitchPaid := snitchFacts(jv)
	if jv.Alarm >= alarmTotal {
		// Heading, then exactly one sentence of explanation, then the cost.
		// A stranger has to get the mechanic from that sentence alone.
		body := "### 🐀 Busted\n\n"
		if snitch >= 0 {
			body += "**Seat " + strconv.FormatInt(int64(snitch)+1, 10) + " was the snitch.** " +
				payoffLine(jv, snitch, snitchPaid) + " They walk.\n\n"
		} else {
			body += "The door slammed at round " + strconv.FormatInt(int64(jv.Round), 10) + ".\n\n"
		}
		if jv.Secured == 0 {
			body += "**Nothing reached the door.** " + money(bustedLost(jv)) +
				" GNOT stayed on the shelf of a " + money(jv.Pot) + " GNOT pot.\n"
		} else {
			body += "What reached the door survives: **" + money(jv.Secured) + " GNOT**. " +
				money(bustedLost(jv)) + " GNOT stayed on the shelf.\n"
		}
		return frame(body) + "\n"
	}

	body := "### Escaped\n\n"
	if snitch >= 0 {
		body += "**Seat " + strconv.FormatInt(int64(snitch)+1, 10) + " was the snitch** — and got " +
			"away with it: on an escape they take nothing extra, the same share as everyone.\n\n"
	}
	if jv.Secured == 0 {
		body += "Three rounds cleared and the alarm never reached 3, but nothing was carried " +
			"out — the pot still splits.\n\n"
	} else {
		body += "Three rounds cleared, alarm never reached 3. **" + money(jv.Secured) +
			" GNOT** walked out the door.\n\n"
	}
	body += "The remainder split by contribution below. It could have been worse.\n"
	return frame(body) + "\n"
}

// payoffLine is the snitch's payoff in one sentence, pitched at someone who has
// never played. The contrast does the teaching: the 60% is only outrageous when
// it is set against what that seat actually did.
func payoffLine(jv JobView, seat int, paid int64) string {
	shares := payoutShares(jv)
	rank, didLeast := 1, true
	for i := range jv.Seats {
		if i == seat {
			continue
		}
		if shares[i] >= shares[seat] {
			rank++
		}
		if jv.Seats[i].Contribution < jv.Seats[seat].Contribution {
			didLeast = false
		}
	}
	amount := money(paid) + " GNOT"
	switch {
	case rank == 1 && didLeast:
		return "A bust pays the snitch 60% of the pot: " + amount +
			", taken before the crew is paid, from the seat that did the least."
	case rank == 1:
		return "A bust pays the snitch 60% of the pot: " + amount +
			", before the crew is paid — more than any seat that worked for it."
	case didLeast:
		return "A bust pays the snitch 60% of the pot: " + amount +
			", before the crew is paid, more than the seat that did most."
	}
	return "A bust pays the snitch 60% of the pot: " + amount + ", before the crew is paid at all."
}

// bustedLost is loot that never reached the door.
func bustedLost(jv JobView) int64 {
	if jv.Loot <= jv.Secured {
		return 0
	}
	return jv.Loot - jv.Secured
}

// takeCards is the money, split into the three places it went. On a bust the
// 60% is the story; on an escape the treasury cut is, because the snitch took
// nothing extra there.
func takeCards(jv JobView) string {
	shares := payoutShares(jv)
	if jv.Alarm >= alarmTotal {
		var snitchGet, crewGet int64
		for i, v := range shares {
			if i == int(jv.Traitor) {
				snitchGet += v
				continue
			}
			crewGet += v
		}
		return cards(
			"**The pot**\n\n"+coins(jv.Pot)+"\n\nthe whole stake",
			"**To the snitch**\n\n"+coins(snitchGet)+"\n\n60%, plus their split",
			"**To the crew**\n\n"+coins(crewGet)+"\n\nwhat is left",
		) + "\n"
	}

	var split int64
	for _, v := range shares {
		split += v
	}
	return cards(
		"**The pot**\n\n"+coins(jv.Pot)+"\n\nthe whole stake",
		"**To the treasury**\n\n"+coins(treasuryCut(jv))+"\n\n5%, scaled by what was secured",
		"**Split by contribution**\n\n"+coins(split)+"\n\nbetween all seats",
	) + "\n"
}

// scoreboard ranks the crew by what they took. The snitch is first, because
// the pot always pays them most — that is the point of the game.
func scoreboard(jv JobView, you string) string {
	shares := payoutShares(jv)
	order := make([]int, len(jv.Seats))
	for i := range order {
		order[i] = i
	}
	for i := 1; i < len(order); i++ {
		for k := i; k > 0 && shares[order[k]] > shares[order[k-1]]; k-- {
			order[k], order[k-1] = order[k-1], order[k]
		}
	}

	var b strings.Builder
	b.WriteString("## What everyone took\n\n")
	b.WriteString("| Seat | Player | Pick | Contribution | Took |\n|---:|---|---|---:|---:|\n")
	for _, i := range order {
		seat := jv.Seats[i]
		mark := ""
		if i == int(jv.Traitor) {
			mark = " 🐀"
		}
		pick := actionCell(seat.Action)
		if seat.Auto {
			pick += " `auto`"
		}
		b.WriteString("| " + strconv.Itoa(i+1) + mark + " | " + who(seat.Addr.String()) +
			youMark(seat.Addr.String(), you) + " | " + pick + " | " +
			strconv.FormatInt(seat.Contribution, 10) + " | **" + money(shares[i]) + "** |\n")
	}
	b.WriteString("\nPaid by contribution, remainder to the top contributor. ")
	if jv.Traitor >= 0 {
		b.WriteString("The 🐀 seat is the snitch.")
	}
	b.WriteString("\n\n")
	return b.String()
}

// snitchFacts is the snitch seat, how to describe them, and what they take.
func snitchFacts(jv JobView) (seat int, where string, paid int64) {
	seat = int(jv.Traitor)
	if seat < 0 || seat >= len(jv.Seats) {
		return -1, "", 0
	}
	where = "sealed at the close of round one"
	if jv.Round > 1 {
		where = "the crew never suspected"
	}
	if jv.Alarm >= alarmTotal {
		paid = jv.Pot * TraitorBustShare / 100
	}
	return seat, where, paid
}

// phaseBanner is only for the deadline running out. The round facts live in the
// one-line jobFacts above it; a second block repeating them is gas for nothing.
func phaseBanner(jv JobView) string {
	if jv.Deadline > jv.Height {
		return ""
	}
	return notice("CAUTION", "Deadline passed — nudge the clock",
		"The next phase is one Tick away. Anyone can send it and it pays nothing.")
}

// traitorPanel holds the snitch shut until the end states name them.
func traitorPanel(jv JobView) string {
	if jv.Round < 1 {
		return ""
	}
	return "🐀 **The snitch is among you** " + segLocked + " " + segLocked + " " + segLocked + " " +
		segLocked + "\n\n" +
		"One seat is on the take. A bust pays it 60% of the pot; a clean escape pays it nothing " +
		"extra — so the snitch wants the alarm, and you cannot see who does. Sealed from round " +
		"one out of every commit hash, and nobody sets it.\n\n"
}

// seatTable is the crew, in seat order.
func seatTable(jv JobView, you string) string {
	var b strings.Builder
	b.WriteString("## The crew\n\n")
	if len(jv.Seats) == 0 {
		b.WriteString(notice("NOTE", "Empty cellar. No one has taken a seat.", "") + "\n")
		return b.String()
	}
	b.WriteString("| Seat | Player | This round | Contribution |\n|---:|---|---|---:|\n")
	for i, seat := range jv.Seats {
		b.WriteString("| " + strconv.Itoa(i+1) + " | " + who(seat.Addr.String()) + youMark(seat.Addr.String(), you) +
			" | " + seatState(jv, seat) + " | " + strconv.FormatInt(seat.Contribution, 10) + " |\n")
	}
	b.WriteString("\nContribution is what the payout splits by. " + md("How that works", self("rules")) + ".\n\n")
	return b.String()
}

// seatState never leaks a pick before the reveal.
func seatState(jv JobView, seat SeatView) string {
	if jv.Revealed && seat.Revealed {
		s := actionCell(seat.Action)
		if seat.Auto {
			s += " `auto`"
		}
		return s
	}
	if seat.Committed {
		return icon("lock", "committed")
	}
	if jv.Phase == 1 || jv.Phase == 2 {
		return "▪"
	}
	return "—"
}

// roundLabel is the round in a page header; an open job has none yet.
func roundLabel(jv JobView) string {
	if jv.Phase == 0 || jv.Round == 0 {
		return " · seats filling"
	}
	return " · round " + strconv.FormatInt(int64(jv.Round), 10) + "/" +
		strconv.FormatInt(Rounds, 10)
}

// ----- controls -----

func controlPanel(jv JobView, you string, settled bool, arch Result) string {
	var b strings.Builder
	b.WriteString("## " + panelTitle(jv) + "\n\n")
	switch {
	case jv.Phase == 0:
		b.WriteString(joinPanel(jv))
		b.WriteString(kickPanel(jv))
		b.WriteString(startPanel(jv))
	case jv.Phase == 1:
		b.WriteString("Your pick stays hidden: the page hashes it and signs only the hash. " +
			"Keep the salt it hands back — without it the pick cannot be revealed.\n\n")
		b.WriteString(stepButtons(jv, you, "Commit your pick", "commit/"))
	case jv.Phase == 2:
		b.WriteString(notice("CAUTION", "Reveal or lose the pick",
			"An unrevealed pick counts as "+actionCell(4)+", earns nothing and costs a reputation point."))
		b.WriteString(stepButtons(jv, you, "Reveal", "reveal"))
	case jv.Phase >= 3:
		b.WriteString(settlePanel(jv, settled, arch))
	}
	b.WriteString(tickPanel(jv))
	return b.String()
}

func panelTitle(jv JobView) string {
	switch jv.Phase {
	case 1:
		return "Your pick"
	case 2:
		return "Reveal"
	case 3, 4:
		if jv.Settled {
			return "Settled"
		}
		return "The pot"
	}
	return "Take a seat"
}

// seatLink is the viewer's own view of the job, so a form can name its seat.
func seatLink(jv JobView, you, suffix string) string {
	p := "job/" + strconv.FormatInt(jv.ID, 10) + "/"
	if you != "" {
		p += you + "/"
	}
	return self(p + suffix)
}

// stepButtons sends the viewer to the commit chooser or the reveal form.
func stepButtons(jv JobView, you string, label, sub string) string {
	if jv.Deadline <= jv.Height {
		return "Deadline passed — " + md("Tick it first", seatLink(jv, you, "")) + ".\n\n"
	}
	b := button(label, seatLink(jv, you, sub), "")
	if you == "" {
		b += "\n\n" + md("Open your own seat view", seatLink(jv, you, "")) +
			" first if the next page cannot find your seat — it reads your address from the URL."
	}
	return b + "\n\n"
}

// joinPanel is the join form, or why you cannot join.
func joinPanel(jv JobView) string {
	var b strings.Builder
	if int(jv.NSeats) >= seatTotal {
		b.WriteString(notice("NOTE", "Full. Four seats, all taken.", "Watch this page: a kick frees one."))
		return b.String()
	}
	b.WriteString("Joining puts up " + coins(jv.Fee) + " of your own, into escrow. " +
		"A seat you take is seat " + strconv.FormatInt(int64(jv.NSeats)+1, 10) + ".\n\n")
	b.WriteString("<gno-form exec=\"JoinJob\">\n")
	b.WriteString(readonlyField("id", "Job", strconv.FormatInt(jv.ID, 10)))
	b.WriteString("</gno-form>\n\n")
	return b.String()
}

// kickPanel lets only the creator prune seats while the job is open.
func kickPanel(jv JobView) string {
	if jv.Phase != 0 || len(jv.Seats) < 2 {
		return ""
	}
	var b strings.Builder
	b.WriteString("<gno-form exec=\"Kick\">\n")
	b.WriteString(readonlyField("id", "Job", strconv.FormatInt(jv.ID, 10)))
	for i, seat := range jv.Seats {
		b.WriteString(selectOpt("seat", strconv.Itoa(i), short(seat.Addr.String()), i == len(jv.Seats)-1))
	}
	b.WriteString("</gno-form>\n\n")
	b.WriteString("_Creator only. A kicked seat is refunded in full, immediately._\n\n")
	return b.String()
}

// startPanel is the creator's go signal, once two seats are filled.
func startPanel(jv JobView) string {
	if int(jv.NSeats) < 2 {
		return notice("NOTE", "One player is not a job",
			"Seats fill for now. Send this page's link to a second wallet; Start appears at two.")
	}
	var b strings.Builder
	b.WriteString("<gno-form exec=\"Start\">\n")
	b.WriteString(readonlyField("id", "Job", strconv.FormatInt(jv.ID, 10)))
	b.WriteString("</gno-form>\n\n")
	b.WriteString("_Creator only. This closes the seats and opens round one. Empty seats stay empty._\n\n")
	return b.String()
}

// settlePanel is the permissionless settle, plus the split it will pay. Once
// the job is archived the form and the summary both go: the receipt replaces
// them, and a second send would only panic.
func settlePanel(jv JobView, settled bool, arch Result) string {
	var b strings.Builder
	if settled {
		b.WriteString(notice("SUCCESS", "Settled in block "+strconv.FormatInt(arch.At, 10),
			"Settled once, permanently — the pot cannot move again. "+
				md("Entry "+strconv.FormatInt(jv.ID, 10), self("ledger/1"))+" is the record."))
		if arch.Payouts != "" {
			b.WriteString("The realm logged the send: `" + arch.Payouts + "`\n\n")
		}
		return b.String()
	}

	if jv.Alarm >= alarmTotal {
		b.WriteString("Pot " + coins(jv.Pot) + " · 60% to the snitch · the rest by contribution.\n\n")
	} else {
		b.WriteString("Pot " + coins(jv.Pot) + " · " + money(treasuryCut(jv)) +
			" GNOT to the treasury (5%) · the rest by contribution.\n\n")
	}
	b.WriteString("<gno-form exec=\"Settle\">\n")
	b.WriteString(readonlyField("id", "Job", strconv.FormatInt(jv.ID, 10)))
	b.WriteString("</gno-form>\n\n")
	b.WriteString("_The pot is still here. Anyone may settle, once._\n\n")
	return b.String()
}

// tickPanel is the clock nudge, shown whenever a deadline has passed.
func tickPanel(jv JobView) string {
	if jv.Phase == 0 || jv.Phase >= 3 || jv.Deadline > jv.Height {
		return ""
	}
	var b strings.Builder
	b.WriteString("### The clock stopped\n\n")
	b.WriteString("<gno-form exec=\"Tick\">\n")
	b.WriteString(readonlyField("id", "Job", strconv.FormatInt(jv.ID, 10)))
	b.WriteString("</gno-form>\n\n")
	b.WriteString("_Permissionless. Carries the job to its next phase and pays nothing._\n\n")
	return b.String()
}

// payoutShares mirrors Settle exactly — same pool, same order of operations,
// same remainder rule — because a preview that disagrees with the chain is a
// lie on a page whose whole purpose is trust. The pool is the POT on both
// outcomes; a bust reserves 60% for the snitch, an escape a scaled 5% for the
// treasury. Returns all-zero when the realm would pay nothing.
func payoutShares(jv JobView) []int64 {
	shares := make([]int64, len(jv.Seats))
	if len(shares) == 0 || jv.Pot <= 0 {
		return shares
	}
	if jv.Alarm >= alarmTotal {
		share := jv.Pot * TraitorBustShare / 100
		if int(jv.Traitor) >= 0 && int(jv.Traitor) < len(shares) {
			shares[int(jv.Traitor)] = share
			splitShares(jv, jv.Pot-share, shares)
		} else {
			splitShares(jv, jv.Pot, shares)
		}
		return shares
	}
	splitShares(jv, jv.Pot-treasuryCut(jv), shares)
	return shares
}

// treasuryCut is the escape cut exactly as Settle computes it: Secured scaled
// against the best possible secure, so 5% of the pot is 5% of the pot.
func treasuryCut(jv JobView) int64 {
	if jv.Pot <= 0 {
		return 0
	}
	cut := jv.Pot * jv.Secured * TreasuryBps / (10000 * MaxSecured)
	if cut > jv.Pot {
		return jv.Pot
	}
	return cut
}

// splitShares is splitByContribution over a view: contribution-weighted, the
// remainder to the top contributor, an even split when nobody contributed.
func splitShares(jv JobView, amount int64, shares []int64) {
	n := len(shares)
	if amount <= 0 || n == 0 {
		return
	}
	var total int64
	top := 0
	for i := 0; i < n; i++ {
		c := jv.Seats[i].Contribution
		if c < 0 {
			c = 0
		}
		total += c
		if c > jv.Seats[top].Contribution {
			top = i
		}
	}
	if total == 0 {
		each := amount / int64(n)
		for i := 0; i < n; i++ {
			shares[i] += each
		}
		shares[0] += amount - each*int64(n)
		return
	}
	var given int64
	for i := 0; i < n; i++ {
		c := jv.Seats[i].Contribution
		if c < 0 {
			c = 0
		}
		part := amount * c / total
		shares[i] += part
		given += part
	}
	if rest := amount - given; rest > 0 {
		shares[top] += rest
	}
}

// ----- commit -----

func renderCommitChoose(jv JobView, you string) string {
	var b strings.Builder
	b.WriteString(pageHead("Commit your pick", jobTitle(jv)+" · round "+
		strconv.FormatInt(int64(jv.Round), 10), "The job", jobLink(jv.ID)))
	if jv.Phase != 1 {
		b.WriteString(notice("WARNING", "Not committing any more", "This job is "+phaseName(jv.Phase)+"."))
		return b.String() + nav("The job", jobLink(jv.ID))
	}
	b.WriteString("Pick one. The next page hashes it and hands you the exact value to sign — " +
		"the hash is public, the pick is not. You can change nothing after signing.\n\n")
	for _, a := range []uint8{1, 2, 3, 4} {
		b.WriteString("### " + actionGlyph(a) + " " + actionName(a) + "\n" + actionBlurb(a) + "\n\n")
		b.WriteString(button("Take "+actionName(a), seatLink(jv, you, "commit/"+strconv.Itoa(int(a))), "outline") + "\n\n")
	}
	b.WriteString(notice("NOTE", "Alarm is at "+strconv.FormatInt(jv.Alarm, 10)+"/3",
		"Carry secures loot against a bust; Watch holds the door. If you are the snitch you want alarm, not a clean cellar."))
	b.WriteString(nav("The job", jobLink(jv.ID), "Rules", self("rules")))
	return b.String()
}

func renderCommitHash(jv JobView, you string, action uint8) string {
	if action < 1 || action > 4 {
		action = 1
	}
	var b strings.Builder
	b.WriteString(pageHead("Sign this hash", jobTitle(jv)+" · "+actionCell(action), "The job", jobLink(jv.ID)))
	if jv.Phase != 1 {
		b.WriteString(notice("WARNING", "Too late for a commit", "This job is "+phaseName(jv.Phase)+"."))
		return b.String() + nav("The job", jobLink(jv.ID))
	}
	if you == "" {
		b.WriteString(notice("WARNING", "No address in the URL",
			"The hash is bound to your wallet. Open your own seat view first: "+
				md("job "+strconv.FormatInt(jv.ID, 10), jobLink(jv.ID))+" and use the address link there."))
	}
	salt := CommitSalt(jv.ID, jv.Round, you)
	hash := CommitHash(jv.ID, action, salt, you)

	b.WriteString("You chose " + actionCell(action) + ". " + actionBlurb(action) + "\n\n")
	b.WriteString("**Hash to sign**\n\n" + code(hash) + "\n\n")
	b.WriteString("**Salt, keep it**\n\n" + code(salt) + "\n\n")
	b.WriteString(notice("CAUTION", "Without the salt your pick dies",
		"The realm checks `sha256(action|salt|you|job|round)` on reveal. Paste this salt back at the "+
			"reveal step or the pick counts as "+actionCell(4)+" and earns nothing."))

	b.WriteString("<gno-form exec=\"Commit\">\n")
	b.WriteString(readonlyField("id", "Job", strconv.FormatInt(jv.ID, 10)))
	b.WriteString(readonlyField("hash", "Hash (built from your pick)", hash))
	b.WriteString("</gno-form>\n\n")
	b.WriteString("_Signing posts only the hash. Your pick stays unreadable until the reveal._\n\n")

	b.WriteString("### After signing\n\n")
	b.WriteString(md("Back to the job", jobLink(jv.ID)) + " · " +
		md("go straight to the reveal form", seatLink(jv, you, "reveal")) +
		" (it works once this round's commits close — " + blocksLeft(jv) + ")\n")
	return b.String()
}

// ----- reveal -----

func renderReveal(jv JobView, you string) string {
	var b strings.Builder
	b.WriteString(pageHead("Reveal your pick", jobTitle(jv)+" · round "+
		strconv.FormatInt(int64(jv.Round), 10), "The job", jobLink(jv.ID)))
	if jv.Phase != 2 {
		b.WriteString(notice("WARNING", "Reveal is closed", "This job is "+phaseName(jv.Phase)+"."))
		return b.String() + nav("The job", jobLink(jv.ID))
	}
	if jv.Deadline <= jv.Height {
		b.WriteString(notice("CAUTION", "Deadline passed",
			"Reveal is rejected now (`e410`). "+md("Tick the job", jobLink(jv.ID))+
				" — unrevealed picks become "+actionCell(4)+" with no contribution."))
		return b.String() + nav("The job", jobLink(jv.ID))
	}
	b.WriteString(blocksLeft(jv) + ". The realm recomputes the hash from what you send and rejects a " +
		"mismatch, so send exactly what you committed.\n\n")

	b.WriteString("<gno-form exec=\"Reveal\">\n")
	b.WriteString(readonlyField("id", "Job", strconv.FormatInt(jv.ID, 10)))
	for _, a := range []uint8{1, 2, 3, 4} {
		b.WriteString(selectOpt("action", strconv.Itoa(int(a)), actionGlyph(a)+" "+actionName(a), false))
	}
	b.WriteString(selectSalt(jv, you))
	b.WriteString("</gno-form>\n\n")

	b.WriteString(notice("NOTE", "Salt prefilled but editable",
		"It is derived from your seat and this round. If you committed from another device, "+
			"paste the salt the commit page gave you instead."))
	b.WriteString(nav("The job", jobLink(jv.ID), "Rules", self("rules")))
	return b.String()
}

// ----- small form fields -----

func readonlyField(name, description, value string) string {
	return `<gno-input name="` + name + `" description="` + attr(description) +
		`" value="` + attr(value) + `" readonly="true" />` + "\n"
}

func selectOpt(name, value, label string, selected bool) string {
	s := `<gno-select name="` + name + `" value="` + attr(value) + `"`
	if label != "" {
		s += ` description="` + attr(label) + `"`
	}
	if selected {
		s += ` selected="true"`
	}
	return s + " />\n"
}

// selectSalt prefills the salt; a player who committed elsewhere overwrites it.
func selectSalt(jv JobView, you string) string {
	return `<gno-input name="salt" description="Salt from your commit page" value="` +
		attr(CommitSalt(jv.ID, jv.Round, you)) + `" required="true" />` + "\n"
}
