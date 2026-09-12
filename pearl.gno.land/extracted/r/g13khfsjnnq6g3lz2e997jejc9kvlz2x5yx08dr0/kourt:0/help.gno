package kourt
import "strings"
const helpPath = "how-it-works"
const helpLink = "[New here? How Kourt works](/r/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/kourt:" + helpPath + ")"
func renderHelp() string {
	var b strings.Builder
	b.WriteString("# How Kourt works\n\n")
	b.WriteString("Kourt is a place to put money behind whether a factual claim is " +
		"true — without being able to lose the money.\n\n")
	b.WriteString("It works in two steps. **GNOT buys a court's coin**, one way; " +
		"**that coin is what you stake** on the court's claims.\n\n")
	b.WriteString("## You cannot lose your stake\n\n")
	b.WriteString("Stake the court's coin on YES or NO and the stake stays yours. " +
		"It is locked where it is, not handed to anybody: when the claim is " +
		"answered you withdraw exactly what you put in — 1×, always, whichever " +
		"side you took and whichever side turned out to be right. No one's stake " +
		"pays anyone else's winnings.\n\n")
	b.WriteString("Then what is at stake? Being right pays you more of the court's " +
		"coin, out of the reserve it set aside for exactly that — and being wrong " +
		"pays you none. Nothing of yours is taken either way.\n\n")
	b.WriteString("Being right also earns **standing**, which is a separate thing " +
		"from a balance: a score you cannot buy, and what actually gives you a " +
		"voice here.\n\n")
	b.WriteString("## A court is a subject\n\n")
	b.WriteString("A court covers one subject — an epidemic, an election, a company. " +
		"Each court has its own coin, and coins never cross between courts. Being " +
		"right about virology earns you nothing in a court about monetary policy. " +
		"That is the point: standing is earned subject by subject, by the people who " +
		"follow that subject.\n\n")
	b.WriteString("## A claim is a statement that can be settled\n\n")
	b.WriteString("A claim is a sentence that is either true or false, written so it " +
		"can actually be answered. You stake YES or NO, and you can move your stake " +
		"freely until an answer posts.\n\n")
	b.WriteString("A claim's page always says where it stands. The wordings you will see:\n\n")
	b.WriteString("- **settled YES** or **settled NO** — answered, and the page " +
		"says which way; every stake withdraws 1×\n")
	b.WriteString("- **disputed** — a sealed vote is deciding; principal is never withheld\n")
	b.WriteString("- **closed** — never answered; every stake exited 1×, the deposit refunded\n")
	b.WriteString("- **closed without a decision** — three dispute rounds failed quorum; " +
		"everyone withdraws 1×, deposit and fee refunded\n\n")
	b.WriteString("## Comments are where the argument is\n\n")
	b.WriteString("Every claim has a comment board. A YES/NO number cannot carry a " +
		"reason, a source, or an objection; the board is where those go.\n\n")
	b.WriteString("Writing takes standing — the score you earned by being right in " +
		"this court, not the coin you hold. If you have none yet, you can buy a " +
		"one-off entry pass by burning a little of the court's coin, which is the " +
		"single place money substitutes for it. Standing sets how many comments a " +
		"day you get, not how loudly they land: nothing is hidden for being new, " +
		"and nothing is ranked by wealth.\n\n")
	b.WriteString("If you have money on the claim you are commenting on, your comment " +
		"says so — which side, and how much. The board deliberately does *not* order " +
		"by it. You are told, and you decide what it is worth.\n\n")
	b.WriteString("## Two things you can actually lose\n\n")
	b.WriteString("Everything above is about a stake that always comes back. " +
		"There are exactly two actions here that risk money, and both are " +
		"challenges — you are putting up a **bond** to say the court got " +
		"something wrong.\n\n")
	b.WriteString("- **Challenging an answer.** If you think a claim was answered " +
		"the wrong way, you can dispute it by posting a bond. Win and the " +
		"answerer's bond is burned and you are compensated; lose and yours is " +
		"burned instead. Nothing passes between you — a forfeit is destroyed, a " +
		"compensation is newly issued.\n")
	b.WriteString("- **Challenging a rating.** Every answered claim gets rated " +
		"low, mid or high, and that rating decides what it pays. Anyone may " +
		"challenge the rating once, also by posting a bond, which calls a vote " +
		"on it.\n\n")
	b.WriteString("**Your stake is never at risk in either.** A bond is separate " +
		"money you choose to put up; the coin you staked on the claim still " +
		"comes back 1×, whatever the challenge decides.\n\n")
	b.WriteString("## What things cost\n\n")
	b.WriteString("- **Staking** costs only the stake, which you get back.\n")
	b.WriteString("- **Opening a claim** takes a deposit, refunded when the claim is " +
		"answered or closed.\n")
	b.WriteString("- **Buying a court's coin** burns GNOT one way. There is no sell " +
		"side and no redemption; the price only rises as more is bought.\n\n")
	b.WriteString("## Who is in charge\n\n")
	b.WriteString("Each court elects its own moderators. They answer claims, organise " +
		"them into folders, and can hide comments. What they do to a claim or a " +
		"comment is written to that court's moderation log, which anyone can read " +
		"without asking. The serious powers need several moderators to agree — one " +
		"moderator acting alone cannot use them.\n\n")
	b.WriteString("[← all courts](/r/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/kourt:)\n")
	return b.String()
}
