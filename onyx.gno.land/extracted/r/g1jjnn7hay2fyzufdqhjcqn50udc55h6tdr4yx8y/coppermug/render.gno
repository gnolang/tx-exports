package coppermug

import (
	"strings"
)

// Render is the whole front end: gnoweb serves this Markdown as the realm
// page, and the sub-pages hang off the realm's args (`/r/<pkg>:feed`).
func Render(cur realm, path string) string {
	pkg := cur.PkgPath()
	p := strings.Trim(strings.TrimSpace(path), "/")

	switch {
	case p == "":
		return renderHome(pkg)
	case p == "feed":
		return renderFeed(pkg)
	case p == "board":
		return renderBoard(pkg)
	case p == "cup":
		return renderCup(pkg)
	case p == "rules":
		return renderRules(pkg)
	case strings.HasPrefix(p, "u/"):
		return renderProfile(pkg, strings.TrimPrefix(p, "u/"))
	}
	return renderMissing(pkg, p)
}

// ---------------------------------------------------------------------------
// links
// ---------------------------------------------------------------------------

func realmURL(pkg, suffix string) string {
	if suffix == "" {
		return "/r/" + pkg
	}
	return "/r/" + pkg + ":" + suffix
}

func actionURL(pkg, fn string) string {
	return "/r/" + pkg + "$help&func=" + fn
}

func actionURL1(pkg, fn, key, value string) string {
	return "/r/" + pkg + "$help&func=" + fn + "&" + key + "=" + strings.ReplaceAll(value, " ", "%20")
}

// profileURL links to a profile, encoding the spaces names may contain.
func profileURL(pkg, name string) string {
	return realmURL(pkg, "u/"+strings.ReplaceAll(name, " ", "%20"))
}

func nav(pkg string) string {
	return "[Common room](" + realmURL(pkg, "feed") + ") · " +
		"[Board](" + realmURL(pkg, "board") + ") · " +
		"[The Cup](" + realmURL(pkg, "cup") + ") · " +
		"[House rules](" + realmURL(pkg, "rules") + ")"
}

func header(pkg string) string {
	return "# 🍺 Copper Mug\n\n" +
		"*A candle-lit room at the edge of the chain.*\n\n" +
		nav(pkg) + "\n\n---\n\n"
}

// ---------------------------------------------------------------------------
// home
// ---------------------------------------------------------------------------

func renderHome(pkg string) string {
	var b strings.Builder
	b.WriteString(header(pkg))

	seated := 0
	gold := int64(0)
	cups := 0
	for _, a := range seats {
		seated++
		gold += a.Gold
		if a.InCup {
			cups++
		}
	}

	b.WriteString("**" + itoa(int64(seated)) + " adventurer(s)** · **" +
		itoa(int64(len(feed))) + " tale(s) on the board** · **" +
		itoa(gold) + " gold** on the tables")
	if cups > 0 {
		b.WriteString(" · **" + itoa(int64(cups)) + " cup(s)** in play")
	}
	b.WriteString("\n\n")

	if seated == 0 {
		b.WriteString("The room is quiet. The fire is lit. The first stool is yours.\n\n")
	}

	b.WriteString("### Take a stool\n\n")
	b.WriteString("Pick a name and a trade, then call `Join`. The house stakes you **100 gold**.\n\n")
	b.WriteString("*[Join the tavern](" + actionURL(pkg, "Join") + ")*\n\n")
	b.WriteString("Trades: ⚔️ Fighter · 🗡️ Rogue · 🔮 Mage · 🎻 Bard\n\n")

	if len(feed) > 0 {
		b.WriteString("### Tonight at the mug\n\n")
		start := len(feed) - 3
		if start < 0 {
			start = 0
		}
		for i := len(feed) - 1; i >= start; i-- {
			writePost(&b, pkg, feed[i])
			b.WriteString("\n")
		}
		b.WriteString("[Read the whole board](" + realmURL(pkg, "feed") + ")\n\n")
	}

	if cups > 0 {
		b.WriteString("### Cups on the table\n\n")
		writeOpenCups(&b, pkg)
		b.WriteString("\n")
	}

	b.WriteString("### The house in three lines\n\n")
	b.WriteString("1. Every tale, tip and roll is realm state — no server, no database, no JavaScript.\n")
	b.WriteString("2. Gold is tavern money. It buys rounds and stakes cups; it is worth nothing outside.\n")
	b.WriteString("3. Cheer other people's tales. The board remembers.\n\n")

	b.WriteString("*[House rules](" + realmURL(pkg, "rules") + ") · Copper Mug v" + Version + "*\n")
	return b.String()
}

// ---------------------------------------------------------------------------
// feed
// ---------------------------------------------------------------------------

func renderFeed(pkg string) string {
	var b strings.Builder
	b.WriteString(header(pkg))
	b.WriteString("## 📜 The common room\n\n")
	b.WriteString("Every line here is a transaction. Cheer the ones you like.\n\n")
	b.WriteString("*[Say something](" + actionURL(pkg, "Say") + ")*\n\n")

	if len(feed) == 0 {
		b.WriteString("> The board is blank. Somebody has to go first.\n")
		return b.String()
	}

	shown := 0
	for i := len(feed) - 1; i >= 0 && shown < 40; i-- {
		writePost(&b, pkg, feed[i])
		b.WriteString("\n")
		shown++
	}

	if len(feed) > shown {
		b.WriteString("*Older tales have been scraped off the board. The mug keeps the last " +
			itoa(int64(MaxFeed)) + ".*\n")
	}
	return b.String()
}

func writePost(b *strings.Builder, pkg string, p *Post) {
	b.WriteString("> **[" + p.Name + "](" + profileURL(pkg, p.Name) + ")** " + p.Class.Sigil() +
		" · *" + p.Class.Label() + "* · night " + itoa(p.Height))
	if len(p.Cheers) > 0 {
		b.WriteString(" · 🍻 " + itoa(int64(len(p.Cheers))))
	}
	b.WriteString(" · [cheer](" + actionURL1(pkg, "Cheer", "postID", itoa(p.ID)) + ")")
	b.WriteString("\n> " + escapeMarkdown(p.Text) + "\n")
}

// ---------------------------------------------------------------------------
// board
// ---------------------------------------------------------------------------

func renderBoard(pkg string) string {
	var b strings.Builder
	b.WriteString(header(pkg))
	b.WriteString("## 🏆 The board\n\n")

	if len(seats) == 0 {
		b.WriteString("No names on the board yet.\n")
		return b.String()
	}

	b.WriteString("### Richest\n\n")
	writeTable(&b, pkg, topSeats(0, 8), 0, "Gold")

	b.WriteString("### Most renowned\n\n")
	writeTable(&b, pkg, topSeats(1, 8), 1, "Renown")

	b.WriteString("### Biggest pots\n\n")
	writeTable(&b, pkg, topSeats(2, 8), 2, "Best pot")

	b.WriteString("*Renown comes from tips received and tales cheered. Pots come from the Cup.*\n")
	return b.String()
}

// topSeats returns up to limit seats ordered by metric (0 gold, 1 renown,
// 2 best pot), with names breaking ties so the page is deterministic.
func topSeats(metric int, limit int) []*Adventurer {
	out := make([]*Adventurer, 0, limit)
	for _, a := range seats {
		v := metricValue(a, metric)
		if v <= 0 {
			continue
		}
		pos := len(out)
		for i := 0; i < len(out); i++ {
			ov := metricValue(out[i], metric)
			if v > ov || (v == ov && a.Name < out[i].Name) {
				pos = i
				break
			}
		}
		if pos >= limit {
			continue
		}
		out = append(out, nil)
		for i := len(out) - 1; i > pos; i-- {
			out[i] = out[i-1]
		}
		out[pos] = a
		if len(out) > limit {
			out = out[:limit]
		}
	}
	return out
}

func metricValue(a *Adventurer, metric int) int64 {
	switch metric {
	case 0:
		return a.Gold
	case 1:
		return a.Rep
	case 2:
		return a.BestPot
	}
	return 0
}

func writeTable(b *strings.Builder, pkg string, rows []*Adventurer, metric int, label string) {
	if len(rows) == 0 {
		b.WriteString("*Nobody yet.*\n\n")
		return
	}
	b.WriteString("| # | Adventurer | " + label + " |\n")
	b.WriteString("|---|---|---|\n")
	for i, a := range rows {
		b.WriteString("| " + itoa(int64(i+1)) + " | " +
			"[" + a.Name + "](" + profileURL(pkg, a.Name) + ") " + a.Class.Sigil() +
			" | " + itoa(metricValue(a, metric)) + " |\n")
	}
	b.WriteString("\n")
}

// ---------------------------------------------------------------------------
// cup
// ---------------------------------------------------------------------------

func renderCup(pkg string) string {
	var b strings.Builder
	b.WriteString(header(pkg))
	b.WriteString("## 🎲 The Cup\n\n")
	b.WriteString("A push-your-luck game played for tavern gold.\n\n")
	b.WriteString("| Roll | Result |\n|---|---|\n")
	b.WriteString("| **1** | Bust — the stake is gone |\n")
	b.WriteString("| **2–5** | Pot grows by half your stake |\n")
	b.WriteString("| **6** | Pot grows by 20% |\n\n")
	b.WriteString("Roll as often as you dare, then **Hold** to bank the pot.\n\n")
	b.WriteString("*[Open a cup](" + actionURL(pkg, "OpenCup") + ") · " +
		"[Roll](" + actionURL(pkg, "Roll") + ") · " +
		"[Hold](" + actionURL(pkg, "Hold") + ")*\n\n")
	b.WriteString("Minimum stake: **10 gold**. The house does not take a cut; the dice are enough.\n\n")

	if cups := openCups(); len(cups) > 0 {
		b.WriteString("### Cups on the table\n\n")
		writeOpenCups(&b, pkg)
		b.WriteString("\n")
	}

	b.WriteString("### Biggest pots ever\n\n")
	writeTable(&b, pkg, topSeats(2, 5), 2, "Best pot")

	b.WriteString("### Fairness\n\n")
	b.WriteString("Rolls are derived from the chain height, the player's address and a realm " +
		"sequence number. That is **house randomness**: it is deterministic and a player who " +
		"can simulate the next block can predict the roll. It is fine for play money and not " +
		"fine for anything valuable. A commit-reveal scheme is the next version.\n")
	return b.String()
}

func openCups() []*Adventurer {
	var out []*Adventurer
	for _, a := range seats {
		if a.InCup {
			out = append(out, a)
		}
	}
	// Simple insertion sort by pot, descending, name as tie-break.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0; j-- {
			if out[j].Pot > out[j-1].Pot ||
				(out[j].Pot == out[j-1].Pot && out[j].Name < out[j-1].Name) {
				out[j], out[j-1] = out[j-1], out[j]
				continue
			}
			break
		}
	}
	return out
}

func writeOpenCups(b *strings.Builder, pkg string) {
	cups := openCups()
	if len(cups) == 0 {
		b.WriteString("*No cups on the table right now.*\n")
		return
	}
	b.WriteString("| Adventurer | Stake | Pot | Dice |\n")
	b.WriteString("|---|---|---|---|\n")
	for _, a := range cups {
		b.WriteString("| [" + a.Name + "](" + profileURL(pkg, a.Name) + ") " + a.Class.Sigil() +
			" | " + itoa(a.Stake) + " | " + itoa(a.Pot) + " | " + diceString(a.CupDice) + " |\n")
	}
}

func diceString(dice []int) string {
	if len(dice) == 0 {
		return "—"
	}
	parts := make([]string, 0, len(dice))
	for _, d := range dice {
		parts = append(parts, itoa(int64(d)))
	}
	return strings.Join(parts, " · ")
}

// ---------------------------------------------------------------------------
// profile
// ---------------------------------------------------------------------------

func renderProfile(pkg, name string) string {
	key := strings.ToLower(strings.TrimSpace(strings.ReplaceAll(name, "%20", " ")))
	addr, ok := byName[key]
	if !ok {
		return renderMissing(pkg, "u/"+name)
	}
	a := seats[addr]

	var b strings.Builder
	b.WriteString(header(pkg))
	b.WriteString("## " + a.Name + " " + a.Class.Sigil() + "\n\n")
	b.WriteString("*" + a.Class.Label() + " · seated since night " + itoa(a.Joined) + "*\n\n")

	b.WriteString("| Gold | Renown | Wins | Losses | Best pot |\n")
	b.WriteString("|---|---|---|---|---|\n")
	b.WriteString("| " + itoa(a.Gold) + " | " + itoa(a.Rep) + " | " + itoa(int64(a.Wins)) +
		" | " + itoa(int64(a.Losses)) + " | " + itoa(a.BestPot) + " |\n\n")

	if a.InCup {
		b.WriteString("### A cup is on the table\n\n")
		b.WriteString("Stake **" + itoa(a.Stake) + "**, pot **" + itoa(a.Pot) + "**, dice: " +
			diceString(a.CupDice) + "\n\n")
	}

	b.WriteString("*[Tip " + a.Name + "](" + actionURL1(pkg, "Tip", "to", a.Name) + ")*\n\n")

	wrote := false
	for i := len(feed) - 1; i >= 0; i-- {
		if feed[i].Author != addr {
			continue
		}
		if !wrote {
			b.WriteString("### From their table\n\n")
			wrote = true
		}
		writePost(&b, pkg, feed[i])
		b.WriteString("\n")
	}
	if !wrote {
		b.WriteString("*Has not said a word yet.*\n")
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// rules and fallbacks
// ---------------------------------------------------------------------------

func renderRules(pkg string) string {
	var b strings.Builder
	b.WriteString(header(pkg))
	b.WriteString("## 📖 House rules\n\n")
	b.WriteString("**Join.** One stool per wallet, one name per wallet. Names are 2–20 characters: " +
		"letters, digits, spaces, `-` and `_`.\n\n")
	b.WriteString("**Talk.** Messages are capped at 240 characters and one every few blocks. " +
		"The board keeps the last " + itoa(int64(MaxFeed)) + ".\n\n")
	b.WriteString("**Tip.** Send gold to anyone seated. Every 10 gold of tips earns them 1 renown.\n\n")
	b.WriteString("**Cheer.** One cheer per wallet per tale. The author gains renown.\n\n")
	b.WriteString("**Buy a round.** 25 gold: up to ten recently active neighbours get 2 gold each, " +
		"and you gain 1 renown.\n\n")
	b.WriteString("**The Cup.** Stake at least 10 gold. Roll a d6: 1 busts, 2–5 adds half your stake " +
		"to the pot, 6 multiplies it by 1.2. Hold whenever you like.\n\n")
	b.WriteString("**Fairness.** Rolls are deterministic house randomness, not consensus randomness. " +
		"Fine for play money; not fine for value.\n\n")
	b.WriteString("**Money.** Gold is minted by this realm, has no monetary value, and cannot leave it.\n\n")
	b.WriteString("**Calls.** Only wallet calls are accepted. Other realms cannot act for you.\n")
	return b.String()
}

func renderMissing(pkg, path string) string {
	var b strings.Builder
	b.WriteString(header(pkg))
	b.WriteString("## 🚪 No such room\n\n")
	b.WriteString("There is nothing at `" + escapeMarkdown(path) + "`.\n\n")
	b.WriteString("Try the " + "[common room](" + realmURL(pkg, "feed") + ") or the " +
		"[board](" + realmURL(pkg, "board") + ").\n")
	return b.String()
}
