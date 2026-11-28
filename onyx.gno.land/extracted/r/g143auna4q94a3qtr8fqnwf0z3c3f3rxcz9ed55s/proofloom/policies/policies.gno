// Package policies stores versioned publication policies for projects.
// The policy engine's deterministic evaluation happens in the verify realm
// (and off-chain in the application); this realm is the authoritative
// versioned record of what each project requires.
//
// Policies answer the question: what must be true before a release of this
// project may be published?
package policies

import (
	"time"

	core "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/core"
	reg "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/registry"
)

// Policy is a versioned publication policy for a project.
type Policy struct {
	ProjectID             string
	Version               int
	RequireCategories     []string // attestation categories required for publication
	MinApprovals          int      // minimum RELEASE_APPROVAL attestations required
	AllowedIssuers        []string // empty means any issuer; non-empty is an allow-list
	RequireNoCritical     bool     // security assessment must be active and clean per off-chain scan
	RequireValidSBOM      bool     // a DEPENDENCY_VERIFICATION or BUILD attestation covering the SBOM must exist
	UpdatedAt             int64
	UpdatedBy             address
}

// policyHistory preserves every version for audit.
var (
	current  map[string]*Policy
	history  map[string][]*Policy
)

func ensure() {
	if current == nil {
		panic("policies: realm not initialized")
	}
}

// Init seeds realm state.
func Init(cur realm) {
	if current != nil {
		panic("policies: already initialized")
	}
	current = make(map[string]*Policy)
	history = make(map[string][]*Policy)
}

func validCategoryRef(cat string) bool {
	switch cat {
	case core.AttestBuild, core.AttestSource, core.AttestTest, core.AttestSecurity,
		core.AttestCodeReview, core.AttestReleaseApprove, core.AttestAgentTask,
		core.AttestBenchmark, core.AttestDependency, core.AttestOwnership,
		core.AttestDeployment, core.AttestCompliance, core.AttestIncident:
		return true
	}
	return false
}

// SetPolicy creates or updates the publication policy of a project. Only
// the project owner may set policy. Every update bumps the version and
// preserves the previous version in history.
func SetPolicy(cur realm, projectID string, requireCategories []string, minApprovals int, allowedIssuers []string, requireNoCritical, requireValidSBOM bool) int {
	ensure()
	if !reg.HasProject(projectID) {
		panic("policies: unknown project")
	}
	if !reg.IsProjectOwner(projectID, cur.Previous().Address()) {
		panic("policies: only the project owner may set policy")
	}
	if len(requireCategories) > core.MaxListLen || len(allowedIssuers) > core.MaxListLen {
		panic("policies: list too long")
	}
	cats := make([]string, 0, len(requireCategories))
	for _, c := range requireCategories {
		if !validCategoryRef(c) {
			panic("policies: invalid required category " + c)
		}
		cats = append(cats, c)
	}
	for _, i := range allowedIssuers {
		if !core.IsValidAddress(i) {
			panic("policies: invalid issuer address")
		}
	}
	if minApprovals < 0 || minApprovals > 16 {
		panic("policies: invalid approval threshold")
	}

	prev, exists := current[projectID]
	version := 1
	if exists {
		version = prev.Version + 1
		history[projectID] = append(history[projectID], prev)
	}
	p := &Policy{
		ProjectID:         projectID,
		Version:           version,
		RequireCategories: cats,
		MinApprovals:      minApprovals,
		AllowedIssuers:    allowedIssuers,
		RequireNoCritical: requireNoCritical,
		RequireValidSBOM:  requireValidSBOM,
		UpdatedAt:         time.Now().Unix(),
		UpdatedBy:         cur.Previous().Address(),
	}
	current[projectID] = p
	return version
}

// ClearPolicy removes the active policy (back to protocol defaults). Owner
// only. The previous policy is archived.
func ClearPolicy(cur realm, projectID string) {
	ensure()
	if !reg.HasProject(projectID) {
		panic("policies: unknown project")
	}
	if !reg.IsProjectOwner(projectID, cur.Previous().Address()) {
		panic("policies: only the project owner may clear policy")
	}
	if p, ok := current[projectID]; ok {
		history[projectID] = append(history[projectID], p)
		delete(current, projectID)
	}
}

// GetPolicy returns a copy of the active policy for a project, if set.
func GetPolicy(projectID string) (Policy, bool) {
	ensure()
	p, ok := current[projectID]
	if !ok {
		return Policy{}, false
	}
	return copyPolicy(*p), true
}

// GetPolicyVersion returns a specific archived version (1-based); version 0
// or a version beyond history yields the active policy when it matches.
func GetPolicyVersion(projectID string, version int) (Policy, bool) {
	ensure()
	for _, p := range history[projectID] {
		if p.Version == version {
			return copyPolicy(*p), true
		}
	}
	if p, ok := current[projectID]; ok && p.Version == version {
		return copyPolicy(*p), true
	}
	return Policy{}, false
}

// PolicyVersionCount returns how many versions exist for a project.
func PolicyVersionCount(projectID string) int {
	ensure()
	n := 0
	if _, ok := current[projectID]; ok {
		n++
	}
	n += len(history[projectID])
	return n
}

func copyPolicy(p Policy) Policy {
	cats := make([]string, len(p.RequireCategories))
	copy(cats, p.RequireCategories)
	iss := make([]string, len(p.AllowedIssuers))
	copy(iss, p.AllowedIssuers)
	p.RequireCategories = cats
	p.AllowedIssuers = iss
	return p
}

// Initialized reports whether the realm is initialized.
func Initialized() bool {
	return current != nil
}
