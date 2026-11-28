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
//	"hunters"          link to the Training Grounds hunters board
//	"wanted"           Wanted posters: every bug class
//	"wanted/<rule>"    one bug class: the bug, the fix, where it was caught
//	"census"           aggregate numbers from scanning a network's most active realms
func Render(path string) string {
	if pkgpath, ok := strings.CutPrefix(path, "realm/"); ok {
		return renderPassport(pkgpath)
	}
	if path == "" {
		return renderNoticeboard()
	}
	if path == "wanted" {
		return renderWantedIndex()
	}
	if rule, ok := strings.CutPrefix(path, "wanted/"); ok {
		return renderWanted(rule)
	}
	if path == "census" {
		return renderCensus()
	}
	if path == "hunters" {
		return "# Hunters\n\nThe hunters board lives with the Training Grounds, which this registry does not import: " +
			"a deliberately vulnerable target must never count as one of Bouncer's own dependencies.\n\n" +
			"[Open the hunters board](" + groundsWebPath() + ")\n"
	}
	return "# Not found\n\n[Back to the noticeboard](" + webPath() + ")\n"
}

// groundsWebPath is the Training Grounds' gnoweb path: "grounds" next to
// this realm's /vN, in the same namespace.
func groundsWebPath() string {
	p := webPath()
	return p[:strings.LastIndex(p, "/")] + "/grounds"
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
	b.WriteString("# Bouncer\n\n**No exploit, no claim.** Bouncer checks Gno realms against the Gno security guide, proves serious bugs with a working attacker realm, and records the verdict here.\n\n" +
		"**How it works:** request a scan below → the bot scans and runs an attacker realm against the code → the Passport shows each bug, its proof and its fix → the fixed `/vN` is scanned again → other realms call `Check()` and refuse what fails.\n\n")
	b.WriteString("| Passports | Findings | PROVEN | Open requests |\n| --- | --- | --- | --- |\n")
	b.WriteString("| " + strconv.Itoa(records.Size()) + " | " + strconv.Itoa(totalFindings) + " | " + strconv.Itoa(totalProven) + " | " + strconv.Itoa(openByRequester.Size()) + " |\n\n")

	b.WriteString("## Recent Passports\n\n")
	if len(recent) == 0 {
		b.WriteString("No packages attested yet.\n\n")
	} else {
		b.WriteString("| Package | Score | Grade | Verdict |\n| --- | --- | --- | --- |\n")
		for _, p := range recent {
			a, _ := Latest(p)
			b.WriteString("| " + passportLink(p) + " | " + strconv.Itoa(a.Score) + " | " + a.Grade + " | " + verdictText(a.Verdict) + " |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## Wanted\n\nThe bug classes Bouncer hunts, with the fix for each: [Wanted posters](" + webPath() + ":wanted).\n\n")
	if hasCensus {
		b.WriteString("## Census\n\nBouncer scanned the " + strconv.Itoa(census.Ranked) + " most active realms on " + sanitize.InlineCode(census.Network) + ": " +
			strconv.Itoa(census.CriticalOrHigh) + " have a Critical or High finding. [Aggregate numbers](" + webPath() + ":census), no names.\n\n")
	}
	b.WriteString("## Training Grounds\n\nPractice targets with a real bug each. Break one, claim it, and land on the [hunters board](" + groundsWebPath() + ").\n\n")
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
	a, _ := Latest(pkgpath)

	b.WriteString("## " + strconv.Itoa(a.Score) + " / 100 · Grade " + a.Grade + " · " + verdictText(a.Verdict) + "\n\n")
	b.WriteString(Badge(pkgpath) + "\n\n")
	b.WriteString(verdictAlert(a, pkgpath))
	if a.Disputed {
		b.WriteString("> ⚠️ **Disputed.** A re-scan produced a different report from this attestation. Policies that do not allow disputed attestations (such as `Strict()`) refuse it until it is attested again.\n\n")
	}
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
	b.WriteString("\n")
	renderDeps(&b, a.Deps)

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

	if ds := recentDisputes(pkgpath, maxShownDisputes); len(ds) > 0 {
		b.WriteString("## Disputes\n\n")
		total := DisputeCount(pkgpath)
		b.WriteString(strconv.Itoa(OpenDisputes(pkgpath)) + " open of " + strconv.Itoa(total) + " filed.")
		if total > len(ds) {
			b.WriteString(" The newest " + strconv.Itoa(len(ds)) + " are shown.")
		}
		b.WriteString(" An open dispute asks for a re-scan and changes no score or policy by itself; it is upheld only if the re-scan's report differs from the attested one.")
		b.WriteString("\n\n| Filer | Report | Note | Status |\n| --- | --- | --- | --- |\n")
		for _, d := range ds {
			status := "⏳ open: waiting for a re-scan"
			switch d.Status {
			case DisputeUpheld:
				status = "⚠️ upheld: " + sanitize.TableCell(d.Resolution)
			case DisputeRejected:
				status = "rejected: " + sanitize.TableCell(d.Resolution)
			case DisputeClosed:
				status = "closed: " + sanitize.TableCell(d.Resolution)
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
			h := live(rec.history[i])
			change := "first scan"
			if i > 0 {
				change = diffFindings(rec.history[i-1].Findings, h.Findings)
			}
			b.WriteString("| " + date(h.Time) + " | " + strconv.Itoa(h.Score) + " | " + h.Grade + " | " + strconv.Itoa(len(h.Findings)) + " | " + change + " |\n")
		}
	}
	return b.String()
}

// alert renders a gnoweb alert block: kind is NOTE, TIP, SUCCESS, WARNING,
// CAUTION...; fold "-" renders it collapsed. title and body are trusted
// Markdown built here (user text in them must already be sanitized).
func alert(kind, fold, title, body string) string {
	var b strings.Builder
	b.WriteString("> [!" + kind + "]" + fold + " " + title + "\n>\n")
	for _, line := range strings.Split(strings.TrimRight(body, "\n"), "\n") {
		if line == "" {
			b.WriteString(">\n")
		} else {
			b.WriteString("> " + line + "\n")
		}
	}
	return b.String() + "\n"
}

// verdictAlert is the Passport's summary: what was found, in a sentence,
// and what an integrator should do.
func verdictAlert(a Attestation, pkgpath string) string {
	// Neighbours in the package's /vN family: the version this one fixes,
	// and a newer one to point readers of a red Passport to.
	var prev, newer string
	vs := Versions(pkgpath)
	for i, v := range vs {
		if v != pkgpath {
			continue
		}
		if i > 0 {
			prev = vs[i-1]
		}
		for _, w := range vs[i+1:] {
			h := getRecord(w).history
			if live(h[len(h)-1]).Verdict == VerdictClear {
				newer = w
			}
		}
	}
	resolved := ""
	if prev != "" {
		h := getRecord(prev).history
		var gone []string
		for _, part := range strings.Split(diffFindings(h[len(h)-1].Findings, a.Findings), ", ") {
			if rule, ok := strings.CutSuffix(part, " resolved"); ok {
				gone = append(gone, rule)
			}
		}
		if len(gone) > 0 {
			verb := " was PROVEN there and is gone here."
			list := gone[0]
			if len(gone) > 1 {
				verb = " were PROVEN there and are gone here."
				list = strings.Join(gone[:len(gone)-1], ", ") + " and " + gone[len(gone)-1]
			}
			resolved = "\n\n**Fixed since " + passportLink(prev) + ":** " + list + verb
		}
	}
	proven, warnings := 0, 0
	var first Finding
	for _, f := range a.Findings {
		if f.Label == LabelProven {
			if proven == 0 {
				first = f
			}
			proven++
		} else {
			warnings++
		}
	}
	count := func(n int, one, many string) string {
		if n == 1 {
			return "1 " + one
		}
		return strconv.Itoa(n) + " " + many
	}
	switch a.Verdict {
	case VerdictNotRecommended:
		body := "Bouncer ran a working exploit against this exact source: " + first.Rule + " (" + first.Severity + ") at " + sanitize.InlineCode(location(first)) + ". " +
			count(proven, "finding is", "findings are") + " PROVEN"
		if warnings > 0 {
			body += ", " + count(warnings, "more is a warning", "more are warnings")
		}
		body += ".\n\n**Do not integrate this version.** Every Bouncer policy refuses it. The fix for each finding is below."
		if newer != "" {
			body += "\n\nA newer version, " + passportLink(newer) + ", has no known Critical or High issues."
		}
		return alert("CAUTION", "", "Not recommended for integration", body)
	case VerdictReview:
		return alert("WARNING", "", "Review before integration",
			count(warnings, "Critical or High warning", "warnings")+" matched a known bug pattern, but Bouncer has no working exploit for "+
				map[bool]string{true: "it", false: "them"}[warnings == 1]+". Read each finding below before you integrate."+resolved)
	}
	body := "Bouncer's " + strconv.Itoa(len(wantedRules)) + " rules found nothing Critical or High in this exact source."
	if len(a.Findings) > 0 {
		body += " " + count(len(a.Findings), "lower-severity finding is", "lower-severity findings are") + " listed below."
	}
	body += resolved
	return alert("SUCCESS", "", "No known Critical or High issues", body)
}

// maxShownDisputes caps the disputes a Passport lists: anyone can file
// one, so the page must not grow with them.
const maxShownDisputes = 10

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
	rule := f.Rule
	for _, r := range wantedRules {
		if r == f.Rule {
			rule = "[" + f.Rule + "](" + webPath() + ":wanted/" + f.Rule + ")"
		}
	}
	b.WriteString("### " + strconv.Itoa(n) + ". " + rule + ": " + title + "\n\n")
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
			lines := strconv.Itoa(strings.Count(strings.TrimRight(f.Exploit, "\n"), "\n") + 1)
			b.WriteString(alert("NOTE", "-", "The attacker realm ("+lines+" lines)",
				"Lines that print Bouncer's evidence markers are left out; the full report has the exact source.\n\n"+sanitize.LanguageCodeBlock("go", f.Exploit)))
		}
		if f.Before != "" || f.After != "" {
			b.WriteString("Only the lines that changed are shown; `...` marks lines left out. The full report has the complete output.\n\n")
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
		a := live(cur[len(cur)-1])
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

// renderDeps shows dependency trust as it stands now, direct first.
func renderDeps(b *strings.Builder, d Deps) {
	b.WriteString("## Dependencies\n\n")
	if len(d.List) == 0 {
		b.WriteString("No `gno.land` imports.\n\n")
		return
	}
	b.WriteString(strconv.Itoa(d.DirectAtRisk) + " direct at risk, " + strconv.Itoa(d.IndirectAtRisk) + " indirect at risk, " +
		strconv.Itoa(d.Unverified) + " unverified. A dependency at risk does not mean this package is exploitable; " +
		"an unverified one has not been scanned yet, which is not a finding.\n\n")
	b.WriteString("| Dependency | Import | Status |\n| --- | --- | --- |\n")
	for _, direct := range []bool{true, false} {
		for _, dep := range d.List {
			if dep.Direct != direct {
				continue
			}
			kind := "indirect"
			if direct {
				kind = "direct"
			}
			b.WriteString("| " + passportLink(dep.Path) + " | " + kind + " | " + depStatusText(dep.Status) + " |\n")
		}
	}
	b.WriteString("\n")
}

func depStatusText(s string) string {
	switch s {
	case DepVerified:
		return "🟢 Verified"
	case DepAtRisk:
		return "🔴 At risk"
	}
	return "⚪ Unverified"
}
