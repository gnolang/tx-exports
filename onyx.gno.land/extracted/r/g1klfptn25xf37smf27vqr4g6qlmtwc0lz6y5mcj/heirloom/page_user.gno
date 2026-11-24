package heirloom

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

func renderUser(addr address, page int) string {
	made, madeMore := willsMadeBy(addr, page)
	named, namedMore := willsNaming(addr, page)
	succeeding, succeedingMore := willsPassingRightsTo(addr, page)
	if page > 1 && len(made) == 0 && len(named) == 0 && len(succeeding) == 0 {
		return notFound("Page not found")
	}

	var b strings.Builder
	b.WriteString("# " + shortAddr(addr) + "\n\n" + backLink() + "\n\n`" + addr.String() + "`\n\n")
	if holder := holderOf(addr); holder != addr {
		b.WriteString("Admin rights of this address now belong to " + userLink(holder) + ".\n\n")
	}
	b.WriteString(section("Wills made", made, page, func(w *Will) string {
		return ufmt.Sprintf("- %s: %s\n", willLink(w.ID), string(w.status()))
	}))
	b.WriteString(section("Named as heir", named, page, func(w *Will) string {
		return ufmt.Sprintf("- %s of %s: %d%%, %s\n", willLink(w.ID), userLink(w.Owner), w.heir(addr).Percent, string(w.status()))
	}))
	b.WriteString(section("Named as successor", succeeding, page, func(w *Will) string {
		return ufmt.Sprintf("- %s of %s: %s\n", willLink(w.ID), userLink(w.Owner), string(w.status()))
	}))
	if madeMore || namedMore || succeedingMore {
		b.WriteString(userPageLink("More", addr, page+1) + "\n")
	}
	return b.String()
}

func section(title string, ws []*Will, page int, line func(*Will) string) string {
	if len(ws) == 0 {
		if page == 1 {
			return "## " + title + "\n\nNone.\n\n"
		}
		return ""
	}
	var b strings.Builder
	b.WriteString("## " + title + "\n\n")
	for _, w := range ws {
		b.WriteString(line(w))
	}
	return b.String() + "\n"
}
