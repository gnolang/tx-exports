package cutpurse

// render_home.gno — the front door. One pitch, one thing to do, the board.
// A stranger must be able to start a job without scrolling.

import "strings"

func renderHome() string {
	var b strings.Builder
	b.WriteString(title("Cutpurse"))
	b.WriteString("**Four strangers rob the same cellar in the dark. Each picks in secret. " +
		"One of them is on the take.**\n\n")
	b.WriteString("Three rounds. Commit, then reveal. The snitch walks out with 60% of a busted pot.\n\n")

	open := jobList(0, 40)
	b.WriteString(nav("Rules", self("rules"), "Ledger", self("ledger"), "Stats", self("stats")) + "\n")
	b.WriteString(notice("NOTE", "", plural(int64(len(open)), "job")+" open. A seat costs what its creator set; "+
		"the pot is held by the realm, not by them."))

	b.WriteString("## Start a job\n\n")
	b.WriteString("You name it and put up one seat's fee. That fee is escrowed, not spent: " +
		"it comes back with the pot when the job settles.\n\n")
	b.WriteString("<gno-form exec=\"CreateJob\">\n")
	b.WriteString(`<gno-input name="name" placeholder="Cellar job, like Monday's take" description="Job name" required="true" />` + "\n")
	b.WriteString(`<gno-input name="fee" type="number" value="100000" description="Your seat's fee in ugnot (100000 = 0.1 GNOT)" required="true" />` + "\n")
	b.WriteString("</gno-form>\n\n")
	b.WriteString(sendFor(MinFee, "That is your own seat's fee, held in escrow; the fee field "+
		"below is clamped to the realm's range."))

	b.WriteString("> [!TIP] The one thing worth knowing before you sign\n")
	b.WriteString("> Your pick is hidden until the round ends, so nobody can copy it. ")
	b.WriteString("Open " + md("the rules", self("rules")) + " until the commit step makes sense. Three minutes.\n\n")

	b.WriteString("## Open jobs\n\n")
	if len(open) == 0 {
		b.WriteString(notice("NOTE", "No job is open. Be the first through the door.",
			"Fill the form above. A second wallet joining is enough to start."))
	} else {
		b.WriteString(jobTable(open))
		b.WriteString("\nAll of them → " + md("the board", self("jobs")) + "\n\n")
	}

	b.WriteString("## How a job runs\n\n")
	b.WriteString(cards(
		"### 1. Fill the seats\nA job takes 2 to 4 players. The creator kicks anyone "+
			"they do not want before it starts; a kicked seat is refunded in full.\n",
		"### 2. Pick in secret\nYou pick an action and commit `sha256(action|salt|you|job|round)`. "+
			"The page does the arithmetic. Nobody can see what you chose until the reveal.\n",
		"### 3. Pay out\nThree rounds, then the pot splits by contribution — unless the alarm "+
			"hits 3 and the job busts. Then only secured loot is paid, and the snitch takes 60%.\n",
	))

	b.WriteString(fold("One of the four is the snitch", ""+
		"The seat is sealed at the end of round one and only becomes visible at settlement.\n\n"+
		"Until then every seat carries the same "+segLocked+" "+segLocked+" "+segLocked+" "+segLocked+". "+
		"A bust pays the snitch 60% of the pot; an escape pays the snitch nothing extra.\n\n"+
		"Read the "+md("rules", self("rules"))+" before you bet on anyone.\n"))

	b.WriteString(notice("WARNING", "Bets are real GNOT on a testnet",
		"Nothing here is audited for mainnet. Play what you can afford to lose."))

	b.WriteString(nav("The board", self("jobs"), "Every settled job", self("ledger")))
	return b.String()
}
