// Package memba_quest_attestation_v1 is the on-chain quest/XP attestation realm
// for Memba (audit Q-05, Track A — "Model B" offline-signed voucher).
//
// WHY: Memba quest XP lives in a centralized backend DB; the chain holds no
// verifiable record. This realm makes a quest completion + its XP an independently
// verifiable on-chain fact, WITHOUT giving the backend a hot key that can write
// arbitrary state.
//
// HOW (Model B — offline voucher):
//   - The backend holds an OFFLINE ed25519 signing key; it NEVER broadcasts.
//   - For a server-verified completion it issues a voucher
//     (address, questId, xp, nonce) + ed25519 signature
//     over the canonical message
//     addr "|" questId "|" itoa(xp) "|" nonce            (UTF-8 bytes)
//   - The USER broadcasts RecordCompletion(...) with the voucher (they pay gas).
//   - This realm verifies the signature against the configured signer pubkey,
//     rejects reused nonces (replay), bounds xp, and records the completion +
//     cumulative attested XP.
//
// TRUST MODEL: the signature is the authority, NOT the caller — anyone may
// broadcast a valid voucher (it can only record the backend-attested fact). The
// only privileged action is rotating the signer pubkey (owner multisig).
//
// The canonical message format is a CONTRACT with the backend signer — it MUST
// stay byte-identical on both sides. See canonicalMsg.
package memba_quest_attestation_v1

import (
	"crypto/ed25519"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/samcrew/avl"
	"gno.land/p/nt/ufmt/v0"

	"chain/runtime"
	"chain/runtime/unsafe"
)

// ── Constants ────────────────────────────────────────────────
const (
	// OwnerAddress is the samcrew-core-test1 multisig on test13 (realm owner /
	// signer-key rotator). CONFIRM before deploy.
	OwnerAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

	// MaxAttestXP bounds the XP a single voucher can carry. This caps the blast
	// radius if the offline signer key ever leaks: a leaked key can still forge
	// vouchers, but cannot mint unbounded XP in one call. Generous vs the real
	// max single-quest XP (≤100).
	MaxAttestXP = 1000

	pubKeySize = 32 // ed25519 public key length (gno crypto/ed25519 exposes no const)
	sigSize    = 64 // ed25519 signature length
	fieldSep   = "|"
)

// ── State ────────────────────────────────────────────────────
var (
	// signerPubKey is the backend's offline ed25519 PUBLIC key (32 bytes). Set by
	// the owner via SetSigner after deploy; until then NO voucher verifies.
	signerPubKey []byte

	completions *avl.Tree // addr + ":" + questId -> int64 (block height recorded)
	attestedXP  *avl.Tree // addr               -> int   (cumulative attested XP)
	usedNonce   *avl.Tree // nonce              -> true  (replay guard)
)

func init() {
	completions = avl.NewTree()
	attestedXP = avl.NewTree()
	usedNonce = avl.NewTree()
}

// ── Pure helpers (unit-tested) ───────────────────────────────

// canonicalMsg is the EXACT byte string the backend signs offline and this realm
// verifies. It MUST stay byte-identical to the backend signer (ADR Track A / A.3).
// strconv.Itoa gives a canonical decimal with no leading zeros, so both sides
// agree for any xp.
func canonicalMsg(addr, questId string, xp int, nonce string) []byte {
	return []byte(addr + fieldSep + questId + fieldSep + strconv.Itoa(xp) + fieldSep + nonce)
}

func completionKey(addr, questId string) string { return addr + ":" + questId }

// validXP bounds the attestable XP (see MaxAttestXP).
func validXP(xp int) bool { return xp > 0 && xp <= MaxAttestXP }

// fieldsClean rejects any voucher field containing the separator. This makes the
// canonical message PROVABLY unambiguous (no field-injection collision) without
// trusting the backend's nonce charset: with no field able to contain "|", a
// given canonical byte string maps to exactly one (addr, questId, xp, nonce).
func fieldsClean(addr, questId, nonce string) bool {
	return !strings.Contains(addr, fieldSep) &&
		!strings.Contains(questId, fieldSep) &&
		!strings.Contains(nonce, fieldSep)
}

// verifyVoucher reports whether sigHex is a valid ed25519 signature by pub over
// the canonical voucher message. Pure (no state) so it is unit-tested directly
// with offline-generated test vectors.
func verifyVoucher(pub []byte, addr, questId string, xp int, nonce, sigHex string) bool {
	if len(pub) != pubKeySize {
		return false
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil || len(sig) != sigSize {
		return false
	}
	return ed25519.Verify(pub, canonicalMsg(addr, questId, xp, nonce), sig)
}

// ── Owner: rotate the signer key ─────────────────────────────

// SetSigner installs/rotates the backend's offline signer PUBLIC key (32-byte
// hex). Owner-multisig only. This is a crossing function, so PreviousRealm()
// correctly identifies the immediate caller (see gno interrealm semantics).
func SetSigner(cur realm, pubKeyHex string) {
	if unsafe.PreviousRealm().Address() != address(OwnerAddress) {
		panic("unauthorized: owner multisig only")
	}
	pub, err := hex.DecodeString(pubKeyHex)
	if err != nil || len(pub) != pubKeySize {
		panic("signer pubkey must be 32-byte hex")
	}
	signerPubKey = pub
}

// ── User-broadcast: record a signed completion voucher ───────

// RecordCompletion verifies a backend-signed voucher and records the completion
// + its XP on-chain. Idempotent per (addr, questId); replay-proof per nonce.
// Panics (reverting the tx) on any invalid/again-used/out-of-range voucher.
func RecordCompletion(cur realm, addr, questId string, xp int, nonce, sigHex string) {
	if len(signerPubKey) != pubKeySize {
		panic("attestation signer not configured")
	}
	if addr == "" || questId == "" || nonce == "" {
		panic("missing voucher field")
	}
	if !fieldsClean(addr, questId, nonce) {
		panic("voucher field must not contain the separator")
	}
	if !validXP(xp) {
		panic("xp out of range")
	}
	if _, used := usedNonce.Get(nonce); used {
		panic("nonce already used")
	}
	if !verifyVoucher(signerPubKey, addr, questId, xp, nonce, sigHex) {
		panic("invalid voucher signature")
	}

	// Consume the nonce (replay guard) before the idempotency early-return below,
	// so a replayed voucher always fails even for an already-recorded completion.
	usedNonce.Set(nonce, true)

	// Idempotent on (addr, questId): a second, distinct-nonce voucher for an
	// already-recorded completion must NOT double-count XP.
	ck := completionKey(addr, questId)
	if _, exists := completions.Get(ck); exists {
		return
	}
	completions.Set(ck, runtime.ChainHeight())

	prev := 0
	if v, ok := attestedXP.Get(addr); ok {
		prev = v.(int)
	}
	attestedXP.Set(addr, prev+xp)
}

// ── Public reads ─────────────────────────────────────────────

// GetAttestedXP returns addr's cumulative on-chain attested XP (0 if none).
func GetAttestedXP(addr string) int {
	if v, ok := attestedXP.Get(addr); ok {
		return v.(int)
	}
	return 0
}

// GetRecordedCompletions returns addr's attested quest IDs as a comma-separated
// list (empty string if none), in ascending key order.
func GetRecordedCompletions(addr string) string {
	prefix := addr + ":"
	out := []string{}
	completions.Iterate(prefix, addr+";", func(key string, _ interface{}) bool {
		out = append(out, strings.TrimPrefix(key, prefix))
		return false
	})
	return strings.Join(out, ",")
}

// Render is the human/gnoweb view; the authoritative reads are the exported
// Get* funcs (queried via vm/qeval).
func Render(path string) string {
	if path == "" {
		signer := "not configured"
		if len(signerPubKey) == pubKeySize {
			signer = "configured"
		}
		return ufmt.Sprintf(
			"# Memba Quest Attestation\n\nVerifiable on-chain quest/XP records (offline-signed vouchers).\n\n- Completions attested: %d\n- Accounts with attested XP: %d\n- Signer: %s\n",
			completions.Size(), attestedXP.Size(), signer)
	}
	if strings.HasPrefix(path, "user/") {
		addr := strings.TrimPrefix(path, "user/")
		comps := GetRecordedCompletions(addr)
		if comps == "" {
			comps = "(none)"
		}
		return ufmt.Sprintf("# %s\n\n- Attested XP: %d\n- Completions: %s\n", addr, GetAttestedXP(addr), comps)
	}
	return "404"
}
