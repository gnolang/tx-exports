package heirloom

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type willList struct {
	slug  string
	title string
	index *avl.Tree
}

const (
	listMade      = "made"
	listHeir      = "heir"
	listSuccessor = "successor"
)

func willLists() []willList {
	return []willList{
		{listMade, "Wills made", &state.ownerWills},
		{listHeir, "Named as heir", &state.heirWills},
		{listSuccessor, "Named as successor", &state.successorWills},
	}
}

func renderUser(addr address, only string, before int) string {
	var b strings.Builder
	b.WriteString("# " + shortAddr(addr) + "\n\n" + backLink() + "\n\n`" + addr.String() + "`\n\n")
	if holder := holderOf(addr); holder != addr {
		b.WriteString("Admin rights of this address now belong to " + userLink(holder) + ".\n\n")
	}
	found, named := false, false
	for _, list := range willLists() {
		if only != "" && list.slug != only {
			continue
		}
		found = true
		ws, more := willPage(list.index, addr, before)
		if only != "" && len(ws) == 0 {
			return notFound("Page not found")
		}
		b.WriteString("## " + list.title + "\n\n")
		if len(ws) == 0 {
			b.WriteString("None.\n\n")
			continue
		}
		for _, w := range ws {
			b.WriteString(willLine(list.slug, w, addr))
		}
		if more {
			b.WriteString("\n" + userPageLink("More", addr, list.slug, ws[len(ws)-1].ID) + "\n")
		}
		b.WriteString("\n")
		named = named || list.slug != listMade
	}
	if !found {
		return notFound("Page not found")
	}
	if named {
		b.WriteString("If this is your address, hide takes a will off this page; you stay an heir or successor, and Unhide puts it back.\n")
	}
	return b.String()
}

func willLine(list string, w *Will, addr address) string {
	switch list {
	case listHeir:
		return ufmt.Sprintf("- %s of %s: %d%%, %s · %s\n", willLink(w.ID), userLink(w.Owner), w.heir(addr).Percent, string(w.status()), hideLink(w))
	case listSuccessor:
		return ufmt.Sprintf("- %s of %s: %s · %s\n", willLink(w.ID), userLink(w.Owner), string(w.status()), hideLink(w))
	}
	return ufmt.Sprintf("- %s: %s\n", willLink(w.ID), string(w.status()))
}

func hideLink(w *Will) string {
	return link("hide", txURL("Hide", 0, "id", strconv.Itoa(w.ID)))
}
