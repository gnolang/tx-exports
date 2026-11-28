package bouncer

import (
	"chain"
	"strconv"
	"strings"
	"unicode/utf8"

	"gno.land/p/nt/seqid/v0"
)

// Size limits for finding details. The full report (ReportURI) has
// everything; the Passport shows what fits here.
const (
	maxSnippetLen  = 1500
	maxAttackLen   = 200
	maxExploitLen  = 6000
	maxEvidenceLen = 1500
	// maxDetailBytes caps the detail text of one attestation.
	maxDetailBytes = 32000
)

// AddDetail attaches the vulnerable snippet and, for a PROVEN finding, the
// exploit and its evidence to finding index of attestation id. Only the
// attester who posted the attestation may call it, once per finding: the
// details are as permanent as the attestation itself.
func AddDetail(cur realm, pkgpath string, id uint64, index int, snippet, attack, exploit, before, after string) {
	caller := assertAttester(cur)
	rec := getRecord(pkgpath)
	if rec == nil {
		panic("no attestation for this package")
	}
	ai := -1
	for i := range rec.history {
		if rec.history[i].ID == id {
			ai = i
			break
		}
	}
	if ai < 0 {
		panic("no such attestation for this package")
	}
	a := &rec.history[ai]
	if a.Attester != caller {
		panic("only the attestation's own attester can add details")
	}
	if index < 0 || index >= len(a.Findings) {
		panic("finding index out of range")
	}
	f := &a.Findings[index]
	if f.Detailed {
		panic("details already added for this finding")
	}
	checkText("snippet", snippet, maxSnippetLen)
	checkText("attack", attack, maxAttackLen)
	checkText("exploit", exploit, maxExploitLen)
	checkText("before", before, maxEvidenceLen)
	checkText("after", after, maxEvidenceLen)
	if strings.ContainsAny(attack, "\n\r") {
		panic("attack must be one line")
	}
	proofLen := len(attack) + len(exploit) + len(before) + len(after)
	if f.Label != LabelProven && proofLen > 0 {
		panic("only PROVEN findings carry an exploit and evidence")
	}
	if detailBytes(a.Findings)+len(snippet)+proofLen > maxDetailBytes {
		panic("detail limit reached for this attestation; see the full report")
	}
	f.Detailed = true
	f.Snippet = snippet
	f.Attack = attack
	f.Exploit = exploit
	f.Before = before
	f.After = after
	chain.Emit("DetailAdded",
		"id", seqid.ID(id).String(),
		"pkgpath", pkgpath,
		"index", strconv.Itoa(index))
}

func detailBytes(fs []Finding) int {
	n := 0
	for _, f := range fs {
		n += len(f.Snippet) + len(f.Attack) + len(f.Exploit) + len(f.Before) + len(f.After)
	}
	return n
}

// checkText rejects text that is too long, not UTF-8, or carries NUL or
// other control characters besides tab and newline.
func checkText(name, s string, max int) {
	if len(s) > max {
		panic(name + " is too long (max " + strconv.Itoa(max) + " bytes)")
	}
	if !utf8.ValidString(s) {
		panic(name + " must be valid UTF-8")
	}
	for _, c := range s {
		if c < 0x20 && c != '\n' && c != '\t' || c == 0x7f {
			panic(name + " contains a control character")
		}
	}
}
