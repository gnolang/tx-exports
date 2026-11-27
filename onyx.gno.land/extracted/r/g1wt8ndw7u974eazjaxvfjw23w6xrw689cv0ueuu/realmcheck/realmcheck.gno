// Package realmcheck is the on-chain report store for RealmCheck, the
// Gno.land realm auditor built for the Gnome Tavern Hackathon.
//
// Audits run off chain: the UI runs the audit-rules package against a
// realm's source text. Their results are stored here, so any report is
// public, shareable, and verifiable. The stored source hash lets anyone
// re-run the audit against the same source and compare. This realm never
// audits; it only stores, indexes, and renders reports.
//
// Deploy order: deploy the audit-rules package first, then this realm,
// because this realm imports it.
package realmcheck

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/g1wt8ndw7u974eazjaxvfjw23w6xrw689cv0ueuu/auditrules"
)

// reports holds every stored report by numeric ID.
var reports = map[int]auditrules.Report{}

// latestByRealm maps a realm path to its newest report ID.
var latestByRealm = map[string]int{}

// nextID is the ID the next stored report gets.
var nextID = 1

// maxReportsShown caps how many reports Render lists.
const maxReportsShown = 20

// SubmitReport stores one audit report and returns its numeric ID.
//
// findings is one finding per line, fields separated by "|":
// RULEID|Severity|Line|Title|Description|SourceLine
// A malformed line is skipped, never fatal, so a stored report stays
// readable even when one line is bad. The severity stored for a finding
// is the catalog severity of its rule when the encoded severity is not
// one of the four known values.
//
// The caller address is recorded as Auditor, and the current block
// height is recorded as Height.
func SubmitReport(cur realm, realmPath string, sourceHash string, score int, findings string) int {
	if realmPath == "" {
		panic("realm path must not be empty")
	}
	if !isSafeRealmPath(realmPath) {
		panic("realm path must be a gno.land path with safe characters")
	}
	if !isHexHash(sourceHash) {
		panic("source hash must be a hex string of at most 128 characters")
	}
	if score < 0 || score > 100 {
		panic("score must be between 0 and 100")
	}
	parsed := parseFindings(findings)
	report := auditrules.Report{
		ID:         nextID,
		RealmPath:  realmPath,
		SourceHash: sourceHash,
		Score:      score,
		Auditor:    string(cur.Previous().Address()),
		Height:     runtime.ChainHeight(),
		Findings:   parsed,
	}
	reports[nextID] = report
	latestByRealm[realmPath] = nextID
	nextID++
	return report.ID
}

// isSafeRealmPath reports whether p looks like a realm path: it must start
// with gno.land/ and contain only letters, digits, slash, dot, underscore,
// and hyphen. This keeps Render output safe: a path with newlines or
// markdown could otherwise inject lines into the rendered page, and Render
// receives attacker-controlled input.
func isSafeRealmPath(p string) bool {
	if !strings.HasPrefix(p, "gno.land/") {
		return false
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '/' || c == '.' || c == '_' || c == '-' {
			continue
		}
		return false
	}
	return true
}

// isHexHash reports whether s is a hex string of at most 128 characters,
// which is the shape of a source hash (SHA-256 is 64 hex characters).
func isHexHash(s string) bool {
	if s == "" || len(s) > 128 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
			continue
		}
		return false
	}
	return true
}

// parseFindings decodes the findings encoding into a slice of findings.
func parseFindings(encoded string) []auditrules.Finding {
	trimmed := strings.TrimSpace(encoded)
	if trimmed == "" {
		return []auditrules.Finding{}
	}
	lines := strings.Split(trimmed, "\n")
	out := make([]auditrules.Finding, 0, len(lines))
	for _, line := range lines {
		parts := strings.Split(line, "|")
		if len(parts) != 6 {
			continue
		}
		rule, ok := auditrules.RuleByID(strings.TrimSpace(parts[0]))
		if !ok {
			continue
		}
		sev := auditrules.Severity(strings.TrimSpace(parts[1]))
		if sev != auditrules.SeverityCritical && sev != auditrules.SeverityHigh &&
			sev != auditrules.SeverityMedium && sev != auditrules.SeverityLow {
			sev = rule.Severity
		}
		lineNo, err := strconv.Atoi(strings.TrimSpace(parts[2]))
		if err != nil || lineNo < 1 {
			continue
		}
		out = append(out, auditrules.Finding{
			RuleID:      rule.ID,
			Severity:    sev,
			Title:       strings.TrimSpace(parts[3]),
			Description: strings.TrimSpace(parts[4]),
			Line:        lineNo,
			SourceLine:  strings.TrimSpace(parts[5]),
		})
	}
	return out
}

// ReportFindings returns the findings of the stored report with the given
// ID, one finding per line in the same "RULEID|Severity|Line|Title|
// Description|SourceLine" encoding SubmitReport accepts. It exists because
// the chain query printers show slices as references, not values, so a UI
// cannot read the findings list from GetReport directly. It returns "" for
// an unknown ID.
func ReportFindings(id int) string {
	r, ok := reports[id]
	if !ok {
		return ""
	}
	out := ""
	for i, f := range r.Findings {
		if i > 0 {
			out += "\n"
		}
		out += f.RuleID + "|" + string(f.Severity) + "|" + strconv.Itoa(f.Line) + "|" + f.Title + "|" + f.Description + "|" + f.SourceLine
	}
	return out
}

// GetReport returns the stored report with the given ID.
func GetReport(id int) (auditrules.Report, bool) {
	r, ok := reports[id]
	return r, ok
}

// LatestReport returns the newest stored report for a realm path.
func LatestReport(realmPath string) (auditrules.Report, bool) {
	id, ok := latestByRealm[realmPath]
	if !ok {
		return auditrules.Report{}, false
	}
	return GetReport(id)
}

// ReportCount returns how many reports are stored.
func ReportCount() int {
	return len(reports)
}

// Render returns a Markdown page listing recent reports, newest first.
func Render(path string) string {
	out := "# RealmCheck reports\n\n"
	out += "On-chain audit reports. Each report cites the realm path, the risk score, the finding count, and the auditor.\n\n"
	if len(reports) == 0 {
		return out + "No reports stored yet.\n"
	}
	shown := 0
	for id := nextID - 1; id >= 1 && shown < maxReportsShown; id-- {
		r, ok := reports[id]
		if !ok {
			continue
		}
		out += "- #" + strconv.Itoa(r.ID) + " " + r.RealmPath +
			" score " + strconv.Itoa(r.Score) +
			", " + strconv.Itoa(len(r.Findings)) + " findings" +
			", auditor " + r.Auditor + "\n"
		shown++
	}
	return out
}
