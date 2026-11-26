// Package releases is the on-chain release provenance engine of the
// PROOFLOOM protocol. It records release commitments and enforces the
// authoritative release state machine:
//
//	DRAFT -> EVIDENCE_PENDING -> VALIDATING -> REVIEW_REQUIRED ->
//	APPROVED -> PUBLISHED -> VERIFIED
//
// with terminal states REJECTED, REVOKED, SUPERSEDED and DISPUTED.
//
// A PUBLISHED record can never silently change: corrections require an
// explicit supersede or revocation, both of which are auditable state
// transitions in their own right.
//
// Authorization: every state-changing call is attributed to
// cur.Previous().Address() and must be the project owner (per the registry
// realm), the release publisher, or the protocol admin.
package releases

import (
	"sort"
	"time"

	core "gno.land/r/g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq/proofloom/core"
	reg "gno.land/r/g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq/proofloom/registry"
)

// Release is the durable on-chain record of a software release commitment.
type Release struct {
	ID             string
	ProjectID      string
	ComponentID    string
	Version        string
	Commit         string
	Branch         string
	Repo           string
	ArtifactDigest string
	Status         string
	Publisher      address
	CreatedAt      int64
	PublishedAt    int64
	SupersededBy   string
}

var releases map[string]*Release

// releaseOrder preserves creation order for deterministic listing.
var releaseIDs []string

func initialized() bool {
	return releases != nil
}

func ensure() {
	if releases == nil {
		panic("releases: realm not initialized")
	}
}

// Init seeds realm state. The registry realm must already be deployed and
// initialized: this realm relies on registry.IsProtocolAdmin for its root of
// trust, so there is no separate admin to configure here.
func Init(cur realm) {
	if initialized() {
		panic("releases: already initialized")
	}
	releases = make(map[string]*Release)
}

func caller(cur realm) address {
	return cur.Previous().Address()
}

func requireCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("releases: call must run in current realm")
	}
}

// authorized returns true when addr may act on the given release: as the
// release publisher, the project owner, or the protocol admin.
func authorized(r *Release, addr address) bool {
	if r.Publisher == addr {
		return true
	}
	if reg.IsProjectOwner(r.ProjectID, addr) {
		return true
	}
	if reg.IsProtocolAdmin(addr) {
		return true
	}
	return false
}

func getRelease(id string) *Release {
	r, ok := releases[id]
	if !ok {
		panic("releases: unknown release " + id)
	}
	return r
}

// CreateRelease starts a new release in DRAFT state. Caller must be the
// project owner. The release id is derived deterministically from project
// and version.
func CreateRelease(cur realm, projectID, version, commit, branch, repo, componentID string) string {
	ensure()
	requireCurrent(cur)
	if !reg.HasProject(projectID) {
		panic("releases: unknown project")
	}
	if !core.IsValidVersion(version) {
		panic("releases: invalid version")
	}
	if commit != "" && !core.IsValidShortHash(commit) {
		panic("releases: invalid commit hash")
	}
	if !core.BoundedText(branch, 128) || !core.BoundedText(repo, 256) || !core.BoundedText(componentID, 64) {
		panic("releases: field exceeds size limits")
	}
	id := core.ComposeReleaseID(projectID, version)
	if _, exists := releases[id]; exists {
		panic("releases: release already exists " + id)
	}
	// Authorization: only the project owner may create releases.
	if !reg.IsProjectOwner(projectID, caller(cur)) {
		panic("releases: only the project owner may create releases")
	}
	releases[id] = &Release{
		ID:          id,
		ProjectID:   projectID,
		ComponentID: componentID,
		Version:     version,
		Commit:      commit,
		Branch:      branch,
		Repo:        repo,
		Status:      core.ReleaseDraft,
		Publisher:   caller(cur),
		CreatedAt:   time.Now().Unix(),
	}
	releaseIDs = append(releaseIDs, id)
	return id
}

// SetEvidence attaches the build artifact digest and moves the release from
// DRAFT to EVIDENCE_PENDING, or from EVIDENCE_PENDING to VALIDATING when the
// digest changes. Digest correctness against artifacts is verified off-chain
// by the evidence worker; the chain stores the commitment.
func SetEvidence(cur realm, id, artifactDigest string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized for release")
	}
	if !core.IsValidDigest(artifactDigest) {
		panic("releases: invalid artifact digest")
	}
	switch r.Status {
	case core.ReleaseDraft:
		r.Status = core.ReleaseEvidencePending
	case core.ReleaseEvidencePending:
		r.Status = core.ReleaseValidating
	default:
		panic("releases: cannot set evidence in state " + r.Status)
	}
	r.ArtifactDigest = artifactDigest
}

// MarkValidating records that automated validation started.
func MarkValidating(cur realm, id string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized for release")
	}
	if r.Status != core.ReleaseEvidencePending {
		panic("releases: expected EVIDENCE_PENDING, got " + r.Status)
	}
	r.Status = core.ReleaseValidating
}

// RequireReview moves a release into REVIEW_REQUIRED (policy or verifier
// decision).
func RequireReview(cur realm, id string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized for release")
	}
	if r.Status != core.ReleaseValidating {
		panic("releases: expected VALIDATING, got " + r.Status)
	}
	r.Status = core.ReleaseReviewRequired
}

// Approve authorizes the release for publication. Only REVIEW_REQUIRED and
// VALIDATING releases may be approved.
func Approve(cur realm, id string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized for release")
	}
	if r.Status != core.ReleaseReviewRequired && r.Status != core.ReleaseValidating {
		panic("releases: cannot approve from state " + r.Status)
	}
	r.Status = core.ReleaseApproved
}

// Reject terminates the release lifecycle. Terminal state.
func Reject(cur realm, id string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized for release")
	}
	if r.Status == core.ReleasePublished || r.Status == core.ReleaseVerified {
		panic("releases: published releases cannot be rejected; revoke instead")
	}
	r.Status = core.ReleaseRejected
}

// Publish commits the release on-chain. Requires APPROVED state and an
// attached artifact digest. Publish stamps the publication time and makes
// the record immutable except through Revoke/Supersede/Dispute.
func Publish(cur realm, id string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized for release")
	}
	if r.Status != core.ReleaseApproved {
		panic("releases: only APPROVED releases can be published")
	}
	if r.ArtifactDigest == "" {
		panic("releases: missing artifact digest")
	}
	r.Status = core.ReleasePublished
	r.PublishedAt = time.Now().Unix()
}

// MarkVerified records a successful verification pass over a published
// release. Only moves PUBLISHED -> VERIFIED.
func MarkVerified(cur realm, id string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized for release")
	}
	if r.Status != core.ReleasePublished {
		panic("releases: only PUBLISHED releases can be verified")
	}
	r.Status = core.ReleaseVerified
}

// Revoke withdraws a published release. Authorization: publisher, project
// owner, or protocol admin. Revoked releases remain publicly readable —
// revocation is a visible state, never a deletion.
func Revoke(cur realm, id string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized to revoke")
	}
	if r.Status != core.ReleasePublished && r.Status != core.ReleaseVerified {
		panic("releases: only published releases can be revoked")
	}
	r.Status = core.ReleaseRevoked
}

// Supersede marks a release replaced by a newer release of the same project.
// The superseding release must exist and be published.
func Supersede(cur realm, id, byID string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	nxt := getRelease(byID)
	if r.ProjectID != nxt.ProjectID {
		panic("releases: superseding release belongs to another project")
	}
	if nxt.Status != core.ReleasePublished && nxt.Status != core.ReleaseVerified {
		panic("releases: superseding release is not published")
	}
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized to supersede")
	}
	r.Status = core.ReleaseSuperseded
	r.SupersededBy = byID
}

// Dispute flags a release as disputed (compliance or legal hold). Admin or
// project owner.
func Dispute(cur realm, id string) {
	ensure()
	requireCurrent(cur)
	r := getRelease(id)
	if !authorized(r, caller(cur)) {
		panic("releases: caller not authorized to dispute")
	}
	if r.Status == core.ReleaseRevoked || r.Status == core.ReleaseSuperseded {
		panic("releases: terminal release cannot be disputed")
	}
	r.Status = core.ReleaseDisputed
}

// GetRelease returns a copy of a release if visible to the reader. Public
// visibility: any reader sees published/verified/revoked/superseded/disputed
// records; pre-publication states are visible to authorized parties only.
func GetRelease(id string, reader address) (Release, bool) {
	ensure()
	r, ok := releases[id]
	if !ok {
		return Release{}, false
	}
	if !isPublicState(r.Status) && !authorized(r, reader) {
		return Release{}, false
	}
	return *r, true
}

// HasRelease reports existence without visibility checks.
func HasRelease(id string) bool {
	ensure()
	_, ok := releases[id]
	return ok
}

func isPublicState(status string) bool {
	switch status {
	case core.ReleasePublished, core.ReleaseVerified, core.ReleaseRevoked,
		core.ReleaseSuperseded, core.ReleaseDisputed:
		return true
	}
	return false
}

// ReleaseStatus returns the current status of a release, or "" when unknown.
// Status is public metadata for every release (needed by external verifiers
// to check revocation without full record access).
func ReleaseStatus(id string) string {
	ensure()
	if r, ok := releases[id]; ok {
		return r.Status
	}
	return ""
}

// GetPublishedRelease returns the release only when in a published-family
// state, for external consumers.
func GetPublishedRelease(id string) (Release, bool) {
	ensure()
	r, ok := releases[id]
	if !ok || !isPublicState(r.Status) {
		return Release{}, false
	}
	return *r, true
}

// ListReleaseIDsByProject returns release ids of a project, newest first.
func ListReleaseIDsByProject(projectID string) []string {
	ensure()
	var out []string
	for _, id := range releaseIDs {
		if r := releases[id]; r != nil && r.ProjectID == projectID {
			out = append(out, id)
		}
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// FindByDigest returns published release ids whose artifact digest matches,
// sorted for deterministic output. This powers digest-based public
// verification.
func FindByDigest(digest string) []string {
	ensure()
	if !core.IsValidDigest(digest) {
		return nil
	}
	var out []string
	for _, id := range releaseIDs {
		if r := releases[id]; r != nil && r.ArtifactDigest == digest && isPublicState(r.Status) {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out
}

// ReleaseCount returns the total number of releases.
func ReleaseCount() int {
	ensure()
	return len(releaseIDs)
}

// Initialized reports whether the releases realm has been initialized.
func Initialized() bool {
	return releases != nil
}
