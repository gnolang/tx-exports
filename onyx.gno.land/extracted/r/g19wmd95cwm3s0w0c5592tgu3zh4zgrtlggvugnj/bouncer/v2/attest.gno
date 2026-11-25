package bouncer

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// Finding is one attested finding. The detail fields (Snippet onward) are
// filled once, after Attest, by AddDetail.
type Finding struct {
	Rule     string // B01 ...
	Severity string // critical, high, medium
	Label    string // PROVEN, NOT REPRODUCED, STATIC WARNING
	File     string
	Line     int
	Func     string // enclosing function, if known

	Detailed bool   // AddDetail has run for this finding
	Snippet  string // the vulnerable code
	Attack   string // what the exploit did, one line (PROVEN only)
	Exploit  string // the attacker source that ran (PROVEN only)
	Before   string // evidence before the attack (PROVEN only)
	After    string // evidence after the attack (PROVEN only)
}

// Attestation is a scan result posted by an attester.
type Attestation struct {
	ID             uint64
	PkgPath        string
	SourceHash     string // sha256 of the scanned source, hex
	ScannerVersion string
	RulesetHash    string // hex
	Toolchain      string // gno version the exploits ran on
	ReportHash     string // sha256 of the full JSON report, hex
	ReportURI      string // where the full report lives (ipfs:// or https://)
	Findings       []Finding
	Deps           Deps
	Score          int
	Grade          string
	Verdict        string
	Attester       address
	Height         int64
	Time           int64 // unix seconds, block time
}

// AuthorReply is an author's response to a Passport.
type AuthorReply struct {
	Author    address
	Note      string
	Successor string // pkgpath of the fixed version, if any
	Height    int64
}

// record holds everything known about one package.
type record struct {
	history []Attestation // oldest first
	replies []AuthorReply
}

const (
	maxFindings = 64
	maxHistory  = 50
	maxReplies  = 20
	maxNoteLen  = 280
	maxRecent   = 10
)

// Attest records a scan result for pkgpath. Attesters only. findings is a
// ";"-separated list of "RULE,severity,LABEL,file,line[,func]" entries (""
// for none), in the report's order. deps is the import tree (see
// parseDeps). Score, grade and verdict are computed here from the findings
// and the dependencies' statuses in this registry.
func Attest(cur realm, pkgpath, sourceHash, scannerVersion, rulesetHash, toolchain, reportHash, reportURI, findings, deps string) uint64 {
	attester := assertAttester(cur)
	if !validPkgPath(pkgpath) {
		panic("invalid package path")
	}
	for _, h := range []string{sourceHash, rulesetHash, reportHash} {
		if !isHex64(h) {
			panic("hashes must be 64 lowercase hex characters")
		}
	}
	if !isToken(scannerVersion) || !isToken(toolchain) {
		panic("invalid scanner or toolchain version")
	}
	if !validReportURI(reportURI) {
		panic("report URI must be ipfs://<cid> or an https:// URL")
	}
	fs := parseFindings(findings)
	ds := parseDeps(pkgpath, deps)

	rec := getRecord(pkgpath)
	if rec == nil {
		rec = &record{}
		records.Set(pkgpath, rec)
		if author, ok := authorOf(pkgpath); ok {
			addToAuthor(author, pkgpath)
		}
		addToFamily(pkgpath)
	} else {
		if len(rec.history) >= maxHistory {
			panic("attestation history is full for this package")
		}
		prev := rec.history[len(rec.history)-1]
		totalFindings -= len(prev.Findings)
		totalProven -= countProven(prev.Findings)
	}
	id := uint64(attestationID.Next())
	a := Attestation{
		ID:             id,
		PkgPath:        pkgpath,
		SourceHash:     sourceHash,
		ScannerVersion: scannerVersion,
		RulesetHash:    rulesetHash,
		Toolchain:      toolchain,
		ReportHash:     reportHash,
		ReportURI:      reportURI,
		Findings:       fs,
		Deps:           Deps{List: ds},
		Attester:       attester,
		Height:         runtime.ChainHeight(),
		Time:           time.Now().Unix(),
	}
	// Stored values are a snapshot; reads recompute them (see live).
	snap := live(a)
	_, _, verdict := ScoreFor(fs, Deps{})
	a.Score, a.Grade, a.Verdict = snap.Score, snap.Grade, verdict
	score, grade := snap.Score, snap.Grade
	rec.history = append(rec.history, a)
	totalFindings += len(fs)
	totalProven += countProven(fs)
	markRecent(pkgpath)
	closeRequestsFor(pkgpath)
	chain.Emit("Attested",
		"id", seqid.ID(id).String(),
		"pkgpath", pkgpath,
		"score", strconv.Itoa(score),
		"grade", grade,
		"verdict", verdict,
		"report_hash", reportHash,
		"attester", attester.String())
	return id
}

func getRecord(pkgpath string) *record {
	v := records.Get(pkgpath)
	if v == nil {
		return nil
	}
	return v.(*record)
}

func addToAuthor(author address, pkgpath string) {
	var t *avl.Tree
	if v := byAuthor.Get(string(author)); v != nil {
		t = v.(*avl.Tree)
	} else {
		t = avl.NewTree()
		byAuthor.Set(string(author), t)
	}
	t.Set(pkgpath, true)
}

func markRecent(pkgpath string) {
	next := []string{pkgpath}
	for _, p := range recent {
		if p != pkgpath && len(next) < maxRecent {
			next = append(next, p)
		}
	}
	recent = next
}

func countProven(fs []Finding) int {
	n := 0
	for _, f := range fs {
		if f.Label == LabelProven {
			n++
		}
	}
	return n
}

// parseFindings validates and decodes the findings argument.
func parseFindings(s string) []Finding {
	out := []Finding{}
	if s == "" {
		return out
	}
	entries := strings.Split(s, ";")
	if len(entries) > maxFindings {
		panic("too many findings")
	}
	for _, e := range entries {
		parts := strings.Split(e, ",")
		if len(parts) != 5 && len(parts) != 6 {
			panic("finding must be RULE,severity,LABEL,file,line[,func]: " + e)
		}
		f := Finding{Rule: parts[0], Severity: parts[1], Label: parts[2], File: parts[3]}
		if !isRuleID(f.Rule) {
			panic("invalid rule id: " + f.Rule)
		}
		switch f.Severity {
		case SeverityCritical, SeverityHigh, SeverityMedium:
		default:
			panic("invalid severity: " + f.Severity)
		}
		switch f.Label {
		case LabelProven, LabelNotReproduced, LabelStaticWarning:
		default:
			panic("invalid label: " + f.Label)
		}
		if !isGnoFile(f.File) {
			panic("invalid file name: " + f.File)
		}
		line, err := strconv.Atoi(parts[4])
		if err != nil || line < 1 || line > 1000000 {
			panic("invalid line: " + parts[4])
		}
		f.Line = line
		if len(parts) == 6 {
			if !isIdent(parts[5]) {
				panic("invalid function name: " + parts[5])
			}
			f.Func = parts[5]
		}
		out = append(out, f)
	}
	return out
}

// isIdent accepts a Go identifier, optionally a method as Type.Method.
func isIdent(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, part := range strings.Split(s, ".") {
		if part == "" || part[0] >= '0' && part[0] <= '9' {
			return false
		}
		for _, c := range part {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
				return false
			}
		}
	}
	return true
}

func isRuleID(s string) bool {
	return len(s) == 3 && s[0] == 'B' && s[1] >= '0' && s[1] <= '9' && s[2] >= '0' && s[2] <= '9'
}

func isGnoFile(s string) bool {
	if len(s) > 64 || !strings.HasSuffix(s, ".gno") || len(s) == len(".gno") {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}

func isHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// isToken accepts short version strings such as "0.1.0" or "master.1+f0f9c70".
func isToken(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune(".+-_", c)) {
			return false
		}
	}
	return true
}

func validReportURI(s string) bool {
	if len(s) > 200 {
		return false
	}
	rest, ok := strings.CutPrefix(s, "ipfs://")
	if !ok {
		rest, ok = strings.CutPrefix(s, "https://")
	}
	if !ok || rest == "" {
		return false
	}
	for _, c := range rest {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("./-_~", c)) {
			return false
		}
	}
	return true
}
