package questboard

import (
	"strconv"
	"strings"
)

// RealmPath is this realm's on-chain path, used in the usage examples
// rendered below. Update it if the realm is deployed under a different
// namespace (e.g. an address-based namespace gno.land/r/g1.../questboard).
const RealmPath = "gno.land/r/g13fd5s4h9ap0cggkgxnkqf0wawm9ew8x2kvnlv5/questboard"

// Render serves the quest board on gnoweb.
//
// Routes:
//
//	""          board home: stats, open quests, how to play
//	"open"      only open quests
//	"all"       every quest ever posted
//	"quest/<id>"  one quest in detail
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case path == "open":
		return "# Open quests\n\n" + renderQuestList(int(StatusOpen), true)
	case path == "all":
		return "# All quests\n\n" + renderQuestList(-1, true)
	case strings.HasPrefix(path, "quest/"):
		return renderQuestDetail(path[len("quest/"):])
	}
	return "# Tavern Quest Board\n\nUnknown page. Go back to the [board](/r/g13fd5s4h9ap0cggkgxnkqf0wawm9ew8x2kvnlv5/questboard).\n"
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# 🍺 The Tavern Quest Board\n\n")
	sb.WriteString("Post a bounty, brave adventurer. Complete a quest, claim the gold. ")
	sb.WriteString("Rewards are held in escrow by this realm and paid out on completion — ")
	sb.WriteString("or refunded to the poster after the deadline.\n\n")
	sb.WriteString("- Quests posted: " + strconv.Itoa(len(quests)) + "\n")
	sb.WriteString("- Currently open: " + strconv.Itoa(OpenQuestCount()) + "\n")
	sb.WriteString("- Locked in escrow: " + FormatGNOT(escrowed) + "\n\n")
	sb.WriteString("## Open quests\n\n")
	sb.WriteString(renderQuestList(int(StatusOpen), true))
	sb.WriteString("\n## How to play\n\n")
	sb.WriteString("Post a quest (attach exactly the reward as `-send`):\n\n")
	sb.WriteString("```\n")
	sb.WriteString("gnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"PostQuest\" \\\n")
	sb.WriteString("  -args \"Slay the spam goblins\" -args \"Clear the tavern cellar of spam goblins.\" \\\n")
	sb.WriteString("  -args 5000000 -args 1799000000 -send 5000000ugnot <your-key>\n")
	sb.WriteString("```\n\n")
	sb.WriteString("Accept a quest, then the poster completes it to release the reward:\n\n")
	sb.WriteString("```\n")
	sb.WriteString("gnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"AcceptQuest\" -args 1 <your-key>\n")
	sb.WriteString("gnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"CompleteQuest\" -args 1 <poster-key>\n")
	sb.WriteString("```\n\n")
	sb.WriteString("Poster tools: `CancelQuest` (open quests) and `ClaimRefund` (after the deadline) ")
	sb.WriteString("both return the escrowed reward in full.\n")
	return sb.String()
}

// renderQuestList renders a markdown table of quests. status >= 0
// filters by status; -1 lists everything.
func renderQuestList(status int, linkDetails bool) string {
	var sb strings.Builder
	count := 0
	sb.WriteString("| # | Quest | Reward | Deadline (unix) | Status |\n")
	sb.WriteString("|---|-------|--------|-----------------|--------|\n")
	for _, q := range quests {
		if status >= 0 && int(q.Status) != status {
			continue
		}
		count++
		title := sanitizeInline(q.Title)
		if linkDetails {
			title = "[" + title + "](/r/g13fd5s4h9ap0cggkgxnkqf0wawm9ew8x2kvnlv5/questboard:quest/" +
				strconv.FormatInt(int64(q.ID), 10) + ")"
		}
		sb.WriteString("| " + strconv.FormatInt(int64(q.ID), 10) +
			" | " + title +
			" | " + FormatGNOT(q.Reward) +
			" | " + strconv.FormatInt(q.Deadline, 10) +
			" | " + StatusName(q.Status) + " |\n")
	}
	if count == 0 {
		return "The board is empty. The tavern keeper is polishing mugs.\n"
	}
	return sb.String()
}

func renderQuestDetail(idStr string) string {
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		return "# Quest not found\n\nBad quest id.\n"
	}
	q := findQuest(id)
	if q == nil {
		return "# Quest not found\n\nNo quest with that id.\n"
	}
	var sb strings.Builder
	sb.WriteString("# Quest #" + strconv.FormatInt(int64(q.ID), 10) + ": " + sanitizeInline(q.Title) + "\n\n")
	sb.WriteString(sanitizeBlock(q.Description) + "\n\n")
	sb.WriteString("- Status: **" + StatusName(q.Status) + "**\n")
	sb.WriteString("- Reward: **" + FormatGNOT(q.Reward) + "** (" +
		strconv.FormatInt(q.Reward, 10) + " ugnot, held in escrow)\n")
	sb.WriteString("- Poster: " + q.Poster.String() + "\n")
	sb.WriteString("- Adventurer: " + addrOrDash(q.Adventurer) + "\n")
	sb.WriteString("- Posted at (unix): " + strconv.FormatInt(q.CreatedAt, 10) + "\n")
	sb.WriteString("- Deadline (unix): " + strconv.FormatInt(q.Deadline, 10) + "\n")
	return sb.String()
}

// sanitizeInline makes user-supplied text safe to embed in a single
// markdown line: newlines become spaces and markdown control
// characters are stripped, so a quest title cannot break the board
// layout or inject links/images of its own.
func sanitizeInline(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch r {
		case '\n', '\r', '\t':
			sb.WriteRune(' ')
		case '`', '#', '[', ']', '(', ')', '<', '>', '|', '*', '_':
			// drop markdown control characters
		default:
			sb.WriteRune(r)
		}
	}
	out := strings.TrimSpace(sb.String())
	if len(out) > 120 {
		out = out[:120]
	}
	return out
}

// sanitizeBlock is sanitizeInline for multi-line text: newlines are
// kept, the rest of the control characters are still stripped.
func sanitizeBlock(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch r {
		case '`', '<', '>':
			// drop characters that could break out into raw markup
		default:
			sb.WriteRune(r)
		}
	}
	return strings.TrimSpace(sb.String())
}
