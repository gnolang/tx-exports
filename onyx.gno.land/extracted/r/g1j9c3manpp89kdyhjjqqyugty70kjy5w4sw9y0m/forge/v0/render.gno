package forge

import (
	"strconv"
	"strings"

	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
)

// realmPath is this realm's gnoweb path; action links hang $help&func=...
// off it and pages hang :sub/path segments.
const realmPath = "/r/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/forge/v0"

// Render serves the forge's gnoweb pages. "" is home; "item/<id>" is a ware
// page for known ids only; "inv/<addr>" is a player's kit. Every other path —
// and every invalid segment — gets a fixed message; nothing user-controlled
// is ever echoed into the markdown.
func Render(path string) string {
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return renderHome()
	case len(parts) == 2 && parts[0] == "item":
		return renderItem(parts[1])
	case len(parts) == 2 && parts[0] == "inv":
		return renderInventory(parts[1])
	default:
		return "## The forge goes quiet\n\n" +
			"There is nothing on that shelf. Head back to the " +
			"[forge](" + realmPath + ").\n"
	}
}

func renderHome() string {
	var b strings.Builder

	b.WriteString("# The Tavern Forge\n\n")
	b.WriteString("Behind the taproom, where the regulars swap stories over ale, ")
	b.WriteString("a working forge never goes cold. Gather wood and ore out back, ")
	b.WriteString("smelt and shape them at the anvil, and hang your name among the ")
	b.WriteString("tavern's most renowned crafters.\n\n")

	b.WriteString("## How to play\n\n")
	b.WriteString("- [**Gather**](" + realmPath + "$help&func=Gather) — " +
		"2 Oak Wood + 1 Iron Ore per call, once every " +
		strconv.Itoa(gatherCooldown) + " blocks.\n")
	for _, r := range recipes {
		b.WriteString("- [**Craft " + r.id + "**](" + realmPath +
			"$help&func=Craft&recipe=" + r.id + ") — " + recipeText(r) + ".\n")
	}
	b.WriteString("- [**Transfer**](" + realmPath + "$help&func=Transfer) — ")
	b.WriteString("send loot to another player (args: to, id, amount).\n")
	b.WriteString("- [**Batch transfer**](" + realmPath +
		"$help&func=BatchTransfer) — several stacks at once ")
	b.WriteString("(args: to, ids, amounts — comma-separated).\n")
	b.WriteString("- [**Set approval**](" + realmPath +
		"$help&func=SetApprovalForAll) — let an operator move your items ")
	b.WriteString("(args: operator, approved).\n\n")

	b.WriteString("## Wares on the anvil\n\n")
	b.WriteString("| Item | Obtained by | Supply | Used for |\n")
	b.WriteString("|---|---|---:|---|\n")
	for _, it := range items {
		b.WriteString("| [" + it.name + "](" + realmPath + ":item/" + it.id +
			") (`" + it.id + "`) | " + sourceText(it.id) + " | " +
			supplyText(it.id) + " | " + it.useIn + " |\n")
	}
	b.WriteString("\n")

	b.WriteString("## Hall of renown\n\n")
	if len(topTen) == 0 {
		b.WriteString("No one has lifted a hammer yet — the forge is cold. ")
		b.WriteString("Be the first name on the board.\n")
	} else {
		b.WriteString("| # | Player | Renown |\n")
		b.WriteString("|---:|---|---:|\n")
		for i, e := range topTen {
			b.WriteString("| " + strconv.Itoa(i+1) + " | [" +
				shortAddr(e.addr) + "](" + realmPath + ":inv/" +
				e.addr.String() + ") | " +
				strconv.FormatInt(e.score, 10) + " |\n")
		}
	}
	b.WriteString("\n")

	b.WriteString("## Your kit\n\n")
	b.WriteString("Every crafter's pockets are on their own page — open yours at ")
	b.WriteString("`" + realmPath + ":inv/<your g1 address>`.\n")

	return b.String()
}

func renderItem(id string) string {
	it := findItem(id)
	if it == nil {
		return "## The forge knows no such item\n\n" +
			"This page is not on the anvil. See the " +
			"[forge catalog](" + realmPath + ").\n"
	}

	var b strings.Builder
	b.WriteString("# " + it.name + "\n\n")
	b.WriteString(it.desc + "\n\n")
	b.WriteString("- **Item id:** `" + it.id + "`\n")
	b.WriteString("- **Supply:** " + supplyText(it.id) + "\n")
	b.WriteString("- **Obtained by:** " + sourceText(it.id) + "\n")
	b.WriteString("- **Used for:** " + it.useIn + "\n\n")

	if r := recipeFor(it.id); r != nil {
		b.WriteString("[Craft " + it.name + "](" + realmPath +
			"$help&func=Craft&recipe=" + r.id + ")\n")
	} else {
		b.WriteString("[Gather more](" + realmPath + "$help&func=Gather)\n")
	}

	return b.String()
}

func renderInventory(addrStr string) string {
	addr := address(addrStr)
	// IsValid plus the lowercase-canonical form: an uppercase bech32 spelling
	// is a different ledger key, so it can never hold forge items.
	if !addr.IsValid() || addrStr != strings.ToLower(addrStr) {
		return "## Not an address\n\n" +
			"`inv/` expects a player address like `g1...`. " +
			"See the [forge](" + realmPath + ").\n"
	}

	var tids []grc1155.TokenID
	var bals []int64
	after := grc1155.TokenID("")
	for {
		pageIDs, pageBals := token.HoldingsAfter(addr, after, 50)
		if len(pageIDs) == 0 {
			break
		}
		tids = append(tids, pageIDs...)
		bals = append(bals, pageBals...)
		if len(pageIDs) < 50 {
			break
		}
		after = pageIDs[len(pageIDs)-1]
	}

	var b strings.Builder
	b.WriteString("## " + shortAddr(addr) + "'s kit\n\n")

	if len(tids) == 0 {
		b.WriteString("The satchel is empty — nothing gathered, nothing crafted. ")
		b.WriteString("[Head out back to gather](" + realmPath +
			"$help&func=Gather); the forge provides the materials.\n")
		return b.String()
	}

	b.WriteString("| Item | Quantity |\n")
	b.WriteString("|---|---:|\n")
	for i, tid := range tids {
		b.WriteString("| [" + itemName(tid.String()) + "](" + realmPath +
			":item/" + tid.String() + ") | " +
			strconv.FormatInt(bals[i], 10) + " |\n")
	}
	b.WriteString("\n")
	b.WriteString("**Renown:** " +
		strconv.FormatInt(renownScore(addr), 10) + "\n")

	return b.String()
}

// sourceText describes how an item is obtained: its recipe when one exists,
// otherwise gathering.
func sourceText(id string) string {
	if r := recipeFor(id); r != nil {
		return "Craft — " + recipeText(*r)
	}
	return "Gathered behind the tavern."
}

func supplyText(id string) string {
	return strconv.FormatInt(token.TotalSupply(grc1155.TokenID(id)), 10)
}

// shortAddr abbreviates a bech32 address for table display; the full address
// stays in the link target.
func shortAddr(addr address) string {
	s := addr.String()
	if len(s) > 14 {
		return s[:14] + "…"
	}
	return s
}
