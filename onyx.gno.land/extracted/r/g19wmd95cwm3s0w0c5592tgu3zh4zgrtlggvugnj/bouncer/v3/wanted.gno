package bouncer

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// wantedRules are the rules the scanner has, in poster order. A rule gets
// a poster only once the scanner can report it.
var wantedRules = []string{"B01", "B03", "B04", "B05", "B08", "B10"}

// groundsFor is the Training Ground practising a rule, if there is one.
var groundsFor = map[string]string{"B01": "b01", "B05": "b05"}

// maxWantedScan bounds how many Passports one poster reads.
const maxWantedScan = 500

// maxWantedList bounds how many packages a poster lists.
const maxWantedList = 20

const guideURL = "https://docs.gno.land/resources/gno-security-guide"

func renderWantedIndex() string {
	var b strings.Builder
	b.WriteString("# Wanted\n\nThe bug classes Bouncer hunts. Each poster shows the bug, why it is dangerous, the fix, and the packages whose latest scan has it.\n\n")
	b.WriteString("| Rule | Bug | Severity | Guide |\n| --- | --- | --- | --- |\n")
	for _, r := range wantedRules {
		g, _ := RuleGuidance(r)
		b.WriteString("| [" + r + "](" + webPath() + ":wanted/" + r + ") | " + g.Title + " | " + g.Severity + " | " + g.Guide + " |\n")
	}
	b.WriteString("\n[Back to the noticeboard](" + webPath() + ")\n")
	return b.String()
}

func renderWanted(rule string) string {
	known := false
	for _, r := range wantedRules {
		known = known || r == rule
	}
	g, ok := RuleGuidance(rule)
	if !known || !ok {
		return "# Not found\n\nNo poster for that rule. [All Wanted posters](" + webPath() + ":wanted)\n"
	}
	var b strings.Builder
	b.WriteString("# WANTED: " + rule + "\n\n## " + g.Title + "\n\n")
	b.WriteString("**" + g.Severity + "** · [security guide](" + guideURL + ") " + g.Guide + "\n\n")
	b.WriteString("**What it means.** " + g.Meaning + "\n\n")
	b.WriteString(alert("CAUTION", "", "Why it is dangerous", g.Danger))
	// Bug and fix side by side, the way a poster reads.
	b.WriteString("<gno-columns>\n\n**The bug**\n\n" + sanitize.LanguageCodeBlock("go", g.Vulnerable) + "\n\n<gno-columns-sep />\n\n**The fix**\n\n")
	if g.Example != "" {
		b.WriteString(sanitize.LanguageCodeBlock("go", g.Example) + "\n\n")
	} else {
		b.WriteString(g.Fix + "\n\n")
	}
	b.WriteString("</gno-columns>\n\n")
	b.WriteString(alert("TIP", "", "How to fix it", g.Fix+"\n\n**Why it works.** "+g.Why))
	if gr, ok := groundsFor[rule]; ok {
		b.WriteString("## Practice\n\nThe [" + rule + " Training Ground](" + groundsWebPath() + "/" + gr + ") has this bug on purpose. Break it and claim your place on the hunters board.\n\n")
	}
	b.WriteString("## Caught by Bouncer\n\n")
	proven, warned, scanned := caught(rule)
	if len(proven)+len(warned) == 0 {
		b.WriteString("No package's latest scan has this finding.\n\n")
	} else {
		b.WriteString("Packages whose latest scan has this finding (PROVEN first):\n\n| Package | Label |\n| --- | --- |\n")
		n := 0
		for _, p := range proven {
			if n == maxWantedList {
				break
			}
			b.WriteString("| " + passportLink(p) + " | PROVEN |\n")
			n++
		}
		for _, p := range warned {
			if n == maxWantedList {
				break
			}
			b.WriteString("| " + passportLink(p) + " | warning |\n")
			n++
		}
		b.WriteString("\n")
	}
	if scanned == maxWantedScan {
		b.WriteString("_Only the first " + strconv.Itoa(maxWantedScan) + " Passports were read._\n\n")
	}
	b.WriteString("_" + Disclaimer + "_\n\n[All Wanted posters](" + webPath() + ":wanted)\n")
	return b.String()
}

// caught returns the packages whose latest attestation has a finding of
// rule, split by PROVEN or not, in path order, and how many it read.
func caught(rule string) (proven, warned []string, scanned int) {
	records.Iterate("", "", func(k string, v any) bool {
		if scanned == maxWantedScan {
			return true
		}
		scanned++
		h := v.(*record).history
		isProven, has := false, false
		for _, f := range h[len(h)-1].Findings {
			if f.Rule == rule {
				has = true
				isProven = isProven || f.Label == LabelProven
			}
		}
		switch {
		case isProven:
			proven = append(proven, k)
		case has:
			warned = append(warned, k)
		}
		return false
	})
	return
}
