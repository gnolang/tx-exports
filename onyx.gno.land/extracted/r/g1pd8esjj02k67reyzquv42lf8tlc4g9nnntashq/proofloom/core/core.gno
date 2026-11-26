// Package core provides shared validation helpers, deterministic identifier
// rules and status vocabulary for the PROOFLOOM protocol realms.
//
// core holds no mutable state: it is a pure library so it can be imported by
// every other PROOFLOOM realm and by external consumer realms without any
// interrealm authority concerns.
package core

import (
	"strings"
)

// Protocol version stamped on every record produced by these realms.
const ProtocolVersion = "1.0.0"

// Release lifecycle statuses. The authoritative state machine is enforced by
// the releases realm; these constants are shared so callers can reference
// states without magic strings.
const (
	ReleaseDraft          = "DRAFT"
	ReleaseEvidencePending = "EVIDENCE_PENDING"
	ReleaseValidating     = "VALIDATING"
	ReleaseReviewRequired = "REVIEW_REQUIRED"
	ReleaseApproved       = "APPROVED"
	ReleasePublished      = "PUBLISHED"
	ReleaseVerified       = "VERIFIED"
	ReleaseRejected       = "REJECTED"
	ReleaseRevoked        = "REVOKED"
	ReleaseSuperseded     = "SUPERSEDED"
	ReleaseDisputed       = "DISPUTED"
)

// Attestation statuses.
const (
	AttestationActive  = "ACTIVE"
	AttestationRevoked = "REVOKED"
	AttestationExpired = "EXPIRED"
)

// Agent statuses.
const (
	AgentActive    = "ACTIVE"
	AgentSuspended = "SUSPENDED"
	AgentRevoked   = "REVOKED"
)

// Agent permission scopes. Permissions are least-privilege and explicitly
// granted; there is no wildcard scope by design.
const (
	AgentScopeRead          = "READ"
	AgentScopeEvidence      = "EVIDENCE"
	AgentScopeVerifyRequest = "VERIFY_REQUEST"
	AgentScopeTaskUpdate    = "TASK_UPDATE"
	AgentScopeReviewPropose = "REVIEW_PROPOSE"
	AgentScopePublishReq    = "PUBLISH_REQUEST"
)

// Attestation subject types.
const (
	SubjectRelease  = "RELEASE"
	SubjectProject  = "PROJECT"
	SubjectComponent = "COMPONENT"
	SubjectTask     = "TASK"
	SubjectExecution = "AGENT_EXECUTION"
)

// Attestation categories supported by the protocol.
const (
	AttestBuild          = "BUILD_PROVENANCE"
	AttestSource         = "SOURCE_PROVENANCE"
	AttestTest           = "TEST_EXECUTION"
	AttestSecurity       = "SECURITY_ASSESSMENT"
	AttestCodeReview     = "CODE_REVIEW"
	AttestReleaseApprove = "RELEASE_APPROVAL"
	AttestAgentTask      = "AGENT_TASK_COMPLETION"
	AttestBenchmark      = "BENCHMARK_RESULT"
	AttestDependency     = "DEPENDENCY_VERIFICATION"
	AttestOwnership      = "OWNERSHIP_VERIFICATION"
	AttestDeployment     = "DEPLOYMENT_VERIFICATION"
	AttestCompliance     = "COMPLIANCE_EVIDENCE"
	AttestIncident       = "INCIDENT_REMEDIATION"
)

// IsValidAddress reports whether a looks like a Gno bech32 user or package
// address (g1-prefixed). It does not checksum-verify; the VM guarantees the
// addresses it hands out, and externally supplied strings must pass this gate
// before being stored.
func IsValidAddress(a string) bool {
	if len(a) != 40 && len(a) != 43 {
		// user addresses are g1 + 38 chars; package addresses vary slightly.
		if len(a) < 10 || len(a) > 64 {
			return false
		}
	}
	if !strings.HasPrefix(a, "g1") {
		return false
	}
	for i := 0; i < len(a); i++ {
		c := a[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}

// IsValidDigest reports whether d is a plausible sha256 hex digest
// (64 lowercase hex characters).
func IsValidDigest(d string) bool {
	if len(d) != 64 {
		return false
	}
	for i := 0; i < len(d); i++ {
		c := d[i]
		ok := (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}

// IsValidID reports whether id is a safe slug: lowercase letters, digits and
// dashes, 1..64 characters, no leading or trailing dash.
func IsValidID(id string) bool {
	if len(id) == 0 || len(id) > 64 {
		return false
	}
	if id[0] == '-' || id[len(id)-1] == '-' {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// IsValidSlugList validates a comma-free, whitespace-free list of IDs.
func IsValidSlugList(ids []string) bool {
	for _, id := range ids {
		if !IsValidID(id) {
			return false
		}
	}
	return true
}

// IsValidVersion checks a loose semver-ish version string: digits and dots
// with optional alphanum suffix, 1..32 chars.
func IsValidVersion(v string) bool {
	if len(v) == 0 || len(v) > 32 {
		return false
	}
	for i := 0; i < len(v); i++ {
		c := v[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+'
		if !ok {
			return false
		}
	}
	return true
}

// IsValidShortHash validates git commit-ish strings (7..64 hex chars).
func IsValidShortHash(h string) bool {
	if len(h) < 7 || len(h) > 64 {
		return false
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		ok := (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}

// BoundedText guards free-form metadata length on-chain to prevent state
// bloat. Nothing longer than maxLen may be persisted.
func BoundedText(s string, maxLen int) bool {
	return len(s) <= maxLen
}

// ComposeReleaseID derives a deterministic release identifier from the
// project ID and version. Release IDs must be reproducible off-chain so
// external consumers can address them without a lookup.
func ComposeReleaseID(projectID, version string) string {
	return projectID + "-" + strings.ToLower(version)
}

// ComposeAttestationID derives a deterministic attestation identifier from
// subject, category and issuer so duplicate attestations from the same issuer
// for the same subject/category are structurally impossible.
func ComposeAttestationID(subjectID, category, issuer string) string {
	return subjectID + "-" + strings.ToLower(category) + "-" + issuer
}

// MaxTextLen is the default cap for persisted free-form text fields.
const MaxTextLen = 512

// MaxListLen caps ID lists persisted on-chain (scopes, required types, ...).
const MaxListLen = 32
