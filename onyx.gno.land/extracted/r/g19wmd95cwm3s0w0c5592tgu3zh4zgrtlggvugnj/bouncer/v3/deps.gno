package bouncer

import "strings"

// Dependency trust (CLAUDE.md §4, §8). The attester sends the package's
// import tree as a list of paths, each marked direct or indirect; the
// realm never trusts a status from outside. Each dependency's status is
// read from this registry whenever the attestation is read, so a
// dependency attested later updates its importers' score, badge and
// Check() without a re-scan:
//
//   - verified: attested, and its latest verdict has no Critical or High issue
//   - at-risk: attested, and its latest verdict has a Critical or High issue
//   - unverified: not attested here yet (never shown as a vulnerability)

// Dependency statuses.
const (
	DepVerified   = "verified"
	DepAtRisk     = "at-risk"
	DepUnverified = "unverified"
)

const maxDeps = 200

// Dep is one dependency of an attested package. Status is filled in when
// the attestation is read.
type Dep struct {
	Path   string
	Direct bool
	Status string
}

// DepStatus returns the trust status of pkgpath as a dependency.
func DepStatus(pkgpath string) string {
	rec := getRecord(pkgpath)
	if rec == nil {
		return DepUnverified
	}
	if rec.history[len(rec.history)-1].Verdict == VerdictClear {
		return DepVerified
	}
	return DepAtRisk
}

// parseDeps decodes Attest's deps argument: ";"-separated "d,<pkgpath>"
// (direct) or "i,<pkgpath>" (indirect) entries, "" for none.
func parseDeps(pkgpath, s string) []Dep {
	out := []Dep{}
	if s == "" {
		return out
	}
	seen := map[string]bool{}
	for _, e := range strings.Split(s, ";") {
		kind, path, ok := strings.Cut(e, ",")
		if !ok || (kind != "d" && kind != "i") || !validPkgPath(path) {
			panic("invalid dependency entry")
		}
		if path == pkgpath || seen[path] {
			panic("duplicate or self dependency")
		}
		seen[path] = true
		out = append(out, Dep{Path: path, Direct: kind == "d"})
		if len(out) > maxDeps {
			panic("too many dependencies")
		}
	}
	return out
}

// live returns a copy of a with dependency statuses, counts, score and
// grade as they stand now. The verdict depends on the findings only.
func live(a Attestation) Attestation {
	a = copyAttestation(a)
	d := Deps{List: make([]Dep, len(a.Deps.List))}
	for i, dep := range a.Deps.List {
		dep.Status = DepStatus(dep.Path)
		d.List[i] = dep
		switch {
		case dep.Status == DepAtRisk && dep.Direct:
			d.DirectAtRisk++
		case dep.Status == DepAtRisk:
			d.IndirectAtRisk++
		case dep.Status == DepUnverified:
			d.Unverified++
		}
	}
	a.Deps = d
	a.Score, a.Grade, _ = ScoreFor(a.Findings, d)
	return a
}
