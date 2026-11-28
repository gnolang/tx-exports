// Package verify is the read-only public verification facade of the
// PROOFLOOM protocol. External consumers — other realms, dApps, indexers —
// import this realm to answer verification questions without holding any
// authority and without importing the write-side realms.
//
// Everything here is a pure query: no state is written, no authorization is
// granted. The verdicts combine release state, attestation status, and
// policy evaluation into a single explainable result.
//
// This realm is the protocol's composability contract: its function
// signatures are stable public API.
package verify

import (
	core "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/core"
	reg "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/registry"
	rel "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/releases"
	att "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/attestations"
	pol "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/policies"
)

// Verification verdict values.
const (
	VerdictVerified  = "VERIFIED"
	VerdictValid     = "VALID"
	VerdictPending   = "PENDING"
	VerdictFailed    = "FAILED"
	VerdictRevoked   = "REVOKED"
	VerdictExpired   = "EXPIRED"
	VerdictUnknown   = "UNKNOWN"
	VerdictDisputed  = "DISPUTED"
	VerdictSuperseded = "SUPERSEDED"
)

// AttestationSummary is a compact attestation view for consumers.
type AttestationSummary struct {
	ID       string
	Category string
	Issuer   string
	Digest   string
	Status   string
	IssuedAt int64
}

// PolicyCheck is one deterministic policy requirement and its outcome.
type PolicyCheck struct {
	Requirement string
	Passed      bool
	Detail      string
}

// ReleaseVerdict is the composite verification result for a release.
type ReleaseVerdict struct {
	ReleaseID      string
	ProjectID      string
	Version        string
	ArtifactDigest string
	ReleaseStatus  string
	Verdict        string
	Attestations   []AttestationSummary
	PolicyChecks   []PolicyCheck
	PolicyVersion  int
	Notes          string
}

// VerifyRelease answers: is this release's published commitment backed by
// the attestations its project's policy requires, and are those
// attestations still active?
//
// The verdict is explainable: every policy check records its outcome and a
// human-readable detail. A release is VERIFIED only when it is in a
// published-family state AND every configured policy check passed.
func VerifyRelease(releaseID string) ReleaseVerdict {
	v := ReleaseVerdict{ReleaseID: releaseID, Verdict: VerdictUnknown}

	r, ok := rel.GetPublishedRelease(releaseID)
	if !ok {
		// Distinguish unknown from non-public: status lookup is public.
		st := rel.ReleaseStatus(releaseID)
		if st == "" {
			v.Notes = "release does not exist"
			return v
		}
		if !rel.HasRelease(releaseID) {
			v.Notes = "release does not exist"
			return v
		}
		v.ReleaseStatus = st
		switch st {
		case core.ReleaseRevoked:
			v.Verdict = VerdictRevoked
			v.Notes = "release is revoked; the record remains publicly inspectable"
		case core.ReleaseSuperseded:
			v.Verdict = VerdictSuperseded
			v.Notes = "release was superseded by a newer release"
		case core.ReleaseDisputed:
			v.Verdict = VerdictDisputed
			v.Notes = "release is under dispute"
		default:
			v.Verdict = VerdictPending
			v.Notes = "release exists but is not published yet"
		}
		return v
	}

	v.ProjectID = r.ProjectID
	v.Version = r.Version
	v.ArtifactDigest = r.ArtifactDigest
	v.ReleaseStatus = r.Status

	// Gather attestations attached to the release.
	attIDs := att.ListBySubject(releaseID)
	for _, id := range attIDs {
		a, ok := att.GetAttestation(id)
		if !ok {
			continue
		}
		v.Attestations = append(v.Attestations, AttestationSummary{
			ID:       a.ID,
			Category: a.Category,
			Issuer:   string(a.Issuer),
			Digest:   a.Digest,
			Status:   att.EffectiveStatus(a.ID),
			IssuedAt: a.IssuedAt,
		})
	}
	sortAttestations(v.Attestations)

	// Deterministic policy evaluation.
	p, hasPolicy := pol.GetPolicy(r.ProjectID)
	if hasPolicy {
		v.PolicyVersion = p.Version
		evaluatePolicy(&v, p)
	} else {
		v.PolicyVersion = 0
		checkBaseline(&v)
	}

	v.Verdict = computeVerdict(v)
	return v
}

// evaluatePolicy runs the project's configured requirements. Deterministic:
// no heuristics, no judgment calls, same input always yields same output.
func evaluatePolicy(v *ReleaseVerdict, p pol.Policy) {
	for _, cat := range p.RequireCategories {
		active := att.ListActiveBySubjectAndCategory(v.ReleaseID, cat)
		check := PolicyCheck{
			Requirement: "ATTESTATION:" + cat,
			Passed:      len(active) > 0,
		}
		if len(active) > 0 {
			check.Detail = "active attestation present"
		} else {
			check.Detail = "no active attestation of this category"
		}
		v.PolicyChecks = append(v.PolicyChecks, check)
	}

	if p.MinApprovals > 0 {
		approvals := 0
		if len(p.AllowedIssuers) == 0 {
			approvals = len(att.ListActiveBySubjectAndCategory(v.ReleaseID, core.AttestReleaseApprove))
		} else {
			for _, issuer := range p.AllowedIssuers {
				if att.HasActiveAttestation(v.ReleaseID, core.AttestReleaseApprove, issuer) {
					approvals++
				}
			}
		}
		v.PolicyChecks = append(v.PolicyChecks, PolicyCheck{
			Requirement: "APPROVALS>=" + itoa(p.MinApprovals),
			Passed:      approvals >= p.MinApprovals,
			Detail:      itoa(approvals) + " active approval attestations",
		})
	}

	if p.RequireNoCritical {
		check := PolicyCheck{Requirement: "NO_CRITICAL_FINDINGS", Passed: true, Detail: "attestation-level signal only"}
		// A security assessment attestation existing and active satisfies the
		// on-chain check; scan content evaluation is off-chain.
		if len(att.ListActiveBySubjectAndCategory(v.ReleaseID, core.AttestSecurity)) == 0 {
			check.Passed = false
			check.Detail = "no active security assessment attestation"
		}
		v.PolicyChecks = append(v.PolicyChecks, check)
	}

	if p.RequireValidSBOM {
		hasSBOM := len(att.ListActiveBySubjectAndCategory(v.ReleaseID, core.AttestDependency)) > 0
		v.PolicyChecks = append(v.PolicyChecks, PolicyCheck{
			Requirement: "VALID_SBOM",
			Passed:      hasSBOM,
			Detail:      map[bool]string{true: "dependency verification attestation present", false: "missing dependency verification attestation"}[hasSBOM],
		})
	}
}

// checkBaseline applies the protocol baseline when no project policy is set:
// a published release must at least carry a build provenance attestation.
func checkBaseline(v *ReleaseVerdict) {
	active := att.ListActiveBySubjectAndCategory(v.ReleaseID, core.AttestBuild)
	v.PolicyChecks = append(v.PolicyChecks, PolicyCheck{
		Requirement: "BASELINE:BUILD_PROVENANCE",
		Passed:      len(active) > 0,
		Detail:      map[bool]string{true: "active build attestation present", false: "no active build provenance attestation"}[len(active) > 0],
	})
}

func computeVerdict(v ReleaseVerdict) string {
	switch v.ReleaseStatus {
	case core.ReleaseRevoked:
		return VerdictRevoked
	case core.ReleaseSuperseded:
		return VerdictSuperseded
	case core.ReleaseDisputed:
		return VerdictDisputed
	}
	if len(v.PolicyChecks) == 0 {
		return VerdictValid
	}
	for _, c := range v.PolicyChecks {
		if !c.Passed {
			return VerdictPending
		}
	}
	return VerdictVerified
}

// sortAttestations orders summaries by category then id (insertion sort:
// gno's sort package does not provide generics-based helpers).
func sortAttestations(s []AttestationSummary) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && attLess(s[j], s[j-1]); j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

func attLess(a, b AttestationSummary) bool {
	if a.Category != b.Category {
		return a.Category < b.Category
	}
	return a.ID < b.ID
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	if neg {
		return "-" + digits
	}
	return digits
}

// VerifyAttestation answers: does this attestation exist and is it active?
func VerifyAttestation(id string) (AttestationSummary, string) {
	a, ok := att.GetAttestation(id)
	if !ok {
		return AttestationSummary{}, ""
	}
	return AttestationSummary{
		ID:       a.ID,
		Category: a.Category,
		Issuer:   string(a.Issuer),
		Digest:   a.Digest,
		Status:   att.EffectiveStatus(id),
		IssuedAt: a.IssuedAt,
	}, att.EffectiveStatus(id)
}

// VerifyDigest finds published releases committed with a given artifact
// digest and returns their ids. Digests are the content-addressable handle
// for external verification.
func VerifyDigest(digest string) []string {
	return rel.FindByDigest(digest)
}

// GetProject returns the public project record for consumers.
func GetProject(id string) (reg.Project, bool) {
	return reg.GetPublicProject(id)
}

// ListPublicProjectIDs lists public project ids, sorted.
func ListPublicProjectIDs() []string {
	return reg.ListPublicProjectIDs()
}

// ListReleaseIDsByProject lists a project's release ids, newest first.
func ListReleaseIDsByProject(projectID string) []string {
	return rel.ListReleaseIDsByProject(projectID)
}

// ListAttestationsBySubject lists attestation ids for a subject.
func ListAttestationsBySubject(subjectID string) []string {
	return att.ListBySubject(subjectID)
}

// ProtocolVersion returns the protocol version string.
func ProtocolVersion() string {
	return core.ProtocolVersion
}

// RegistryStats returns simple public counts for dashboards.
func RegistryStats() (int, int, int, int) {
	return reg.ProjectCount(), reg.ComponentCount(), rel.ReleaseCount(), att.AttestationCount()
}

