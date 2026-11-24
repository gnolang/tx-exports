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
	return a
}

// Latest returns the newest attestation for pkgpath.
func Latest(pkgpath string) (Attestation, bool) {
	rec := getRecord(pkgpath)
	if rec == nil {
		return Attestation{}, false
	}
	return copyAttestation(rec.history[len(rec.history)-1]), true
}

// History returns every attestation for pkgpath, oldest first.
func History(pkgpath string) []Attestation {
	rec := getRecord(pkgpath)
	out := []Attestation{}
	if rec == nil {
		return out
	}
	for _, a := range rec.history {
		out = append(out, copyAttestation(a))
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

// Policy is an integration policy for Check. The zero value is the most
// conservative: no PROVEN findings, no open disputes, any score.
type Policy struct {
	MinScore int
	// AllowProvenCritical and AllowProvenOther permit PROVEN findings of
	// critical, or of high and medium, severity.
	AllowProvenCritical bool
	AllowProvenOther    bool
	// RequireVerifiedDeps forbids at-risk and unverified dependencies.
	RequireVerifiedDeps bool
	AllowOpenDisputes   bool
}

// Strict: score 90 or more, no PROVEN findings, every dependency verified,
// no open disputes.
func Strict() Policy {
	return Policy{MinScore: 90, RequireVerifiedDeps: true}
}

// Standard: score 75 or more and no PROVEN Critical.
func Standard() Policy {
	return Policy{MinScore: 75, AllowProvenOther: true, AllowOpenDisputes: true}
}

// Custom starts a policy at minScore that is otherwise as strict as the
// zero value; loosen it with the With methods:
//
//	bouncer.Custom(60).WithProvenOther().WithOpenDisputes()
//
// Other realms must build policies this way: the VM refuses to allocate a
// Bouncer type in a foreign realm, so a bouncer.Policy{...} literal written
// in another realm panics.
func Custom(minScore int) Policy { return Policy{MinScore: minScore} }

// WithProvenCritical allows PROVEN critical findings.
func (p Policy) WithProvenCritical() Policy { p.AllowProvenCritical = true; return p }

// WithProvenOther allows PROVEN high and medium findings.
func (p Policy) WithProvenOther() Policy { p.AllowProvenOther = true; return p }

// WithVerifiedDeps requires every dependency to be verified.
func (p Policy) WithVerifiedDeps() Policy { p.RequireVerifiedDeps = true; return p }

// WithOpenDisputes allows open disputes.
func (p Policy) WithOpenDisputes() Policy { p.AllowOpenDisputes = true; return p }

// Check reports whether the latest attestation of pkgpath satisfies p.
// An unattested package never passes.
func Check(pkgpath string, p Policy) bool {
	a, ok := Latest(pkgpath)
	if !ok || a.Score < p.MinScore {
		return false
	}
	for _, f := range a.Findings {
		if f.Label != LabelProven {
			continue
		}
		if f.Severity == SeverityCritical && !p.AllowProvenCritical {
			return false
		}
		if f.Severity != SeverityCritical && !p.AllowProvenOther {
			return false
		}
	}
	if p.RequireVerifiedDeps && (a.Deps.DirectAtRisk > 0 || a.Deps.IndirectAtRisk > 0 || a.Deps.Unverified > 0) {
		return false
	}
	if !p.AllowOpenDisputes && hasOpenDispute(pkgpath, "") {
		return false
	}
	return true
}
