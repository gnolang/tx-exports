package core

import (
	"strings"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
)

// catFilter renders a row of category filter links for a page prefix ("cat/" or "jobs/").
func CatFilter(db *State, prefix, all, cur string) string {
	var sb strings.Builder
	sb.WriteString("Filter: ")
	if cur == "" {
		sb.WriteString("**all**")
	} else {
		sb.WriteString("[all](" + Pl(db, all) + ")")
	}
	for _, c := range textfmt.Categories {
		sb.WriteString(" · ")
		if c == cur {
			sb.WriteString("**" + textfmt.CatLabel(c) + "**")
		} else {
			sb.WriteString("[" + textfmt.CatLabel(c) + "](" + Pl(db, prefix+c) + ")")
		}
	}
	return sb.String() + "\n\n"
}
