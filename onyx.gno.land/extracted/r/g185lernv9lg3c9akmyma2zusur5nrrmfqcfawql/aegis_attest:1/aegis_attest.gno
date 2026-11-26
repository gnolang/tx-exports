// Package aegis_attest implements Aegis Attest, a verifiable agent evidence
// and EMA reputation ledger on Gno.land.
package aegis_attest

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	MaxHandleLen  = 48
	MaxCapLen     = 160
	MaxTaskIDLen  = 96
	MaxSummaryLen = 280
	MaxScoreBps   = 10000

	StatusVerified = "VERIFIED"
	StatusRevoked  = "REVOKED"

	realmURLPath = "/r/g185lernv9lg3c9akmyma2zusur5nrrmfqcfawql/aegis_attest"
)

type AgentProfile struct {
	Addr             address
	Handle           string
	Capabilities     string
	RegisteredHeight int64
	AttestationCount uint64
	AcceptedCount    uint64
	RevokedCount     uint64
	EmaScoreBps      int
}

type Attestation struct {
	ID             uint64
	Author         address
	Subject        address
	TaskOrMarketID string
	EvidenceSHA256 string
	Status         string
	ScoreBps       int
	Summary        string
	CreatedHeight  int64
	RevokedHeight  int64
	RevokeReason   string
}

var (
	agents       *avl.Tree // address string -> *AgentProfile
	attestations *avl.Tree // zero-padded id string -> *Attestation
	bySubject    *avl.Tree // "<subject>:<idKey>" -> uint64
	dedupIndex   *avl.Tree // "<subject>|<task>|<sha256>" -> uint64

	nextAttestationID uint64
	totalAgents       uint64
	totalActive       uint64
	totalRevoked      uint64
)

func init() {
	agents = avl.NewTree()
	attestations = avl.NewTree()
	bySubject = avl.NewTree()
	dedupIndex = avl.NewTree()
}

// RegisterAgent creates or updates an agent profile for the direct EOA caller.
func RegisterAgent(cur realm, handle string, capabilities string) string {
	if !cur.Previous().IsUserCall() {
		panic("aegis_attest: direct EOA call required")
	}
	caller := cur.Previous().Address()
	cleanHandle := sanitizeCell(handle, MaxHandleLen)
	if len(cleanHandle) == 0 {
		panic("aegis_attest: handle must be non-empty")
	}
	cleanCaps := sanitizeCell(capabilities, MaxCapLen)

	if prof, exists := agents.Get(caller.String()).(*AgentProfile); exists {
		prof.Handle = cleanHandle
		prof.Capabilities = cleanCaps
	} else {
		prof := &AgentProfile{
			Addr:             caller,
			Handle:           cleanHandle,
			Capabilities:     cleanCaps,
			RegisteredHeight: runtime.ChainHeight(),
		}
		agents.Set(caller.String(), prof)
		totalAgents++
	}

	chain.Emit(
		"AgentRegistered",
		"agent", caller.String(),
		"handle", cleanHandle,
	)
	return caller.String()
}

// SubmitAttestation anchors a 64-char SHA-256 evidence digest and EMA score (0..10000 bps).
func SubmitAttestation(
	cur realm,
	subject address,
	taskOrMarketID string,
	evidenceSHA256 string,
	scoreBps int,
	summary string,
) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("aegis_attest: direct EOA call required")
	}
	if !subject.IsValid() {
		panic("aegis_attest: invalid subject address")
	}
	cleanTask := sanitizeCell(taskOrMarketID, MaxTaskIDLen)
	if len(cleanTask) == 0 {
		panic("aegis_attest: taskOrMarketID must be non-empty")
	}
	hashLower := normalizeSHA256(evidenceSHA256)
	if scoreBps < 0 || scoreBps > MaxScoreBps {
		panic("aegis_attest: scoreBps out of 0..10000 range")
	}
	cleanSummary := sanitizeCell(summary, MaxSummaryLen)
	if len(cleanSummary) == 0 {
		panic("aegis_attest: summary must be non-empty")
	}

	dedupKey := subject.String() + "|" + cleanTask + "|" + hashLower
	if dedupIndex.Has(dedupKey) {
		panic("aegis_attest: duplicate attestation for subject/task/digest")
	}

	prof := ensureProfile(subject)
	author := cur.Previous().Address()

	nextAttestationID++
	id := nextAttestationID
	idKey := formatIDKey(id)

	att := &Attestation{
		ID:             id,
		Author:         author,
		Subject:        subject,
		TaskOrMarketID: cleanTask,
		EvidenceSHA256: hashLower,
		Status:         StatusVerified,
		ScoreBps:       scoreBps,
		Summary:        cleanSummary,
		CreatedHeight:  runtime.ChainHeight(),
	}

	attestations.Set(idKey, att)
	bySubject.Set(subject.String()+":"+idKey, id)
	dedupIndex.Set(dedupKey, id)

	prof.AttestationCount++
	prof.AcceptedCount++
	if prof.AcceptedCount == 1 {
		prof.EmaScoreBps = scoreBps
	} else {
		prof.EmaScoreBps = (prof.EmaScoreBps*7 + scoreBps*3) / 10
	}
	totalActive++

	chain.Emit(
		"AttestationSubmitted",
		"id", strconv.FormatUint(id, 10),
		"author", author.String(),
		"subject", subject.String(),
		"task_id", cleanTask,
		"evidence_sha256", hashLower,
		"score_bps", strconv.Itoa(scoreBps),
	)
	return id
}

// RevokeAttestation marks a previously anchored attestation as REVOKED (author-only).
func RevokeAttestation(cur realm, attestationID uint64, reason string) {
	if !cur.Previous().IsUserCall() {
		panic("aegis_attest: direct EOA call required")
	}
	idKey := formatIDKey(attestationID)
	att, exists := attestations.Get(idKey).(*Attestation)
	if !exists {
		panic("aegis_attest: attestation ID not found")
	}
	caller := cur.Previous().Address()
	if caller != att.Author {
		panic("aegis_attest: only attestation author may revoke")
	}
	if att.Status == StatusRevoked {
		panic("aegis_attest: attestation already revoked")
	}

	cleanReason := sanitizeCell(reason, MaxSummaryLen)
	if len(cleanReason) == 0 {
		cleanReason = "revoked by author"
	}

	att.Status = StatusRevoked
	att.RevokedHeight = runtime.ChainHeight()
	att.RevokeReason = cleanReason

	if prof, ok := agents.Get(att.Subject.String()).(*AgentProfile); ok {
		if prof.AcceptedCount > 0 {
			prof.AcceptedCount--
		}
		prof.RevokedCount++
	}
	if totalActive > 0 {
		totalActive--
	}
	totalRevoked++

	chain.Emit(
		"AttestationRevoked",
		"id", strconv.FormatUint(att.ID, 10),
		"author", caller.String(),
		"reason", cleanReason,
	)
}

// GetSummary returns zero-gas telemetry summary for QEval monitoring.
func GetSummary() string {
	return ufmt.Sprintf(
		"agents=%d|total_attestations=%d|active=%d|revoked=%d|height=%d",
		totalAgents, nextAttestationID, totalActive, totalRevoked, runtime.ChainHeight(),
	)
}

// GetAgentScoreBps returns the current EMA score (0..10000 bps) for an agent.
func GetAgentScoreBps(subject address) int {
	prof, exists := agents.Get(subject.String()).(*AgentProfile)
	if !exists {
		return -1
	}
	return prof.EmaScoreBps
}

// VerifyEvidenceHash reports true when an active non-revoked attestation matches the triple.
func VerifyEvidenceHash(subject address, taskOrMarketID string, evidenceSHA256 string) bool {
	dedupKey := subject.String() + "|" + sanitizeCell(taskOrMarketID, MaxTaskIDLen) + "|" + normalizeSHA256(evidenceSHA256)
	rawID, exists := dedupIndex.Get(dedupKey).(uint64)
	if !exists {
		return false
	}
	att, ok := attestations.Get(formatIDKey(rawID)).(*Attestation)
	if !ok {
		return false
	}
	return att.Status == StatusVerified
}

// Render serves native gnoweb markdown views for root dashboard and agent/:address.
func Render(path string) string {
	cleanPath := strings.Trim(path, "/")
	if strings.HasPrefix(cleanPath, "agent/") {
		target := strings.TrimPrefix(cleanPath, "agent/")
		return renderAgentDetail(target)
	}
	return renderHome()
}

func renderHome() string {
	regURL := txlink.NewLink("RegisterAgent").
		AddArgs("handle", "my-agent", "capabilities", "evidence-verification,onchain-eval").
		URL()

	var b strings.Builder
	b.WriteString("# Aegis Attest: Verifiable Agent Reputation & Evidence Ledger\n\n")
	b.WriteString("On-chain SHA-256 evidence anchoring, author-gated revocation, and bounded EMA scoring in Gno.\n\n")
	b.WriteString(ufmt.Sprintf("Live Block: `#%d` | [Register Agent](%s)\n\n", runtime.ChainHeight(), regURL))

	b.WriteString("## Ledger Metrics\n\n")
	b.WriteString("| Metric | Value |\n")
	b.WriteString("| --- | --- |\n")
	b.WriteString(ufmt.Sprintf("| Registered Agents | %d |\n", totalAgents))
	b.WriteString(ufmt.Sprintf("| Total Attestations | %d (%d active, %d revoked) |\n\n", nextAttestationID, totalActive, totalRevoked))

	b.WriteString("## Registered Agents\n\n")
	if agents.Size() == 0 {
		b.WriteString("_No agents registered yet._\n\n")
	} else {
		b.WriteString("| Handle | Address | Capabilities | EMA Score (bps) | Active / Total |\n")
		b.WriteString("| --- | --- | --- | --- | --- |\n")
		agents.Iterate("", "", func(_ string, v any) bool {
			p := v.(*AgentProfile)
			b.WriteString(ufmt.Sprintf(
				"| %s | [%s](%s:agent/%s) | %s | `%d` | %d / %d |\n",
				p.Handle, shortAddr(p.Addr), realmURLPath, p.Addr.String(), p.Capabilities, p.EmaScoreBps, p.AcceptedCount, p.AttestationCount,
			))
			return false
		})
		b.WriteString("\n")
	}

	b.WriteString("## Recent Attestations\n\n")
	if attestations.Size() == 0 {
		b.WriteString("_No attestations anchored yet._\n")
		return b.String()
	}

	b.WriteString("| ID | Task / Market | Subject | Score (bps) | Evidence SHA-256 | Status |\n")
	b.WriteString("| --- | --- | --- | --- | --- | --- |\n")
	count := 0
	attestations.ReverseIterate("", "", func(_ string, v any) bool {
		a := v.(*Attestation)
		b.WriteString(ufmt.Sprintf(
			"| #%d | %s | [%s](%s:agent/%s) | `%d` | `%s...` | **%s** |\n",
			a.ID, a.TaskOrMarketID, shortAddr(a.Subject), realmURLPath, a.Subject.String(), a.ScoreBps, a.EvidenceSHA256[:12], a.Status,
		))
		count++
		return count >= 25
	})
	return b.String()
}

func renderAgentDetail(addrStr string) string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Agent Audit: `%s`\n\n[<- Back to Aegis Attest](%s)\n\n", addrStr, realmURLPath))
	p, exists := agents.Get(addrStr).(*AgentProfile)
	if !exists {
		return b.String() + "_Agent not found in ledger._\n"
	}
	b.WriteString(ufmt.Sprintf(
		"- **Handle**: %s\n- **Capabilities**: %s\n- **EMA Score**: `%d` bps\n- **Active / Revoked**: %d / %d\n\n",
		p.Handle, p.Capabilities, p.EmaScoreBps, p.AcceptedCount, p.RevokedCount,
	))
	b.WriteString("## Agent Attestations\n\n")
	b.WriteString("| ID | Task / Market | Score | SHA-256 | Summary | Status |\n")
	b.WriteString("| --- | --- | --- | --- | --- | --- |\n")
	prefix := addrStr + ":"
	bySubject.ReverseIterate(prefix, prefix+"~", func(_ string, v any) bool {
		id := v.(uint64)
		if a, ok := attestations.Get(formatIDKey(id)).(*Attestation); ok {
			b.WriteString(ufmt.Sprintf(
				"| #%d | %s | `%d` | `%s` | %s | **%s** |\n",
				a.ID, a.TaskOrMarketID, a.ScoreBps, a.EvidenceSHA256, a.Summary, a.Status,
			))
		}
		return false
	})
	return b.String()
}

func ensureProfile(addr address) *AgentProfile {
	if prof, exists := agents.Get(addr.String()).(*AgentProfile); exists {
		return prof
	}
	prof := &AgentProfile{
		Addr:             addr,
		Handle:           "agent-" + shortAddr(addr),
		Capabilities:     "external-subject",
		RegisteredHeight: runtime.ChainHeight(),
	}
	agents.Set(addr.String(), prof)
	totalAgents++
	return prof
}

func normalizeSHA256(s string) string {
	trimmed := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(s, "0x"), "0X")))
	if len(trimmed) != 64 {
		panic("aegis_attest: evidenceSHA256 must be 64 hex chars")
	}
	for i := 0; i < len(trimmed); i++ {
		c := trimmed[i]
		isDigit := c >= '0' && c <= '9'
		isHex := c >= 'a' && c <= 'f'
		if !isDigit && !isHex {
			panic("aegis_attest: invalid hex char in evidenceSHA256")
		}
	}
	return trimmed
}

func sanitizeCell(s string, maxLen int) string {
	clean := strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(s, "\r", " "), "\n", " "), "|", "/"))
	if len(clean) > maxLen {
		return clean[:maxLen]
	}
	return clean
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}

func formatIDKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	if len(s) >= 12 {
		return s
	}
	return strings.Repeat("0", 12-len(s)) + s
}
