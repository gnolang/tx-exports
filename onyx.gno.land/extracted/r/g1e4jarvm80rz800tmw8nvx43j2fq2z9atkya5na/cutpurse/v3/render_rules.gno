package cutpurse

// render_rules.gno — the whole game, once. Written for a player who is about
// to risk money, so every number is stated rather than implied.

import "strings"

func renderRules() string {
	var b strings.Builder
	b.WriteString(pageHead("Rules",
		"Four seats, three rounds, one snitch. Read once, then "+md("start a job", self(""))+".", "Home", hub))
	b.WriteString(notice("NOTE", "Everything below is enforced by the realm",
		"The alarm, the deadline and the payout split are arithmetic, not manners. "+
			"Nobody — including the job's creator — can move a coin before settlement."))

	b.WriteString("## The job\n\n")
	b.WriteString("A job is four seats in one cellar. Seats fill for 50 minutes; a job needs 2 players " +
		"to start and may run with fewer than 4. Everyone puts up the same fee, so the pot is " +
		"`fee × seats` and it sits in the realm until the job ends.\n\n")
	b.WriteString(notice("NOTE", "Why the seats may stay empty",
		"An unfilled job is harder and pays the same per seat. Do not wait for strangers if the fee is good."))

	b.WriteString("## Paying in\n\n")
	b.WriteString("The fee rides the transaction, not a form. Only `CreateJob` and `JoinJob` read " +
		"the send envelope: a call with no coins at all is `e403 not-user-call`, less than the " +
		"fee is `e413`, and anything over is refunded in the same transaction.\n\n")
	b.WriteString("Every other call sends nothing — `Start`, `Kick`, `Commit`, `Reveal`, `Tick`, " +
		"`Settle` all fail if you attach coins. The `$help` page of each job prints the exact " +
		"command, send included.\n\n")

	b.WriteString("## The three rounds\n\n")
	b.WriteString(cards(
		"### Commit\nYou pick in secret. The page hashes your pick with a salt and posts only the hash. "+
			"200 blocks.\n",
		"### Reveal\nYou post the pick and the salt. The realm checks them against your hash. "+
			"150 blocks. A pick that is never revealed counts as "+actionCell(4)+" and costs you a reputation point.\n",
		"### Resolve\nLoot and alarm move together. Unless the job busted or this was round three, "+
			"the next round opens.\n",
	))

	b.WriteString("## The four actions\n\n")
	b.WriteString("Each round every player picks one in secret. Contribution is what the pot is split by.\n\n")
	b.WriteString("| Action | Contribution | Loot | Alarm |\n|---:|---:|---:|---:|\n")
	b.WriteString("| " + actionCell(1) + " | 2 | +2 | — |\n")
	b.WriteString("| " + actionCell(2) + " | 3 | +3 | +1 |\n")
	b.WriteString("| " + actionCell(3) + " | 3 | +3 secured | — |\n")
	b.WriteString("| " + actionCell(4) + " | 1 + alarm | +1 | −1 |\n\n")

	b.WriteString("### Alarm\n\n")
	b.WriteString("Alarm climbs by `picks − watches`, never below zero, and the meter is " +
		alarmBars(0) + ". At 3 the cellar door slams: the job busts " +
		"and every point of loot that was not carried out is lost.\n\n")
	b.WriteString(notice("CAUTION", "Carry is the only loot that survives a bust",
		"Unsecured loot is worth nothing on a bust. If the alarm is at 2, "+actionCell(3)+
			" is worth more than "+actionCell(2)+"."))

	b.WriteString("## The snitch\n\n")
	b.WriteString("At the end of round one the realm seals a seed from every commit hash in the round and " +
		"takes the snitch seat from it. No one — no creator, no oracle, no house — can set or change it after that.\n\n")
	b.WriteString("> " + segLocked + " " + segLocked + " " + segLocked + " " + segLocked + " — the seat is among you until settlement\n\n")
	b.WriteString("On a **bust** the snitch takes 60% of the pot and the rest splits by contribution. " +
		"On an **escape** the snitch takes nothing extra. That is the whole deduction: " +
		"a snitch wants alarm, so watch who keeps picking while the meter is climbing.\n\n")

	b.WriteString("## Payout\n\n")
	b.WriteString("Escaped: 5% of secured loot goes to the treasury and the rest splits by contribution. " +
		"Busted: 60% to the snitch, the remainder by contribution. A rounding remainder goes to the " +
		"highest contributor. If everyone contributed nothing, the pot splits evenly.\n\n")

	b.WriteString("## Timeouts\n\n")
	b.WriteString("Deadlines are block heights. Anyone may nudge the clock with " +
		md("Tick", self("jobs")) + " — it is permissionless and pays nothing, so do it rather than wait.\n\n")
	b.WriteString("- [x] A commit that never reveals becomes " + actionCell(4) + ", auto, no contribution, −1 reputation\n")
	b.WriteString("- [x] A missing commit becomes " + actionCell(4) + " with no contribution\n")
	b.WriteString("- [ ] A reveal after the deadline is rejected (`e410`) — the page tells you before you sign\n\n")

	b.WriteString("## Verifying a pick\n\n")
	b.WriteString("The hash is `sha256(action|salt|your address|job id|round)`, hex. The commit page builds it " +
		"from your chosen action and shows the salt to keep. Check it yourself with any sha256 tool; " +
		"the realm recomputes it exactly on reveal and rejects a mismatch (`e409`).\n\n")
	b.WriteString(notice("TIP", "Copy the salt when you commit",
		"Your seat page hands it back on the reveal step. Without it your pick cannot be proven."))

	b.WriteString(button("Read the board", self("jobs"), "") + " " +
		button("Start a job", self(""), "outline") + "\n\n")
	b.WriteString(nav("Home", self(""), "Every settled job", self("ledger")))
	return b.String()
}
