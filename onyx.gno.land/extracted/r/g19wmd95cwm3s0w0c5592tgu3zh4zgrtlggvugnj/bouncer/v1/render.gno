package bouncer

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// Render serves the Tavern pages:
//
//	""                 Noticeboard
//	"realm/<pkgpath>"  Passport
func Render(path string) string {
	if pkgpath, ok := strings.CutPrefix(path, "realm/"); ok {
		return renderPassport(pkgpath)
	}
	if path == "" {
		return renderNoticeboard()
	}
	return "# Not found\n\n[Back to the noticeboard](" + webPath() + ")\n"
}

// webPath is this realm's gnoweb URL path ("/r/...").
func webPath() string {
	return strings.TrimPrefix(selfPath, "gno.land")
}

// passportLink links to pkgpath's Passport. pkgpath is a validated path
// (lowercase letters, digits, underscores and slashes), so it is URL-safe.
func passportLink(pkgpath string) string {
	return "[" + sanitize.InlineCode(pkgpath) + "](" + webPath() + ":realm/" + pkgpath + ")"
}

func verdictText(v string) string {
	switch v {
	case VerdictNotRecommended:
		return "🔴 Not recommended for integration"
	case VerdictReview:
		return "🟠 Review before integration"
	}
	return "🟢 No known Critical or High issues"
}

func date(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02")
}

func renderNoticeboard() string {
	var b strings.Builder
	b.WriteString("# Bouncer\n\n**No exploit, no claim.** Bouncer checks Gno realms against the Gno security guide, proves serious bugs with a working attacker realm, and records the verdict here.\n\n")
	b.WriteString("| Passports | Findings | PROVEN | Open requests |\n| --- | --- | --- | --- |\n")
	b.WriteString("| " + strconv.Itoa(records.Size()) + " | " + strconv.Itoa(totalFindings) + " | " + strconv.Itoa(totalProven) + " | " + strconv.Itoa(openByRequester.Size()) + " |\n\n")

	b.WriteString("## Recent Passports\n\n")
	if len(recent) == 0 {
		b.WriteString("No packages attested yet.\n\n")
	} else {
		b.WriteString("| Package | Score | Grade | Verdict |\n| --- | --- | --- | --- |\n")
		for _, p := range recent {
			a := getRecord(p).history[len(getRecord(p).history)-1]
			b.WriteString("| " + passportLink(p) + " | " + strconv.Itoa(a.Score) + " | " + a.Grade + " | " + verdictText(a.Verdict) + " |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## Request a scan\n\nOne open request per address. The scanner bot picks it up, scans and proves, then posts the result.\n\n")
	b.WriteString("<gno-form exec=\"RequestScan\">\n<gno-input name=\"pkgpath\" placeholder=\"gno.land/r/<address>/myrealm\" />\n</gno-form>\n\n")
	b.WriteString("_" + Disclaimer + "_\n")
	return b.String()
}

func renderPassport(pkgpath string) string {
	if !validPkgPath(pkgpath) {
		return "# Not found\n\nThat is not a valid package path.\n"
	}
	rec := getRecord(pkgpath)
	var b strings.Builder
	b.WriteString("# Passport: " + sanitize.InlineCode(pkgpath) + "\n\n")
	if rec == nil {
		b.WriteString("Bouncer has not attested this package yet. [Request a scan](" + webPath() + ").\n")
		return b.String()
	}
	a := rec.history[len(rec.history)-1]

	b.WriteString("## " + strconv.Itoa(a.Score) + " / 100 · Grade " + a.Grade + " · " + verdictText(a.Verdict) + "\n\n")
	b.WriteString(Badge(pkgpath) + "\n\n")
	b.WriteString("_" + Disclaimer + "_\n\n")
	if successor := latestSuccessor(rec); successor != "" {
		b.WriteString("The author points to a newer version: " + passportLink(successor) + "\n\n")
	}

	b.WriteString("## Findings\n\n")
	if len(a.Findings) == 0 {
		b.WriteString("No findings with the current rules.\n\n")
	} else {
		b.WriteString("| # | Rule | Severity | Label | Location |\n| --- | --- | --- | --- | --- |\n")
		for i, f := range a.Findings {
			b.WriteString("| " + strconv.Itoa(i+1) + " | " + f.Rule + " | " + f.Severity + " | **" + f.Label + "** | " + sanitize.InlineCode(location(f)) + " |\n")
		}
		b.WriteString("\n")
		for i, f := range a.Findings {
			renderFinding(&b, i+1, f)
		}
	}

	b.WriteString("## Attestation\n\n| | |\n| --- | --- |\n")
	row := func(k, v string) { b.WriteString("| " + k + " | " + v + " |\n") }
	row("Attested", date(a.Time)+" (block "+strconv.FormatInt(a.Height, 10)+")")
	row("Attester", sanitize.InlineCode(a.Attester.String()))
	row("Source hash", sanitize.InlineCode(a.SourceHash))
	row("Scanner", sanitize.InlineCode(a.ScannerVersion)+", rule set "+sanitize.InlineCode(a.RulesetHash[:12]))
	row("Gno toolchain", sanitize.InlineCode(a.Toolchain))
	if u := reportURL(a.ReportURI); u != "" {
		row("Full report", "[report]("+u+"), hash "+sanitize.InlineCode(a.ReportHash[:12]))
	}
	row("Dependencies", strconv.Itoa(a.Deps.DirectAtRisk)+" direct at risk, "+strconv.Itoa(a.Deps.IndirectAtRisk)+" indirect at risk, "+strconv.Itoa(a.Deps.Unverified)+" unverified")
	b.WriteString("\n")

	if len(rec.replies) > 0 {
		b.WriteString("## Author replies\n\n")
		for _, r := range rec.replies {
			b.WriteString("- " + sanitize.InlineText(r.Note))
			if r.Successor != "" {
				b.WriteString(" (fixed version: " + passportLink(r.Successor) + ")")
			}
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}

	if ds := DisputesFor(pkgpath); len(ds) > 0 {
		b.WriteString("## Disputes\n\n| Filer | Report | Note | Status |\n| --- | --- | --- | --- |\n")
		for _, d := range ds {
			status := "open"
			if d.Resolved {
				status = "resolved: " + sanitize.TableCell(d.Resolution)
			}
			b.WriteString("| " + sanitize.InlineCode(d.Filer.String()) + " | " + sanitize.InlineCode(d.ReportHash[:12]) + " | " + sanitize.TableCell(d.Note) + " | " + status + " |\n")
		}
		b.WriteString("\n")
	}

	renderVersions(&b, pkgpath)

	b.WriteString("## Badge\n\nShow this live badge on your realm's page by adding one line to its `Render`:\n\n")
	b.WriteString(sanitize.LanguageCodeBlock("go", "out += bouncer.Badge(\""+pkgpath+"\") // import \""+selfPath+"\"") + "\n\n")

	if len(rec.history) > 1 {
		b.WriteString("## Scans of this version\n\n| Date | Score | Grade | Findings | Change |\n| --- | --- | --- | --- | --- |\n")
		for i := len(rec.history) - 1; i >= 0; i-- {
			h := rec.history[i]
			change := "first scan"
			if i > 0 {
				change = diffFindings(rec.history[i-1].Findings, h.Findings)
			}
			b.WriteString("| " + date(h.Time) + " | " + strconv.Itoa(h.Score) + " | " + h.Grade + " | " + strconv.Itoa(len(h.Findings)) + " | " + change + " |\n")
		}
	}
	return b.String()
}

// location is "file:line in Func".
func location(f Finding) string {
	loc := f.File + ":" + strconv.Itoa(f.Line)
	if f.Func != "" {
		loc += " in " + f.Func + "()"
	}
	return loc
}

// renderFinding writes one finding: what it means, why it is dangerous, the
// vulnerable code, the fix and why it works, and the exploit if PROVEN.
func renderFinding(b *strings.Builder, n int, f Finding) {
	g, known := RuleGuidance(f.Rule)
	title := g.Title
	if !known {
		title = "see the full report"
	}
	b.WriteString("### " + strconv.Itoa(n) + ". " + f.Rule + ": " + title + "\n\n")
	b.WriteString("**" + f.Label + "** · " + f.Severity + " · " + sanitize.InlineCode(location(f)))
	if g.Guide != "" {
		b.WriteString(" · security guide " + g.Guide)
	}
	b.WriteString("\n\n")
	if known {
		b.WriteString("**What it means.** " + g.Meaning + "\n\n")
		b.WriteString("**Why it is dangerous.** " + g.Danger + "\n\n")
	}
	if f.Snippet != "" {
		b.WriteString("**Vulnerable code** (" + sanitize.InlineCode(f.File) + "):\n\n" + sanitize.LanguageCodeBlock("go", f.Snippet) + "\n\n")
	}
	if known {
		b.WriteString("**Fix.** " + g.Fix + "\n\n")
		if g.Example != "" {
			b.WriteString(sanitize.LanguageCodeBlock("go", g.Example) + "\n\n")
		}
		b.WriteString("**Why it works.** " + g.Why + "\n\n")
	}
	switch f.Label {
	case LabelProven:
		b.WriteString("**Proof.** Bouncer wrote an attacker realm and ran it against this exact source")
		if f.Attack != "" {
			b.WriteString(": " + sanitize.InlineText(f.Attack))
		}
		b.WriteString(".\n\n")
		if f.Exploit != "" {
			b.WriteString("Attacker realm (lines that print Bouncer's evidence markers are left out; the full report has the exact source):\n\n" + sanitize.LanguageCodeBlock("go", f.Exploit) + "\n\n")
		}
		if f.Before != "" || f.After != "" {
			b.WriteString("<gno-columns>\n\n**Before the attack**\n\n" + sanitize.CodeBlock(f.Before) +
				"\n\n<gno-columns-sep />\n\n**After the attack**\n\n" + sanitize.CodeBlock(f.After) + "\n\n</gno-columns>\n\n")
		}
	case LabelNotReproduced:
		b.WriteString("**Not reproduced.** Bouncer's generated exploit did not land. This stays a warning: it is not evidence that the code is safe.\n\n")
	default:
		b.WriteString("**Static warning.** The pattern matched, and Bouncer has no exploit generator for this rule yet.\n\n")
	}
}

// renderVersions lists every attested version of the package, newest first,
// with what changed from the version before it.
func renderVersions(b *strings.Builder, pkgpath string) {
	vs := Versions(pkgpath)
	if len(vs) < 2 {
		return
	}
	b.WriteString("## Versions\n\nPackages on Gno cannot be overwritten, so each fix ships at a new path. Latest scan of each version:\n\n")
	b.WriteString("| Version | Score | Grade | Verdict | Change from the version before |\n| --- | --- | --- | --- | --- |\n")
	for i := len(vs) - 1; i >= 0; i-- {
		cur := getRecord(vs[i]).history
		a := cur[len(cur)-1]
		change := "first version scanned"
		if i > 0 {
			prev := getRecord(vs[i-1]).history
			change = diffFindings(prev[len(prev)-1].Findings, a.Findings)
		}
		name := passportLink(vs[i])
		if vs[i] == pkgpath {
			name = "**" + name + "** (this page)"
		}
		b.WriteString("| " + name + " | " + strconv.Itoa(a.Score) + " | " + a.Grade + " | " + verdictText(a.Verdict) + " | " + change + " |\n")
	}
	b.WriteString("\n")
}

// latestSuccessor returns the newest successor an author named.
func latestSuccessor(rec *record) string {
	for i := len(rec.replies) - 1; i >= 0; i-- {
		if rec.replies[i].Successor != "" {
			return rec.replies[i].Successor
		}
	}
	return ""
}

// diffFindings describes which rules disappeared or appeared between two
// scans. A rule that was PROVEN and is gone is "resolved"; a warning that is
// gone is only "no longer detected", since a missing warning proves nothing.
func diffFindings(prev, next []Finding) string {
	had, has := map[string]bool{}, map[string]bool{}
	proven := map[string]bool{}
	for _, f := range prev {
		had[f.Rule] = true
		if f.Label == LabelProven {
			proven[f.Rule] = true
		}
	}
	for _, f := range next {
		has[f.Rule] = true
	}
	var parts []string
	done := map[string]bool{}
	for _, f := range prev {
		if has[f.Rule] || done[f.Rule] {
			continue
		}
		done[f.Rule] = true
		if proven[f.Rule] {
			parts = append(parts, f.Rule+" resolved")
		} else {
			parts = append(parts, f.Rule+" no longer detected")
		}
	}
	for _, f := range next {
		if had[f.Rule] || done[f.Rule] {
			continue
		}
		done[f.Rule] = true
		parts = append(parts, f.Rule+" new")
	}
	if len(parts) == 0 {
		return "no rule changes"
	}
	return strings.Join(parts, ", ")
}

// reportURL turns a stored report URI into a safe link target. IPFS URIs
// go through the IPFS gateway gnoweb itself uses, since links need https.
func reportURL(uri string) string {
	if cid, ok := strings.CutPrefix(uri, "ipfs://"); ok {
		uri = "https://ipfs.filebase.io/ipfs/" + cid
	}
	return sanitize.URL(uri)
}
