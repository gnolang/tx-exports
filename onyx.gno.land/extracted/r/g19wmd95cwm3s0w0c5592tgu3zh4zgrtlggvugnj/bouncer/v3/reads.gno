package bouncer

import "gno.land/p/nt/avl/v0"

// Reads for other realms and for clients. All are plain (non-crossing)
// functions that return values or fresh copies: no pointer into state ever
// leaves this realm, and no caller-supplied function is ever invoked.

// copyAttestation returns a deep copy (the Findings slice is copied too).
func copyAttestation(a Attestation) Attestation {
	fs := make([]Finding, len(a.Findings))
	copy(fs, a.Findings)
	a.Findings = fs
	ds := make([]Dep, len(a.Deps.List))
	copy(ds, a.Deps.List)
	a.Deps.List = ds
	return a
}

// Latest returns the newest attestation for pkgpath.
func Latest(pkgpath string) (Attestation, bool) {
	rec := getRecord(pkgpath)
	if rec == nil {
		return Attestation{}, false
	}
	return live(rec.history[len(rec.history)-1]), true
}

// History returns every attestation for pkgpath, oldest first, with scores
// that use the current dependency statuses (like Latest).
func History(pkgpath string) []Attestation {
	rec := getRecord(pkgpath)
	out := []Attestation{}
	if rec == nil {
		return out
	}
	for _, a := range rec.history {
		out = append(out, live(a))
	}
	return out
}

// Replies returns the author's replies on pkgpath, oldest first.
func Replies(pkgpath string) []AuthorReply {
	rec := getRecord(pkgpath)
	out := []AuthorReply{}
	if rec != nil {
		out = append(out, rec.replies...)
	}
	return out
}

// Score returns the latest score for pkgpath.
func Score(pkgpath string) (int, bool) {
	a, ok := Latest(pkgpath)
	return a.Score, ok
}

// ByAuthor returns the attested packages in addr's namespace, sorted.
func ByAuthor(addr address) []string {
	out := []string{}
	v := byAuthor.Get(string(addr))
	if v == nil {
		return out
	}
	v.(*avl.Tree).Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

// Policy is an integration policy for Check. No policy accepts a red
// verdict: a PROVEN Critical or High finding fails every policy, and there
// is no option to allow it. The zero value is the most conservative: no
// PROVEN findings at all, not disputed, any score.
type Policy struct {
	MinScore int
	// AllowProvenMedium permits PROVEN medium findings (which do not make
	// the verdict red).
	AllowProvenMedium bool
	// RequireVerifiedDeps forbids at-risk and unverified dependencies.
	RequireVerifiedDeps bool
	// AllowDisputed accepts a latest attestation that a re-scan disputed
	// (an upheld dispute). An open dispute alone never fails a policy.
	AllowDisputed bool
}

// Strict: score 90 or more, no PROVEN findings, every dependency verified,
// latest attestation not disputed.
func Strict() Policy {
	return Policy{MinScore: 90, RequireVerifiedDeps: true}
}

// Standard: score 75 or more and no PROVEN Critical or High finding.
// A disputed attestation is tolerated.
func Standard() Policy {
	return Policy{MinScore: 75, AllowProvenMedium: true, AllowDisputed: true}
}

// Custom starts a policy at minScore that is otherwise as strict as the
// zero value; loosen it with the With methods:
//
//	bouncer.Custom(60).WithProvenMedium().WithDisputed()
//
// Other realms must build policies this way: the VM refuses to allocate a
// Bouncer type in a foreign realm, so a bouncer.Policy{...} literal written
// in another realm panics.
func Custom(minScore int) Policy { return Policy{MinScore: minScore} }

// WithProvenMedium allows PROVEN medium findings.
func (p Policy) WithProvenMedium() Policy { p.AllowProvenMedium = true; return p }

// WithVerifiedDeps requires every dependency to be verified.
func (p Policy) WithVerifiedDeps() Policy { p.RequireVerifiedDeps = true; return p }

// WithDisputed allows an attestation whose dispute was upheld.
func (p Policy) WithDisputed() Policy { p.AllowDisputed = true; return p }

// Check reports whether the latest attestation of pkgpath satisfies p.
// An unattested package never passes.
func Check(pkgpath string, p Policy) bool {
	a, ok := Latest(pkgpath)
	if !ok || !allows(p, a.Score, a.Findings, a.Deps) {
		return false
	}
	if !p.AllowDisputed && a.Disputed {
		return false
	}
	return true
}

// allows is the policy decision on a score, findings and dependency counts
// (disputes aside). bouncer gate's Go copy (internal/score) must decide the
// same; TestMatchesRealm checks it.
func allows(p Policy, score int, fs []Finding, d Deps) bool {
	if verdictOf(fs) == VerdictNotRecommended {
		return false // a red verdict never passes
	}
	if score < p.MinScore {
		return false
	}
	for _, f := range fs {
		if f.Label == LabelProven && !p.AllowProvenMedium {
			return false // only medium can be PROVEN here
		}
	}
	if p.RequireVerifiedDeps && (d.DirectAtRisk > 0 || d.IndirectAtRisk > 0 || d.Unverified > 0) {
		return false
	}
	return true
}
