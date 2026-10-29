package kourt
import (
	"strconv"
	"strings"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)
const electionPath = "election"
func renderElection(slug string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	base := "/r/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/kourt:" + slug
	var b strings.Builder
	b.WriteString("# Electing the moderators of " + courtNameFor(c) + "\n\n")
	b.WriteString("[← " + courtNameFor(c) + "](" + base + ") · [moderation log](" +
		base + "/mod)\n\n")
	b.WriteString("A court's moderators answer claims, curate its folders, and can " +
		"hide a claim, hide a comment, slash somebody's standing, or freeze an " +
		"address out of the boards. **This ballot is the only way the court's " +
		"holders replace them.**\n\n")
	cm := c.mod
	if cm == nil || cm.election == nil || cm.election.resolved {
		writeNoElection(&b, c, cm)
		b.WriteString("\n" + helpLink + "\n")
		return b.String()
	}
	writeOpenElection(&b, c, cm, base)
	b.WriteString("\n" + helpLink + "\n")
	return b.String()
}
func writeNoElection(b *strings.Builder, c *Court, cm *courtMod) {
	b.WriteString("## No election is open\n\n")
	if cm == nil || cm.n == 0 {
		b.WriteString("This court has no moderator set yet — its creator holds the " +
			"seat until an election or an appointment changes that.\n")
	} else {
		b.WriteString("- seats held now: **" + strconv.Itoa(cm.n) + "**, " +
			strconv.Itoa(cm.m) + " of whom must agree for a moderation act\n")
	}
	now := heightNow()
	if cm != nil && electionCooldownOpen(cm) {
		b.WriteString("- this court is in its post-election cooldown until block **" +
			strconv.FormatInt(cm.electionCooldownUntil, 10) + "** (now " +
			strconv.FormatInt(now, 10) + "); no ballot can open before then\n\n")
		return
	}
	b.WriteString("- a ballot **can be opened now**\n\n")
	b.WriteString("Opening one takes two calls: `RegisterModCandidate` records a " +
		"proposed set of moderators and returns its id, and `OpenElection` puts " +
		"that id on a ballot. Any holder may do both.\n\n")
}
func writeOpenElection(b *strings.Builder, c *Court, cm *courtMod, base string) {
	e := cm.election
	now := heightNow()
	b.WriteString("## A ballot is open\n\n")
	switch {
	case !nominationClosed(e):
		b.WriteString("**Nominating.** Candidate sets may be added until block **" +
			strconv.FormatInt(e.nominateEnd, 10) + "**; voting runs from then " +
			"until block **" + strconv.FormatInt(e.voteEnd, 10) + "**.\n\n")
	case !votingClosed(e):
		b.WriteString("**Voting.** Nominations closed at block " +
			strconv.FormatInt(e.nominateEnd, 10) + "; the ballot closes at block **" +
			strconv.FormatInt(e.voteEnd, 10) + "**.\n\n")
	default:
		b.WriteString("**Closed and awaiting resolution.** The ballot shut at block " +
			strconv.FormatInt(e.voteEnd, 10) + ". Anyone may call `ResolveElection` " +
			"to apply the result below.\n\n")
	}
	b.WriteString("- now: block " + strconv.FormatInt(now, 10) + "\n")
	b.WriteString("- a candidate set costs a bond of **" +
		strconv.FormatInt(e.bond, 10) + " " + qualifiedSymbol(c) + "**\n")
	b.WriteString("- weights are pinned at the epoch the ballot opened, so buying " +
		"coin now does not add voting weight to it\n\n")
	writeBallotLines(b, c, e)
	writeTurnoutBar(b, c, e)
}
func writeBallotLines(b *strings.Builder, c *Court, e *election) {
	b.WriteString("## On the ballot\n\n")
	rows := 0
	e.lines.Iterate("", "", func(_ string, v any) bool {
		l, ok := v.(*ballotLine)
		if !ok {
			return false
		}
		rows++
		b.WriteString("- **set #" + strconv.FormatUint(l.candID, 10) + "** — " +
			strconv.FormatInt(l.weight, 10) + " " + qualifiedSymbol(c) + " approving\n")
		if cv := c.mod.candidates.Get(beClaimKey(l.candID)); cv != nil {
			cand := cv.(*modCandidate)
			b.WriteString("  - would seat " + strconv.Itoa(len(cand.members)) +
				", " + strconv.Itoa(cand.m) + " of whom must agree\n")
			for _, m := range cand.members {
				b.WriteString("  - `" + sanitize.InlineText(m.String()) + "`\n")
			}
		}
		return rows >= renderPageSize
	})
	if rows == 0 {
		b.WriteString("_No candidate sets yet._ Until one is nominated there is " +
			"nothing to elect, and the current moderators stay.\n\n")
	} else {
		b.WriteString("\n")
	}
	b.WriteString("- **keep the current moderators** — " +
		strconv.FormatInt(e.retainW, 10) + " " + qualifiedSymbol(c) + " approving\n\n")
}
func writeTurnoutBar(b *strings.Builder, c *Court, e *election) {
	b.WriteString("## Turnout\n\n")
	b.WriteString("- cast so far: **" + strconv.FormatInt(e.turnout, 10) + " " +
		qualifiedSymbol(c) + "**\n")
	b.WriteString("- the bar: **" + strconv.FormatInt(e.floor, 10) + " " +
		qualifiedSymbol(c) + "**, fixed when the ballot opened\n")
	if e.turnout < e.floor {
		b.WriteString("- still needed: **" + strconv.FormatInt(e.floor-e.turnout, 10) +
			" " + qualifiedSymbol(c) + "**\n\n")
	} else {
		b.WriteString("- the bar is cleared\n\n")
	}
	b.WriteString("> **Falling short is not a draw.** If the ballot closes with less " +
		"than the bar cast, nothing is installed and the current moderators keep " +
		"their seats — the same outcome as a vote to retain them.\n>\n" +
		"> And the bar is a share of this court's coin **including coin that " +
		"cannot vote**: it nets out only the court's own escrow, so coin held at " +
		"a wrapper's address counts toward the pool the bar was measured against " +
		"while no key can cast it. The share of actually-castable weight you need " +
		"is therefore larger than the bar looks.\n\n")
}
