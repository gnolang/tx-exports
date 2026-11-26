// Package ironclad implements an immutable, multi-auditor, content-addressed
// audit attestation, challenge-resolution, and security badge registry for
// Gno.land packages and realms.
//
// Security model: attestations are cryptographically bound to the publishing
// auditor's address (self-reported / auditor-signed claims). No caller can
// overwrite another auditor's certificate or squat another auditor's digest.
package ironclad

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	pironclad "gno.land/p/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	StatusValid   = "valid"
	StatusRevoked = "revoked"

	ChallengeOpen     = "open"
	ChallengeAccepted = "accepted"
	ChallengeRebutted = "rebutted"

	maxRenderRows  = 25
	maxPage        = 10000  // prevents (page-1)*maxRenderRows overflow
	maxFindingCnt  = 100000 // prevents int64 score-penalty wraparound (R5)
	maxHandleLen   = 40
	maxBioLen      = 240
	maxSummaryLen  = 400
	maxRulesLen    = 240
	maxURLLen      = 200
)

type auditorRecord struct {
	addr              address
	handle            string
	bio               string
	websiteURL        string
	registeredHeight  int64
	attestationsCount int64
	revocationsCount  int64
}

type attestationRecord struct {
	id              uint64
	auditor         address
	targetPkgPath   string
	sourceHash      string
	reportDigest    string
	digest          string
	analyzerVersion string
	critical        int
	high            int
	medium          int
	low             int
	info            int
	score           int
	grade           string
	rulesTriggered  string
	summary         string
	reportURL       string
	height          int64
	status          string
	revokeReason    string
	challengeCount  int
	openChallenges  int
}

type challengeRecord struct {
	id              uint64
	attestationID   uint64
	challenger      address
	missedRuleID    string
	evidenceDigest  string
	reason          string
	height          int64
	status          string
	auditorResponse string
	resolvedHeight  int64
}

// Public read-only value views (zero mutable pointers ever exposed).

type AuditorView struct {
	Addr              address
	Handle            string
	Bio               string
	WebsiteURL        string
	RegisteredHeight  int64
	AttestationsCount int64
	RevocationsCount  int64
}

type AttestationView struct {
	ID              uint64
	Auditor         address
	TargetPkgPath   string
	SourceHash      string
	ReportDigest    string
	Digest          string
	AnalyzerVersion string
	Critical        int
	High            int
	Medium          int
	Low             int
	Info            int
	Score           int
	Grade           string
	RulesTriggered  string
	Summary         string
	ReportURL       string
	Height          int64
	Status          string
	RevokeReason    string
	ChallengeCount  int
	OpenChallenges  int
}

type ChallengeView struct {
	ID              uint64
	AttestationID   uint64
	Challenger      address
	MissedRuleID    string
	EvidenceDigest  string
	Reason          string
	Height          int64
	Status          string
	AuditorResponse string
	ResolvedHeight  int64
}

// Strictly unexported realm state (zero GLOBAL001 violations).
var (
	auditors            = avl.NewTree() // addr -> *auditorRecord
	handleIndex         = avl.NewTree() // lower(handle) -> address (uniqueness)
	attestations        = avl.NewTree() // seqid.Binary() -> *attestationRecord
	pkgIndex            = avl.NewTree() // pkgPath -> bool (distinct package count)
	latestByPkgAuditor  = avl.NewTree() // pkgPath+"|"+auditor -> uint64 (R2: no hijack)
	pkgAttestations     = avl.NewTree() // pkgPath+"|"+seqid.Binary() -> uint64 (history)
	auditorDigestIndex  = avl.NewTree() // digest+"|"+auditor -> uint64 (R3: no squatting)
	digestFirstIndex    = avl.NewTree() // digest -> uint64 (lookup helper, non-blocking)
	challenges          = avl.NewTree() // seqid.Binary() -> *challengeRecord
	attChallenges       = avl.NewTree() // seqid(attID).Binary()+"|"+seqid(chID).Binary() -> uint64
	challengeDedup      = avl.NewTree() // attID|rule|evidence|challenger -> challengeID
	nextAttestID        seqid.ID
	nextChallengeID     seqid.ID
)

func mustCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("ironclad: spoofed realm capability")
	}
}

func getAttestationRecord(id uint64) *attestationRecord {
	if id == 0 {
		return nil
	}
	v := attestations.Get(seqid.ID(id).Binary())
	if v == nil {
		return nil
	}
	return v.(*attestationRecord)
}

func getChallengeRecord(id uint64) *challengeRecord {
	if id == 0 {
		return nil
	}
	v := challenges.Get(seqid.ID(id).Binary())
	if v == nil {
		return nil
	}
	return v.(*challengeRecord)
}

func getAuditorRecord(addr address) *auditorRecord {
	v := auditors.Get(addr.String())
	if v == nil {
		return nil
	}
	return v.(*auditorRecord)
}

func isValidRuleToken(s string) bool {
	switch s {
	case "GNO-TC1A", "GNO-TC1B", "GNO-TC2", "GNO-TC3", "GNO-TC4",
		"GNO-SEC01", "GNO-SEC02", "GNO-SEC03", "GNO-SEC04", "GNO-SEC05", "GNO-SEC06", "GNO-SEC07",
		"AVL001", "GLOBAL001", "RENDER001", "PARSE-ERR":
		return true
	default:
		return false
	}
}

// isValidRulesList validates comma-separated rule IDs using strict [A-Z0-9,-] (R8).
func isValidRulesList(s string) bool {
	if s == "" {
		return true
	}
	if len(s) > maxRulesLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == ','
		if !ok {
			return false
		}
	}
	parts := strings.Split(s, ",")
	for _, p := range parts {
		if !isValidRuleToken(p) {
			return false
		}
	}
	return true
}

func isValidVersionToken(s string) bool {
	if len(s) == 0 || len(s) > 48 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '-' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

// RegisterAuditor creates or updates the caller's unique on-chain auditor profile.
func RegisterAuditor(cur realm, handle, bio, websiteURL string) {
	mustCurrent(cur)
	caller := cur.Previous().Address()

	handle = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(handle))
	if handle == "" || len(handle) > maxHandleLen {
		panic("ironclad: invalid handle")
	}
	lowerHandle := strings.ToLower(handle)
	if owner := handleIndex.Get(lowerHandle); owner != nil && owner.(address) != caller {
		panic("ironclad: auditor handle already taken")
	}

	bio = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(bio))
	if len(bio) > maxBioLen {
		panic("ironclad: bio exceeds max length")
	}
	cleanURL := ""
	if strings.TrimSpace(websiteURL) != "" {
		cleanURL = sanitize.URL(strings.TrimSpace(websiteURL))
		if cleanURL == "" || len(cleanURL) > maxURLLen {
			panic("ironclad: invalid website URL")
		}
	}

	existing := getAuditorRecord(caller)
	if existing == nil {
		auditors.Set(caller.String(), &auditorRecord{
			addr:             caller,
			handle:           handle,
			bio:              bio,
			websiteURL:       cleanURL,
			registeredHeight: runtime.ChainHeight(),
		})
	} else {
		oldLower := strings.ToLower(existing.handle)
		if oldLower != lowerHandle {
			handleIndex.Remove(oldLower)
		}
		existing.handle = handle
		existing.bio = bio
		existing.websiteURL = cleanURL
	}
	handleIndex.Set(lowerHandle, caller)
	chain.Emit("AuditorRegistered", "auditor", caller.String(), "handle", handle)
}

// PublishAttestation anchors an immutable, auditor-scoped content-addressed
// static security analysis verdict for a Gno package/realm snapshot on chain.
func PublishAttestation(
	cur realm,
	targetPkgPath string,
	sourceHash string,
	reportDigest string,
	analyzerVersion string,
	critical int,
	high int,
	medium int,
	low int,
	info int,
	rulesTriggered string,
	summary string,
	reportURL string,
) uint64 {
	mustCurrent(cur)
	caller := cur.Previous().Address()

	targetPkgPath = strings.TrimSpace(targetPkgPath)
	if !pironclad.ValidatePkgPath(targetPkgPath) {
		panic("ironclad: invalid targetPkgPath (must start with gno.land/r/ or gno.land/p/)")
	}
	if !pironclad.IsValidHexDigest(sourceHash) {
		panic("ironclad: invalid sourceHash (expect 64-char lowercase sha256 hex)")
	}
	if !pironclad.IsValidHexDigest(reportDigest) {
		panic("ironclad: invalid reportDigest (expect 64-char lowercase sha256 hex)")
	}
	analyzerVersion = strings.TrimSpace(analyzerVersion)
	if !isValidVersionToken(analyzerVersion) {
		panic("ironclad: invalid analyzerVersion (use [a-zA-Z0-9._-], 1..48 chars)")
	}
	if critical < 0 || high < 0 || medium < 0 || low < 0 || info < 0 ||
		critical > maxFindingCnt || high > maxFindingCnt || medium > maxFindingCnt || low > maxFindingCnt || info > maxFindingCnt {
		panic("ironclad: finding counts out of bounds (0..100000)")
	}
	rulesTriggered = strings.TrimSpace(rulesTriggered)
	if !isValidRulesList(rulesTriggered) {
		panic("ironclad: invalid rulesTriggered (must be comma-separated known rule IDs)")
	}
	summary = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(summary))
	if len(summary) > maxSummaryLen {
		panic("ironclad: summary exceeds max length")
	}
	cleanURL := ""
	if strings.TrimSpace(reportURL) != "" {
		cleanURL = sanitize.URL(strings.TrimSpace(reportURL))
		if cleanURL == "" || len(cleanURL) > maxURLLen {
			panic("ironclad: invalid reportURL")
		}
	}

	score := pironclad.ComputeScore(critical, high, medium, low)
	grade := pironclad.ComputeGrade(score, critical, high)
	digest := pironclad.AttestationDigest(
		runtime.ChainID(),
		targetPkgPath,
		sourceHash,
		reportDigest,
		analyzerVersion,
		critical, high, medium, low, info,
	)

	// R3: Dedup strictly per (digest, auditor) so no one can squat another auditor's digest.
	dedupKey := digest + "|" + caller.String()
	if prev := auditorDigestIndex.Get(dedupKey); prev != nil {
		if prevRec := getAttestationRecord(prev.(uint64)); prevRec != nil && prevRec.status != StatusRevoked {
			panic("ironclad: you already published an active identical attestation")
		}
	}

	aid := nextAttestID.Next()
	rec := &attestationRecord{
		id:              uint64(aid),
		auditor:         caller,
		targetPkgPath:   targetPkgPath,
		sourceHash:      sourceHash,
		reportDigest:    reportDigest,
		digest:          digest,
		analyzerVersion: analyzerVersion,
		critical:        critical,
		high:            high,
		medium:          medium,
		low:             low,
		info:            info,
		score:           score,
		grade:           grade,
		rulesTriggered:  rulesTriggered,
		summary:         summary,
		reportURL:       cleanURL,
		height:          runtime.ChainHeight(),
		status:          StatusValid,
	}
	attestations.Set(aid.Binary(), rec)
	pkgIndex.Set(targetPkgPath, true)
	// R2: Scoped per (pkgPath, auditor) + full chronological history; no last-writer-wins hijack.
	latestByPkgAuditor.Set(targetPkgPath+"|"+caller.String(), rec.id)
	pkgAttestations.Set(targetPkgPath+"|"+aid.Binary(), rec.id)
	auditorDigestIndex.Set(dedupKey, rec.id)
	if prevFirst := digestFirstIndex.Get(digest); prevFirst == nil {
		digestFirstIndex.Set(digest, rec.id)
	} else if prevRec := getAttestationRecord(prevFirst.(uint64)); prevRec == nil || prevRec.status == StatusRevoked {
		digestFirstIndex.Set(digest, rec.id)
	}

	if aud := getAuditorRecord(caller); aud != nil {
		aud.attestationsCount++
	} else {
		autoHandle := "auditor-" + caller.String()[:10]
		lowerAuto := strings.ToLower(autoHandle)
		if existingOwner := handleIndex.Get(lowerAuto); existingOwner != nil && existingOwner.(address) != caller {
			autoHandle = "aud-" + caller.String()
			lowerAuto = strings.ToLower(autoHandle)
		}
		auditors.Set(caller.String(), &auditorRecord{
			addr:              caller,
			handle:            autoHandle,
			registeredHeight:  runtime.ChainHeight(),
			attestationsCount: 1,
		})
		if !handleIndex.Has(lowerAuto) {
			handleIndex.Set(lowerAuto, caller)
		}
	}

	chain.Emit(
		"AttestationPublished",
		"attestation_id", strconv.FormatUint(rec.id, 10),
		"target_pkg", targetPkgPath,
		"auditor", caller.String(),
		"score", strconv.Itoa(score),
		"grade", grade,
		"digest", digest,
	)
	return rec.id
}

// ChallengeAttestation records an on-chain counter-finding against an attestation.
// R4: Does NOT unilaterally flip the attestation status (prevents anonymous griefing);
// instead records a structured open challenge that the auditor can accept or rebut.
func ChallengeAttestation(
	cur realm,
	attestationID uint64,
	missedRuleID string,
	evidenceDigest string,
	reason string,
) uint64 {
	mustCurrent(cur)
	rec := getAttestationRecord(attestationID)
	if rec == nil {
		panic("ironclad: attestation not found")
	}
	if rec.status == StatusRevoked {
		panic("ironclad: attestation already revoked")
	}
	missedRuleID = strings.TrimSpace(missedRuleID)
	if !isValidRuleToken(missedRuleID) {
		panic("ironclad: unknown missedRuleID (must match official Ironclad taxonomy rule)")
	}
	if !pironclad.IsValidHexDigest(evidenceDigest) {
		panic("ironclad: invalid evidenceDigest")
	}
	reason = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(reason))
	if reason == "" || len(reason) > maxSummaryLen {
		panic("ironclad: valid challenge reason required")
	}

	challenger := cur.Previous().Address()
	chDedupKey := strconv.FormatUint(attestationID, 10) + "|" + missedRuleID + "|" + challenger.String()
	if challengeDedup.Has(chDedupKey) {
		panic("ironclad: duplicate challenge for same attestation, rule, and challenger")
	}

	cid := nextChallengeID.Next()
	ch := &challengeRecord{
		id:             uint64(cid),
		attestationID:  attestationID,
		challenger:     challenger,
		missedRuleID:   missedRuleID,
		evidenceDigest: evidenceDigest,
		reason:         reason,
		height:         runtime.ChainHeight(),
		status:         ChallengeOpen,
	}
	challenges.Set(cid.Binary(), ch)
	attChallenges.Set(seqid.ID(attestationID).Binary()+"|"+cid.Binary(), ch.id)
	challengeDedup.Set(chDedupKey, ch.id)
	rec.challengeCount++
	rec.openChallenges++

	chain.Emit(
		"AttestationChallenged",
		"challenge_id", strconv.FormatUint(ch.id, 10),
		"attestation_id", strconv.FormatUint(attestationID, 10),
		"rule_id", missedRuleID,
		"challenger", ch.challenger.String(),
	)
	return ch.id
}

// RespondToChallenge lets the original auditor resolve an open challenge by
// either accepting the finding (auto-revoking the attestation) or rebutting it
// with a public technical rationale.
func RespondToChallenge(cur realm, challengeID uint64, accept bool, response string) {
	mustCurrent(cur)
	ch := getChallengeRecord(challengeID)
	if ch == nil {
		panic("ironclad: challenge not found")
	}
	if ch.status != ChallengeOpen {
		panic("ironclad: challenge already resolved")
	}
	rec := getAttestationRecord(ch.attestationID)
	caller := cur.Previous().Address()
	if caller != rec.auditor {
		panic("ironclad: only original auditor may respond to challenge")
	}
	response = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(response))
	if response == "" || len(response) > maxSummaryLen {
		panic("ironclad: response rationale required")
	}

	ch.auditorResponse = response
	ch.resolvedHeight = runtime.ChainHeight()
	if rec.openChallenges > 0 {
		rec.openChallenges--
	}

	if accept {
		ch.status = ChallengeAccepted
		if rec.status != StatusRevoked {
			rec.status = StatusRevoked
			rec.revokeReason = "Accepted challenge #" + strconv.FormatUint(challengeID, 10) + " (" + ch.missedRuleID + "): " + response
			if aud := getAuditorRecord(caller); aud != nil {
				aud.revocationsCount++
			}
		}
	} else {
		ch.status = ChallengeRebutted
	}

	chain.Emit(
		"ChallengeResolved",
		"challenge_id", strconv.FormatUint(challengeID, 10),
		"attestation_id", strconv.FormatUint(ch.attestationID, 10),
		"outcome", ch.status,
	)
}

// RevokeAttestation lets the original auditor mark an attestation as revoked.
func RevokeAttestation(cur realm, attestationID uint64, reason string) {
	mustCurrent(cur)
	rec := getAttestationRecord(attestationID)
	if rec == nil {
		panic("ironclad: attestation not found")
	}
	caller := cur.Previous().Address()
	if caller != rec.auditor {
		panic("ironclad: only original auditor may revoke attestation")
	}
	if rec.status == StatusRevoked {
		panic("ironclad: already revoked")
	}
	reason = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(reason))
	if reason == "" || len(reason) > maxSummaryLen {
		panic("ironclad: revocation reason required")
	}
	rec.status = StatusRevoked
	rec.revokeReason = reason
	if aud := getAuditorRecord(caller); aud != nil {
		aud.revocationsCount++
	}
	chain.Emit("AttestationRevoked", "attestation_id", strconv.FormatUint(attestationID, 10), "auditor", caller.String())
}

// --- Read-only value getters ---

func toAttestationView(r *attestationRecord) AttestationView {
	return AttestationView{
		ID:              r.id,
		Auditor:         r.auditor,
		TargetPkgPath:   r.targetPkgPath,
		SourceHash:      r.sourceHash,
		ReportDigest:    r.reportDigest,
		Digest:          r.digest,
		AnalyzerVersion: r.analyzerVersion,
		Critical:        r.critical,
		High:            r.high,
		Medium:          r.medium,
		Low:             r.low,
		Info:            r.info,
		Score:           r.score,
		Grade:           r.grade,
		RulesTriggered:  r.rulesTriggered,
		Summary:         r.summary,
		ReportURL:       r.reportURL,
		Height:          r.height,
		Status:          r.status,
		RevokeReason:    r.revokeReason,
		ChallengeCount:  r.challengeCount,
		OpenChallenges:  r.openChallenges,
	}
}

func GetAttestation(id uint64) (AttestationView, bool) {
	r := getAttestationRecord(id)
	if r == nil {
		return AttestationView{}, false
	}
	return toAttestationView(r), true
}

func GetChallenge(id uint64) (ChallengeView, bool) {
	c := getChallengeRecord(id)
	if c == nil {
		return ChallengeView{}, false
	}
	return ChallengeView{
		ID:              c.id,
		AttestationID:   c.attestationID,
		Challenger:      c.challenger,
		MissedRuleID:    c.missedRuleID,
		EvidenceDigest:  c.evidenceDigest,
		Reason:          c.reason,
		Height:          c.height,
		Status:          c.status,
		AuditorResponse: c.auditorResponse,
		ResolvedHeight:  c.resolvedHeight,
	}, true
}

// GetLatestByAuditor returns the latest attestation by a specific auditor for targetPkgPath.
func GetLatestByAuditor(targetPkgPath string, auditor address) (AttestationView, bool) {
	v := latestByPkgAuditor.Get(targetPkgPath + "|" + auditor.String())
	if v == nil {
		return AttestationView{}, false
	}
	return GetAttestation(v.(uint64))
}

// GetLatestForPackage returns the most recent valid (non-revoked) attestation
// across auditors for targetPkgPath (or most recent overall if all revoked).
func GetLatestForPackage(targetPkgPath string) (AttestationView, bool) {
	prefix := targetPkgPath + "|"
	end := targetPkgPath + "}"
	var fallback *attestationRecord
	var best *attestationRecord
	seen := 0
	pkgAttestations.ReverseIterate(prefix, end, func(_ string, v any) bool {
		seen++
		r := getAttestationRecord(v.(uint64))
		if r != nil {
			if fallback == nil {
				fallback = r
			}
			if r.status == StatusValid {
				best = r
				return true
			}
		}
		return seen >= maxRenderRows
	})
	if best != nil {
		return toAttestationView(best), true
	}
	if fallback != nil {
		return toAttestationView(fallback), true
	}
	return AttestationView{}, false
}

func VerifyAttestationByDigest(digest string) (uint64, bool) {
	if !pironclad.IsValidHexDigest(digest) {
		return 0, false
	}
	v := digestFirstIndex.Get(digest)
	if v == nil {
		return 0, false
	}
	id := v.(uint64)
	if rec := getAttestationRecord(id); rec != nil && rec.status == StatusValid {
		return id, true
	}
	prefix := digest + "|"
	end := digest + "}"
	foundActive := uint64(0)
	seen := 0
	auditorDigestIndex.Iterate(prefix, end, func(_ string, val any) bool {
		seen++
		if r := getAttestationRecord(val.(uint64)); r != nil && r.status == StatusValid {
			foundActive = r.id
			return true
		}
		return seen >= maxRenderRows
	})
	if foundActive != 0 {
		return foundActive, true
	}
	return id, true
}

func VerifyAttestationByDigestAndAuditor(digest string, auditor address) (uint64, bool) {
	if !pironclad.IsValidHexDigest(digest) {
		return 0, false
	}
	v := auditorDigestIndex.Get(digest + "|" + auditor.String())
	if v == nil {
		return 0, false
	}
	return v.(uint64), true
}

func GetAuditor(addr address) (AuditorView, bool) {
	a := getAuditorRecord(addr)
	if a == nil {
		return AuditorView{}, false
	}
	return AuditorView{
		Addr:              a.addr,
		Handle:            a.handle,
		Bio:               a.bio,
		WebsiteURL:        a.websiteURL,
		RegisteredHeight:  a.registeredHeight,
		AttestationsCount: a.attestationsCount,
		RevocationsCount:  a.revocationsCount,
	}, true
}

// --- Pure read-only gnoweb Markdown + JSON Renderer ---

// jsonEscape produces strict RFC 8259 JSON strings AND unicode-escapes Markdown
// metacharacters ([ ] < > * _ | # ! `) so :json/* routes cannot inject active
// Markdown links or structure when viewed in gnoweb (R7).
func jsonEscape(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '[', ']', '<', '>', '*', '_', '|', '#', '!', '`':
			b.WriteString(`\u00`)
			const hexDigits = "0123456789abcdef"
			b.WriteByte(hexDigits[c>>4])
			b.WriteByte(hexDigits[c&0x0f])
		default:
			if c < 0x20 {
				b.WriteString(" ")
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func parsePage(raw string) int {
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 {
		return 1
	}
	if n > maxPage {
		return maxPage
	}
	return n
}

func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderHome(1)
	}
	if strings.HasPrefix(path, "page/") {
		return renderHome(parsePage(strings.TrimPrefix(path, "page/")))
	}
	if path == "taxonomy" {
		return renderTaxonomy()
	}
	if path == "auditors" {
		return renderAuditors(1)
	}
	if strings.HasPrefix(path, "auditors/page/") {
		return renderAuditors(parsePage(strings.TrimPrefix(path, "auditors/page/")))
	}
	if strings.HasPrefix(path, "attestation/") {
		return renderAttestationDetail(strings.TrimPrefix(path, "attestation/"))
	}
	if strings.HasPrefix(path, "pkg/") {
		return renderPackageDetail(strings.TrimPrefix(path, "pkg/"))
	}
	if strings.HasPrefix(path, "json/") {
		return renderJSON(strings.TrimPrefix(path, "json/"))
	}
	return "# Ironclad — Not Found\n\nUnknown path " + sanitize.InlineCode(path) + ".\n\n[Back to Home](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad)\n"
}

func renderHome(page int) string {
	var b strings.Builder
	b.WriteString("# Ironclad — Gno Smart-Contract Security Attestation Registry\n\n")
	b.WriteString("> Multi-auditor, content-addressed on-chain audit certificates implementing Gno.land's official November 2026 Threat-Class Taxonomy (`gno-security.md`, `gno-ai-contract-review.md`, `AVL001`, `GLOBAL001`, `RENDER001`).\n")
	b.WriteString("> _Trust model: every attestation is an auditor-signed, self-reported claim bound to `(pkgPath, sourceHash, reportDigest)`. Inspect the auditor's identity and any open challenges before trusting a grade._\n\n")

	b.WriteString("## Registry Telemetry\n\n")
	b.WriteString("| Metric | Value |\n|---|---|\n")
	b.WriteString(ufmt.Sprintf("| Chain ID | `%s` |\n", runtime.ChainID()))
	b.WriteString(ufmt.Sprintf("| Block Height | `%d` |\n", runtime.ChainHeight()))
	b.WriteString(ufmt.Sprintf("| Total Attestations | `%d` |\n", attestations.Size()))
	b.WriteString(ufmt.Sprintf("| Distinct Attested Packages | `%d` |\n", pkgIndex.Size()))
	b.WriteString(ufmt.Sprintf("| Registered Auditors | `%d` |\n", auditors.Size()))
	b.WriteString(ufmt.Sprintf("| On-Chain Challenges | `%d` |\n\n", challenges.Size()))

	b.WriteString(ufmt.Sprintf("## Recent Security Attestations (Page %d)\n\n", page))
	if attestations.Size() == 0 {
		b.WriteString("_No audit attestations published yet._\n\n")
	} else {
		offset := (page - 1) * maxRenderRows
		b.WriteString("| ID | Package | Auditor | Grade | Score | Findings (C/H/M/L) | Status | Challenges | Source Hash |\n|---|---|---|---|---|---|---|---|---|\n")
		attestations.ReverseIterateByOffset(offset, maxRenderRows, func(_ string, v any) bool {
			r := v.(*attestationRecord)
			shortSrc := r.sourceHash[:12] + "..."
			shortAud := r.auditor.String()[:12] + "..."
			// R6: validated ASCII tokens placed cleanly inside backticks (no backslash artifacts).
			b.WriteString(ufmt.Sprintf(
				"| [%d](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:attestation/%d) | [`%s`](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:pkg/%s) | `%s` | **%s** | `%d/100` | `%d/%d/%d/%d` | `%s` | `%d` (%d open) | `%s` |\n",
				r.id, r.id,
				r.targetPkgPath,
				r.targetPkgPath,
				shortAud,
				r.grade,
				r.score,
				r.critical, r.high, r.medium, r.low,
				r.status,
				r.challengeCount, r.openChallenges,
				shortSrc,
			))
			return false
		})
		b.WriteString("\n")
		if page > 1 {
			b.WriteString(ufmt.Sprintf("[Prev Page](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:page/%d) ", page-1))
		}
		if page < maxPage && offset+maxRenderRows < attestations.Size() {
			b.WriteString(ufmt.Sprintf("[Next Page](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:page/%d)", page+1))
		}
		b.WriteString("\n\n")
	}

	b.WriteString("## Actions & Navigation\n\n")
	b.WriteString("- [Register as Auditor](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad$help&func=RegisterAuditor) · [Publish Attestation](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad$help&func=PublishAttestation) · [Challenge Attestation](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad$help&func=ChallengeAttestation)\n")
	b.WriteString("- [Threat-Class Taxonomy (15 Rules)](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:taxonomy) · [Auditor Directory](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:auditors)\n")
	b.WriteString("- Machine JSON: `:json/summary`, `:json/attestations`, `:json/pkg/<pkgPath>`, `:json/pkg-all/<pkgPath>`, `:json/attestation/<id>`\n")
	return b.String()
}

func renderTaxonomy() string {
	var b strings.Builder
	b.WriteString("# Ironclad — Official Gno Security Threat-Class Taxonomy (15 Rules)\n\n[Back to Home](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad)\n\n")
	b.WriteString("| Rule ID | Severity | Threat Class | Reference | Remediation |\n|---|---|---|---|---|\n")
	// Include GNO-SEC01 explicitly alongside the 14 pure /p/ taxonomy entries so all 15 rules are listed.
	b.WriteString("| `GNO-SEC01` | `CRITICAL` | Crossing function missing cur.IsCurrent() guard | `docs/resources/gno-ai-contract-review.md#1` | Call if !cur.IsCurrent() { panic(...) } before reading cur.Previous() or cur.Address(). |\n")
	for _, tc := range pironclad.Taxonomy() {
		b.WriteString(ufmt.Sprintf(
			"| `%s` | `%s` | %s | `%s` | %s |\n",
			tc.Code, tc.Severity, tc.Title, tc.Reference, tc.Remediation,
		))
	}
	return b.String()
}

func renderAuditors(page int) string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Ironclad — Registered Auditors (Page %d)\n\n[Back to Home](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad)\n\n", page))
	if auditors.Size() == 0 {
		b.WriteString("_No auditors registered yet._\n")
		return b.String()
	}
	offset := (page - 1) * maxRenderRows
	b.WriteString("| Handle | Address | Attestations | Revocations | Bio |\n|---|---|---|---|---|\n")
	auditors.ReverseIterateByOffset(offset, maxRenderRows, func(_ string, v any) bool {
		a := v.(*auditorRecord)
		b.WriteString(ufmt.Sprintf(
			"| **%s** | `%s` | `%d` | `%d` | %s |\n",
			sanitize.TableCell(a.handle), a.addr.String(), a.attestationsCount, a.revocationsCount, sanitize.TableCell(a.bio),
		))
		return false
	})
	return b.String()
}

// renderPackageDetail lists ALL auditors' attestations for a package (R2: multi-auditor view, no hijack).
func renderPackageDetail(pkgPath string) string {
	if !pironclad.ValidatePkgPath(pkgPath) {
		return "# Invalid Package Path\n\nPath " + sanitize.InlineCode(pkgPath) + " is not a valid `gno.land/r/...` or `gno.land/p/...` path.\n\n[Back to Home](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad)\n"
	}
	prefix := pkgPath + "|"
	end := pkgPath + "}"

	var rows []*attestationRecord
	seen := 0
	pkgAttestations.ReverseIterate(prefix, end, func(_ string, v any) bool {
		seen++
		if r := getAttestationRecord(v.(uint64)); r != nil {
			rows = append(rows, r)
		}
		return seen >= maxRenderRows
	})
	if len(rows) == 0 {
		return "# Package Not Attested\n\nNo Ironclad audit attestation exists for `" + pkgPath + "`.\n\n[Back to Home](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad)\n"
	}

	// Compute multi-auditor consensus summary over active (non-revoked) latest per auditor
	auditorSeen := make(map[string]bool)
	activeCount := 0
	scoreSum := 0
	minScore := 101
	for _, r := range rows {
		ak := r.auditor.String()
		if auditorSeen[ak] {
			continue
		}
		auditorSeen[ak] = true
		if r.status == StatusValid {
			activeCount++
			scoreSum += r.score
			if r.score < minScore {
				minScore = r.score
			}
		}
	}

	var b strings.Builder
	b.WriteString("# Security Certificates: `" + pkgPath + "`\n\n")
	b.WriteString("[Back to Home](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad) | [Taxonomy](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:taxonomy)\n\n")
	if activeCount > 0 {
		avg := scoreSum / activeCount
		b.WriteString(ufmt.Sprintf(
			"> **Multi-Auditor Consensus (%d active auditor(s)):** Mean Score `%d/100` · Lowest Auditor Score `%d/100` _(all attestations are auditor-signed, self-reported claims)_\n\n",
			activeCount, avg, minScore,
		))
	} else {
		b.WriteString("> **Status:** All attestations for this package have been revoked.\n\n")
	}

	b.WriteString("## All On-Chain Attestations (Newest First)\n\n")
	b.WriteString("| ID | Auditor | Grade | Score | Findings (C/H/M/L) | Status | Challenges | Source Hash | Block |\n|---|---|---|---|---|---|---|---|---|\n")
	for _, r := range rows {
		audLabel := r.auditor.String()[:12] + "..."
		if aud := getAuditorRecord(r.auditor); aud != nil {
			audLabel = sanitize.TableCell(aud.handle)
		}
		b.WriteString(ufmt.Sprintf(
			"| [#%d](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:attestation/%d) | %s | **%s** | `%d/100` | `%d/%d/%d/%d` | `%s` | `%d` (%d open) | `%s` | `%d` |\n",
			r.id, r.id,
			audLabel,
			r.grade,
			r.score,
			r.critical, r.high, r.medium, r.low,
			r.status,
			r.challengeCount, r.openChallenges,
			r.sourceHash[:12]+"...",
			r.height,
		))
	}
	return b.String()
}

// renderAttestationDetail renders the EXACT requested attestation record (R1) plus
// its revocation reason (if revoked) and bounded challenge/resolution log (R4).
func renderAttestationDetail(rawID string) string {
	id, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil {
		if aid, ok := VerifyAttestationByDigest(rawID); ok {
			id = aid
		} else {
			return "# Attestation Not Found\n\nUnknown attestation " + sanitize.InlineCode(rawID) + ".\n"
		}
	}
	att, ok := GetAttestation(id)
	if !ok {
		return "# Attestation Not Found\n\nNo attestation with ID `" + strconv.FormatUint(id, 10) + "`.\n"
	}

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Attestation #%d — `%s`\n\n", att.ID, att.TargetPkgPath))
	b.WriteString(ufmt.Sprintf("[Back to Home](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad) | [All Certificates for Package](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:pkg/%s) | [Challenge Attestation](/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad$help&func=ChallengeAttestation&attestationID=%d)\n\n", att.TargetPkgPath, att.ID))
	b.WriteString(ufmt.Sprintf(
		"> **Self-Reported Auditor Grade: `%s` (`%d / 100`)** — Status: `%s` — Open Challenges: `%d` — Analyzer: `%s`\n\n",
		att.Grade, att.Score, att.Status, att.OpenChallenges, att.AnalyzerVersion,
	))
	if att.Summary != "" {
		b.WriteString(sanitize.Block(att.Summary))
	}
	if att.Status == StatusRevoked && att.RevokeReason != "" {
		b.WriteString("**Revocation Reason:** " + sanitize.InlineText(att.RevokeReason) + "\n\n")
	}

	b.WriteString("| Field | Value |\n|---|---|\n")
	b.WriteString("| Attestation ID | `#" + strconv.FormatUint(att.ID, 10) + "` |\n")
	b.WriteString("| Target Package | `" + att.TargetPkgPath + "` |\n")
	b.WriteString("| Auditor | `" + att.Auditor.String() + "` |\n")
	b.WriteString("| Source SHA-256 | `" + att.SourceHash + "` |\n")
	b.WriteString("| Report Digest | `" + att.ReportDigest + "` |\n")
	b.WriteString("| On-Chain Commitment | `" + att.Digest + "` |\n")
	b.WriteString(ufmt.Sprintf("| Findings | Critical `%d` · High `%d` · Medium `%d` · Low `%d` · Info `%d` |\n",
		att.Critical, att.High, att.Medium, att.Low, att.Info))
	if att.RulesTriggered != "" {
		b.WriteString("| Rules Triggered | `" + att.RulesTriggered + "` |\n")
	}
	if att.ReportURL != "" {
		b.WriteString("| Report URL | " + sanitize.TableCell(att.ReportURL) + " |\n")
	}
	b.WriteString(ufmt.Sprintf("| Block Height | `%d` |\n\n", att.Height))

	// R4: Render bounded challenge & auditor resolution table for this attestation
	b.WriteString("## Challenges & Auditor Responses\n\n")
	chPrefix := seqid.ID(att.ID).Binary() + "|"
	chEnd := seqid.ID(att.ID).Binary() + "}"
	chCount := 0
	var chBuf strings.Builder
	attChallenges.ReverseIterate(chPrefix, chEnd, func(_ string, v any) bool {
		chCount++
		c := getChallengeRecord(v.(uint64))
		if c != nil {
			resp := "—"
			if c.auditorResponse != "" {
				resp = sanitize.TableCell(c.auditorResponse)
			}
			chBuf.WriteString(ufmt.Sprintf(
				"| `#%d` | `%s` | `%s` | `%s` | %s | %s |\n",
				c.id,
				c.missedRuleID,
				c.status,
				c.challenger.String()[:12]+"...",
				sanitize.TableCell(c.reason),
				resp,
			))
		}
		return chCount >= maxRenderRows
	})
	if chCount == 0 {
		b.WriteString("_No challenges filed against this attestation._\n")
	} else {
		b.WriteString("| ID | Rule | Outcome | Challenger | Reason | Auditor Response |\n|---|---|---|---|---|---|\n")
		b.WriteString(chBuf.String())
	}
	return b.String()
}

func attestationJSON(r *attestationRecord) string {
	return ufmt.Sprintf(
		`{"id":%d,"auditor":%s,"targetPkgPath":%s,"sourceHash":%s,"reportDigest":%s,"digest":%s,"analyzerVersion":%s,"critical":%d,"high":%d,"medium":%d,"low":%d,"info":%d,"score":%d,"grade":%s,"rulesTriggered":%s,"summary":%s,"reportUrl":%s,"height":%d,"status":%s,"revokeReason":%s,"challengeCount":%d,"openChallenges":%d}`,
		r.id, jsonEscape(r.auditor.String()), jsonEscape(r.targetPkgPath), jsonEscape(r.sourceHash),
		jsonEscape(r.reportDigest), jsonEscape(r.digest), jsonEscape(r.analyzerVersion),
		r.critical, r.high, r.medium, r.low, r.info, r.score, jsonEscape(r.grade),
		jsonEscape(r.rulesTriggered), jsonEscape(r.summary), jsonEscape(r.reportURL),
		r.height, jsonEscape(r.status), jsonEscape(r.revokeReason), r.challengeCount, r.openChallenges,
	)
}

func renderJSON(sub string) string {
	if sub == "summary" {
		return ufmt.Sprintf(
			`{"protocol":%s,"chainId":%s,"height":%d,"attestations":%d,"packages":%d,"auditors":%d,"challenges":%d}`,
			jsonEscape(pironclad.ProtocolVersion),
			jsonEscape(runtime.ChainID()),
			runtime.ChainHeight(),
			attestations.Size(),
			pkgIndex.Size(),
			auditors.Size(),
			challenges.Size(),
		)
	}
	if sub == "attestations" {
		var b strings.Builder
		b.WriteByte('[')
		first := true
		attestations.ReverseIterateByOffset(0, maxRenderRows, func(_ string, v any) bool {
			if !first {
				b.WriteByte(',')
			}
			first = false
			b.WriteString(attestationJSON(v.(*attestationRecord)))
			return false
		})
		b.WriteByte(']')
		return b.String()
	}
	if strings.HasPrefix(sub, "pkg/") {
		pkgPath := strings.TrimPrefix(sub, "pkg/")
		if att, ok := GetLatestForPackage(pkgPath); ok {
			if r := getAttestationRecord(att.ID); r != nil {
				return attestationJSON(r)
			}
		}
		return `{"error":"not_found"}`
	}
	if strings.HasPrefix(sub, "pkg-all/") {
		pkgPath := strings.TrimPrefix(sub, "pkg-all/")
		prefix := pkgPath + "|"
		end := pkgPath + "}"
		var b strings.Builder
		b.WriteByte('[')
		first := true
		seen := 0
		pkgAttestations.ReverseIterate(prefix, end, func(_ string, v any) bool {
			seen++
			if r := getAttestationRecord(v.(uint64)); r != nil {
				if !first {
					b.WriteByte(',')
				}
				first = false
				b.WriteString(attestationJSON(r))
			}
			return seen >= maxRenderRows
		})
		b.WriteByte(']')
		return b.String()
	}
	if strings.HasPrefix(sub, "attestation/") {
		raw := strings.TrimPrefix(sub, "attestation/")
		id, err := strconv.ParseUint(raw, 10, 64)
		if err != nil {
			if aid, ok := VerifyAttestationByDigest(raw); ok {
				id = aid
			}
		}
		if r := getAttestationRecord(id); r != nil {
			return attestationJSON(r)
		}
		return `{"error":"not_found"}`
	}
	return `{"error":"not_found"}`
}
