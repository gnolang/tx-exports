// Package board is Assayer's on-chain report board.
//
// The assayer CLI audits a realm before deploy (logic bugs, state layout,
// gas and storage cost) and posts the result here with Submit. Every report
// is kept, versioned per package path, so anyone can see on gnoweb whether a
// realm got safer, cheaper or more expensive between deploys.
//
// The board follows its own advice: all state lives in avl trees, inputs are
// size-capped and Render is paginated.
package board

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// Input limits. They keep one submission from bloating the realm's storage.
const (
	MaxPkgPathLen  = 256
	MaxToolLen     = 32
	MaxFuncs       = 32
	MaxFindings    = 64
	MaxNameLen     = 64
	MaxFileLen     = 64
	SourceHashLen  = 64 // hex sha256
	maxFieldsInput = 8192
	maxScoresInput = 32
)

var validClasses = map[string]bool{
	"O(1)": true, "O(log n)": true, "O(n)": true,
	"O(n log n)": true, "O(n^2)": true, "?": true,
}

var validSeverities = map[string]bool{
	"critical": true, "high": true, "medium": true, "low": true, "info": true,
}

// FuncBench is the measured cost of one function or Render path.
type FuncBench struct {
	Name         string // "Post", "Render:" (Render with its path)
	Class        string // fitted complexity, e.g. "O(n)"
	MaxN         int    // largest state size measured
	GasAtMaxN    int64  // gas used at MaxN
	GasPerItem   int64  // marginal gas per extra entry at MaxN
	StorageBytes int64  // storage delta of one call at MaxN
}

// Finding is one static-analysis result with its source location.
type Finding struct {
	Rule     string
	Severity string
	File     string
	Line     int
}

// Report is one benchmark submission.
type Report struct {
	ID         int
	PkgPath    string
	Version    int // 1-based, per PkgPath
	SourceHash string
	Tool       string
	Submitter  address
	Height     int64

	Overall  int
	Security int // logic bugs and access control
	State    int // state layout and storage growth
	Cost     int // measured gas
	Quality  int // tests, docs

	Funcs    []FuncBench
	Findings []Finding
}

var (
	reports = avl.NewTree() // padded id -> *Report
	byPkg   = avl.NewTree() // pkgPath -> *avl.Tree (padded version -> *Report)
	seen    = avl.NewTree() // pkgPath|hash|submitter -> id
	nextID  = 1
)

// Submit stores a benchmark report and returns its id.
//
//	scores:   "overall,security,state,cost,quality" (each 0-100)
//	funcs:    "name|class|maxN|gasAtMaxN|gasPerItem|storageBytes;..."
//	findings: "rule|severity|file|line;..."
//
// The assayer CLI builds these strings for you (assayer submit).
// A submitter can post a given source hash of a package only once.
func Submit(cur realm, pkgPath, sourceHash, tool, scores, funcs, findings string) int {
	caller := cur.Previous().Address()

	if pkgPath == "" || len(pkgPath) > MaxPkgPathLen || !strings.HasPrefix(pkgPath, "gno.land/") {
		panic("invalid pkgPath")
	}
	if !isHex(sourceHash) || len(sourceHash) != SourceHashLen {
		panic("sourceHash must be 64 hex chars")
	}
	if len(tool) > MaxToolLen {
		panic("tool too long")
	}
	if len(scores) > maxScoresInput || len(funcs) > maxFieldsInput || len(findings) > maxFieldsInput {
		panic("input too large")
	}

	// Validate every field before touching state, so a bad submission always
	// gets the error that describes it.
	s := parseScores(scores)
	fb := parseFuncs(funcs)
	fs := parseFindings(findings)

	key := pkgPath + "|" + sourceHash + "|" + caller.String()
	if seen.Has(key) {
		panic("report already submitted for this source")
	}

	r := &Report{
		ID:         nextID,
		PkgPath:    pkgPath,
		SourceHash: sourceHash,
		Tool:       tool,
		Submitter:  caller,
		Height:     runtime.ChainHeight(),
		Overall:    s[0],
		Security:   s[1],
		State:      s[2],
		Cost:       s[3],
		Quality:    s[4],
		Funcs:      fb,
		Findings:   fs,
	}

	var versions *avl.Tree
	if v, ok := byPkg.Get(pkgPath).(*avl.Tree); ok {
		versions = v
	} else {
		versions = avl.NewTree()
		byPkg.Set(pkgPath, versions)
	}
	r.Version = versions.Size() + 1
	versions.Set(pad(r.Version), r)

	reports.Set(pad(r.ID), r)
	seen.Set(key, r.ID)
	nextID++

	chain.Emit("ReportSubmitted",
		"id", strconv.Itoa(r.ID),
		"pkgpath", pkgPath,
		"version", strconv.Itoa(r.Version),
		"overall", strconv.Itoa(r.Overall),
	)
	return r.ID
}

// GetReport returns a report by id, or nil.
func GetReport(id int) *Report {
	r, _ := reports.Get(pad(id)).(*Report)
	return r
}

// Latest returns the newest report for pkgPath, or nil.
func Latest(pkgPath string) *Report {
	versions := versionsOf(pkgPath)
	if versions == nil || versions.Size() == 0 {
		return nil
	}
	_, v := versions.GetByIndex(versions.Size() - 1)
	return v.(*Report)
}

// LatestScore returns the newest overall score for pkgPath and whether one
// exists. Other realms can import board and gate on it.
func LatestScore(pkgPath string) (int, bool) {
	r := Latest(pkgPath)
	if r == nil {
		return 0, false
	}
	return r.Overall, true
}

// Count returns the number of stored reports.
func Count() int { return reports.Size() }

// PackageCount returns the number of distinct package paths benchmarked.
func PackageCount() int { return byPkg.Size() }

func versionsOf(pkgPath string) *avl.Tree {
	v := byPkg.Get(pkgPath)
	if v == nil {
		return nil
	}
	return v.(*avl.Tree)
}

// ---- parsing ----

func parseScores(s string) [5]int {
	var out [5]int
	parts := strings.Split(s, ",")
	if len(parts) != 5 {
		panic("scores must have 5 values")
	}
	for i, p := range parts {
		out[i] = mustInt(p, 0, 100, "score")
	}
	return out
}

func parseFuncs(s string) []FuncBench {
	if s == "" {
		return nil
	}
	entries := strings.Split(s, ";")
	if len(entries) > MaxFuncs {
		panic("too many funcs")
	}
	out := make([]FuncBench, 0, len(entries))
	for _, e := range entries {
		f := strings.Split(e, "|")
		if len(f) != 6 {
			panic("func entry needs 6 fields: " + e)
		}
		if f[0] == "" || len(f[0]) > MaxNameLen {
			panic("bad func name")
		}
		if !validClasses[f[1]] {
			panic("bad complexity class: " + f[1])
		}
		out = append(out, FuncBench{
			Name:         f[0],
			Class:        f[1],
			MaxN:         mustInt(f[2], 0, 1000000000, "maxN"),
			GasAtMaxN:    mustInt64(f[3], "gasAtMaxN"),
			GasPerItem:   mustInt64(f[4], "gasPerItem"),
			StorageBytes: mustInt64(f[5], "storageBytes"),
		})
	}
	return out
}

func parseFindings(s string) []Finding {
	if s == "" {
		return nil
	}
	entries := strings.Split(s, ";")
	if len(entries) > MaxFindings {
		panic("too many findings")
	}
	out := make([]Finding, 0, len(entries))
	for _, e := range entries {
		f := strings.Split(e, "|")
		if len(f) != 4 {
			panic("finding entry needs 4 fields: " + e)
		}
		if f[0] == "" || len(f[0]) > 16 {
			panic("bad rule id")
		}
		if !validSeverities[f[1]] {
			panic("bad severity: " + f[1])
		}
		if len(f[2]) > MaxFileLen {
			panic("file name too long")
		}
		out = append(out, Finding{
			Rule:     f[0],
			Severity: f[1],
			File:     f[2],
			Line:     mustInt(f[3], 0, 1000000, "line"),
		})
	}
	return out
}

func mustInt(s string, lo, hi int, what string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || n < lo || n > hi {
		panic("bad " + what + ": " + s)
	}
	return n
}

func mustInt64(s string, what string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		panic("bad " + what + ": " + s)
	}
	return n
}

func isHex(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// pad gives fixed-width keys so avl order matches numeric order.
func pad(n int) string {
	s := strconv.Itoa(n)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}
