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
	b.WriteString("_" + Disclaimer + "_\n\n")
	if successor := latestSuccessor(rec); successor != "" {
		b.WriteString("The author points to a newer version: " + passportLink(successor) + "\n\n")
	}

	b.WriteString("## Findings\n\n")
	if len(a.Findings) == 0 {
		b.WriteString("No findings with the current rules.\n\n")
	} else {
		b.WriteString("| Rule | Severity | Label | Location |\n| --- | --- | --- | --- |\n")
		for _, f := range a.Findings {
			b.WriteString("| " + f.Rule + " | " + f.Severity + " | **" + f.Label + "** | " + sanitize.InlineCode(f.File+":"+strconv.Itoa(f.Line)) + " |\n")
		}
		b.WriteString("\n")
		seen := map[string]bool{}
		for _, f := range a.Findings {
			if seen[f.Rule] {
				continue
			}
			seen[f.Rule] = true
			title, guide, fix := ruleGuidance(f.Rule)
			b.WriteString("### " + f.Rule + ": " + title + "\n\nGuide " + guide + ". **Fix:** " + fix + "\n\n")
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

	b.WriteString("## History\n\n| Date | Score | Grade | Findings | Change |\n| --- | --- | --- | --- | --- |\n")
	for i := len(rec.history) - 1; i >= 0; i-- {
		h := rec.history[i]
		change := "first scan"
		if i > 0 {
			change = diffRules(rec.history[i-1].Findings, h.Findings)
		}
		b.WriteString("| " + date(h.Time) + " | " + strconv.Itoa(h.Score) + " | " + h.Grade + " | " + strconv.Itoa(len(h.Findings)) + " | " + change + " |\n")
	}
	return b.String()
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

// diffRules describes which rules appeared or were resolved between scans.
func diffRules(prev, next []Finding) string {
	had, has := map[string]bool{}, map[string]bool{}
	for _, f := range prev {
		had[f.Rule] = true
	}
	for _, f := range next {
		has[f.Rule] = true
	}
	var parts []string
	for _, f := range prev {
		if !has[f.Rule] {
			parts = append(parts, f.Rule+" resolved")
			has[f.Rule] = true // report once
		}
	}
	for _, f := range next {
		if !had[f.Rule] {
			parts = append(parts, f.Rule+" new")
			had[f.Rule] = true
		}
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

// ruleGuidance is the fix guidance, written once per rule.
func ruleGuidance(rule string) (title, guide, fix string) {
	switch rule {
	case "B01":
		return "getter returns a pointer into state", "§5.1, §5.1a",
			"return copies or plain values, never a pointer into package state, and keep mutating methods unexported."
	case "B05":
		return "IsUser() guards an OriginSend payment", "§5.5",
			"use `cur.Previous().IsUserCall()` with the `OriginSend()` amount check; `IsUser()` also accepts `maketx run` callers that keep the coins."
	case "B03":
		return "caller-supplied callback under the realm's authority", "§3C, §5.3",
			"never invoke a caller-supplied function or interface while holding this realm's authority."
	case "B09":
		return "external Teller used without IsCanonicalTeller", "§5.4",
			"check `grc20.IsCanonicalTeller(t)` before calling a Teller passed in by a caller."
	}
	return "see the full report", "", "see the full report."
}
