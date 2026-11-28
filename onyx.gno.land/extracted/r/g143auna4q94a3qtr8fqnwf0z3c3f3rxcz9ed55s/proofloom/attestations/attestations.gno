// Package attestations is the on-chain evidence commitment registry of the
// PROOFLOOM protocol. Attestations bind a claim category to a subject and a
// content digest, recorded by an identifiable issuer.
//
// An attestation is a signed-off-chain claim's public commitment: the
// evidence bytes themselves live off-chain; the chain stores who claimed
// what about which subject, when, and whether it still stands.
//
// Rules enforced here:
//   - Deterministic attestation ids (subject+category+issuer) structurally
//     prevent duplicate active attestations from one issuer for one subject
//     and category.
//   - Revocation is issuer-only (or protocol admin) and is permanent and
//     publicly visible.
//   - Expiry is recorded as data; status computation treats expired
//     attestations as EXPIRED.
package attestations

import (
	"sort"
	"time"

	core "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/core"
	reg "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/registry"
	rel "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/releases"
)

// Attestation is the durable public commitment record.
type Attestation struct {
	ID               string
	SubjectType      string
	SubjectID        string
	Category         string
	Issuer           address
	Digest           string
	Status           string
	IssuedAt         int64
	ExpiresAt        int64 // 0 means no expiry
	RevokedAt        int64
	RevocationReason string
}

var attestations map[string]*Attestation
var attestationIDs []string

// attestationHistory archives prior attestations when a revoked or expired
// record is re-issued under the same deterministic id, so revocation
// reasons and expiry history are never destroyed by an overwrite.
var attestationHistory map[string][]*Attestation

func ensure() {
	if attestations == nil {
		panic("attestations: realm not initialized")
	}
}

// Init seeds realm state. Root of trust is the registry realm's protocol
// admin; no separate admin exists here.
func Init(cur realm) {
	if attestations != nil {
		panic("attestations: already initialized")
	}
	attestations = make(map[string]*Attestation)
	attestationHistory = make(map[string][]*Attestation)
}

func validCategory(cat string) bool {
	switch cat {
	case core.AttestBuild, core.AttestSource, core.AttestTest, core.AttestSecurity,
		core.AttestCodeReview, core.AttestReleaseApprove, core.AttestAgentTask,
		core.AttestBenchmark, core.AttestDependency, core.AttestOwnership,
		core.AttestDeployment, core.AttestCompliance, core.AttestIncident:
		return true
	}
	return false
}

func validSubjectType(st string) bool {
	switch st {
	case core.SubjectRelease, core.SubjectProject, core.SubjectComponent,
		core.SubjectTask, core.SubjectExecution:
		return true
	}
	return false
}

// subjectExists verifies the subject reference resolves in the appropriate
// realm, preventing attestations against phantom subjects.
func subjectExists(subjectType, subjectID string) bool {
	switch subjectType {
	case core.SubjectRelease:
		return rel.HasRelease(subjectID)
	case core.SubjectProject:
		return reg.HasProject(subjectID)
	}
	// component/task/execution subjects are registered off-chain first;
	// on-chain existence is checked for the types the chain knows.
	return subjectType == core.SubjectComponent || subjectType == core.SubjectTask || subjectType == core.SubjectExecution
}

// Issue records a new attestation commitment. The caller is the issuer.
// expiresAt is an absolute unix timestamp; 0 means never expires.
func Issue(cur realm, subjectType, subjectID, category, digest string, expiresAt int64) string {
	ensure()
	if !cur.IsCurrent() {
		panic("attestations: issue must run in current realm")
	}
	if !validSubjectType(subjectType) {
		panic("attestations: invalid subject type")
	}
	if !validCategory(category) {
		panic("attestations: invalid category")
	}
	if !core.IsValidDigest(digest) {
		panic("attestations: invalid evidence digest")
	}
	if !subjectExists(subjectType, subjectID) {
		panic("attestations: subject does not exist")
	}
	if expiresAt != 0 && expiresAt <= time.Now().Unix() {
		panic("attestations: expiry must be in the future")
	}
	issuer := cur.Previous().Address()
	id := core.ComposeAttestationID(subjectID, category, string(issuer))
	if existing, ok := attestations[id]; ok && existing.Status == core.AttestationActive {
		panic("attestations: active attestation already exists for this subject, category and issuer")
	}
	if existing, ok := attestations[id]; ok {
		// Archive the replaced record; history stays publicly inspectable.
		attestationHistory[id] = append(attestationHistory[id], existing)
	}
	attestations[id] = &Attestation{
		ID:          id,
		SubjectType: subjectType,
		SubjectID:   subjectID,
		Category:    category,
		Issuer:      issuer,
		Digest:      digest,
		Status:      core.AttestationActive,
		IssuedAt:    time.Now().Unix(),
		ExpiresAt:   expiresAt,
	}
	attestationIDs = append(attestationIDs, id)
	return id
}

// Revoke permanently revokes an attestation. Only the original issuer or
// the protocol admin may revoke. Revocation is visible forever.
func Revoke(cur realm, id, reason string) {
	ensure()
	a, ok := attestations[id]
	if !ok {
		panic("attestations: unknown attestation")
	}
	caller := cur.Previous().Address()
	if a.Issuer != caller && !reg.IsProtocolAdmin(caller) {
		panic("attestations: only the issuer or protocol admin may revoke")
	}
	if a.Status == core.AttestationRevoked {
		panic("attestations: already revoked")
	}
	if !core.BoundedText(reason, core.MaxTextLen) {
		panic("attestations: revocation reason too long")
	}
	a.Status = core.AttestationRevoked
	a.RevokedAt = time.Now().Unix()
	a.RevocationReason = reason
}

// GetAttestation returns a copy of the attestation record.
func GetAttestation(id string) (Attestation, bool) {
	ensure()
	a, ok := attestations[id]
	if !ok {
		return Attestation{}, false
	}
	return *a, true
}

// GetAttestationHistory returns archived (replaced) attestation records for
// a deterministic attestation id, oldest first. Copies only: internal
// pointers are never exposed.
func GetAttestationHistory(id string) []Attestation {
	ensure()
	hist := attestationHistory[id]
	out := make([]Attestation, 0, len(hist))
	for _, a := range hist {
		out = append(out, *a)
	}
	return out
}

// EffectiveStatus returns ACTIVE, REVOKED or EXPIRED for an attestation id,
// "" when unknown. Expired status is derived from recorded expiry time so
// verifiers get truthful answers without re-computing.
func EffectiveStatus(id string) string {
	ensure()
	a, ok := attestations[id]
	if !ok {
		return ""
	}
	if a.Status == core.AttestationRevoked {
		return core.AttestationRevoked
	}
	if a.ExpiresAt != 0 && a.ExpiresAt <= time.Now().Unix() {
		return core.AttestationExpired
	}
	return core.AttestationActive
}

// ListBySubject returns attestation ids attached to a subject, newest first.
func ListBySubject(subjectID string) []string {
	ensure()
	var out []string
	for _, id := range attestationIDs {
		if a := attestations[id]; a != nil && a.SubjectID == subjectID {
			out = append(out, id)
		}
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// ListActiveBySubjectAndCategory returns active attestation ids for a
// subject/category pair, sorted deterministically.
func ListActiveBySubjectAndCategory(subjectID, category string) []string {
	ensure()
	var out []string
	for _, id := range attestationIDs {
		a := attestations[id]
		if a == nil || a.SubjectID != subjectID || a.Category != category {
			continue
		}
		if EffectiveStatus(id) != core.AttestationActive {
			continue
		}
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// HasActiveAttestation reports whether any active attestation of the given
// category exists for the subject from the given issuer (empty issuer = any).
func HasActiveAttestation(subjectID, category, issuer string) bool {
	ensure()
	for _, id := range ListActiveBySubjectAndCategory(subjectID, category) {
		if issuer == "" || string(attestations[id].Issuer) == issuer {
			return true
		}
	}
	return false
}

// AttestationCount returns the number of attestations recorded.
func AttestationCount() int {
	ensure()
	return len(attestationIDs)
}

// Initialized reports whether the realm is initialized.
func Initialized() bool {
	return attestations != nil
}
