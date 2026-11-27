// Package whisper defines the canonical E2E-encrypted envelope, handle validation,
// and DeFi escrow evidence primitives for Arobi Whisper.
//
// Wire-compatible with live Arobi Whisper (aura-genesis.org/whisper):
//   - Client generates local X25519 (encryption) + Ed25519 (optional signing) keypairs.
//   - Each message is sealed client-side with an ephemeral X25519 key + HKDF-SHA256
//     (domain "arobi-whisper-x25519-xchacha-v1") + XChaCha20-Poly1305 (24-byte nonce).
//   - Commitment = SHA-256(ciphertext_bytes || ephemeralPk_bytes || nonce_bytes).
//   - Only ciphertext, ephemeral public key, nonce, and commitment ever touch chain state.
//
// Built on gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2 for RFC 6962 / RFC 9162 Merkle evidence anchoring.
package whisper

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"strings"

	"gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2"
)

const (
	EncodingVersion uint8 = 1
	DomainEnvelope        = "arobi-whisper-gno-envelope-v1"
	// v2 (2026-11-24): the escrow record encodes FeeBps, the fee fixed when it opens (PROTOCOL.md).
	DomainEscrow          = "arobi-whisper-gno-escrow-v2"

	// MaxCiphertextB64Len bounds on-chain encrypted payload size (16 KiB base64 ~ 12 KiB ciphertext).
	MaxCiphertextB64Len = 16384
)

// EscrowStatus tracks the lifecycle of a conditional DeFi escrow attached to an encrypted message.
type EscrowStatus string

const (
	EscrowOpen     EscrowStatus = "OPEN"
	EscrowClaimed  EscrowStatus = "CLAIMED"
	EscrowRefunded EscrowStatus = "REFUNDED"
)

var reservedHandles = map[string]bool{
	"arobi": true, "admin": true, "administrator": true, "support": true,
	"help": true, "security": true, "root": true, "system": true,
	"official": true, "whisper": true, "aura": true, "arobiteam": true,
	"moderator": true, "mod": true, "staff": true, "billing": true,
	"payments": true, "noreply": true, "ullumii": true, "treasury": true,
	"gaetano": true, "possumxi": true, "gno": true, "gnoland": true,
	"jaekwon": true,
}

// ValidateKeyHex validates a 32-byte (64 lowercase hex char) X25519 or Ed25519 public key.
func ValidateKeyHex(s string) error {
	_, err := assurance.ParseDigest(s)
	if err != nil {
		return errors.New("public key must be 64 lowercase hexadecimal characters (32 bytes)")
	}
	return nil
}

// ValidateNonceHex validates a 24-byte (48 lowercase hex char) XChaCha20-Poly1305 nonce.
func ValidateNonceHex(s string) error {
	if len(s) != 48 {
		return errors.New("nonce must be 48 lowercase hexadecimal characters (24 bytes)")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return errors.New("nonce must be 48 lowercase hexadecimal characters (24 bytes)")
		}
	}
	return nil
}

// ValidateCiphertextB64 verifies non-empty, bounded, canonical Base64 ciphertext.
func ValidateCiphertextB64(s string) error {
	if len(s) == 0 || len(s) > MaxCiphertextB64Len {
		return errors.New("ciphertext base64 length out of range (1..16384)")
	}
	if len(s)%4 != 0 {
		return errors.New("ciphertext must be canonical padded base64")
	}
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(raw) < 17 {
		// XChaCha20-Poly1305 carries a 16-byte Poly1305 auth tag + >= 1 byte plaintext.
		return errors.New("invalid ciphertext base64 or shorter than 16-byte AEAD tag")
	}
	if base64.StdEncoding.EncodeToString(raw) != s {
		return errors.New("ciphertext is not canonical base64")
	}
	return nil
}

// NormalizeHandle validates and normalizes a Whisper handle (3..20 lowercase a-z0-9_, no __).
func NormalizeHandle(raw string) (string, error) {
	u := strings.ToLower(strings.TrimSpace(raw))
	u = strings.TrimLeft(u, "@")
	if len(u) < 3 || len(u) > 20 {
		return "", errors.New("handle must be 3..20 characters")
	}
	if u[0] == '_' || u[len(u)-1] == '_' || strings.Contains(u, "__") {
		return "", errors.New("handle cannot start/end with underscore or contain double underscores")
	}
	for i := 0; i < len(u); i++ {
		c := u[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
		if !ok {
			return "", errors.New("handle may only contain lowercase letters, digits, and single underscores")
		}
	}
	if reservedHandles[u] {
		return "", errors.New("handle is reserved: " + u)
	}
	return u, nil
}

// SealedEnvelope is one end-to-end encrypted message stored on-chain (ciphertext only).
type SealedEnvelope struct {
	ID              uint64
	ChainID         string
	Realm           string
	From            string
	To              string
	EphemeralPubHex string
	NonceHex        string
	CiphertextB64   string
	CommitmentHex   string
	TipUgnot        int64
	EscrowID        uint64
	Height          int64
	LeafIndex       uint64
}

// Encode serializes SealedEnvelope into canonical length-prefixed big-endian bytes.
func (e SealedEnvelope) Encode() []byte {
	out := make([]byte, 0, 256)
	out = appendStr(out, DomainEnvelope)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, e.ID)
	out = appendStr(out, e.ChainID)
	out = appendStr(out, e.Realm)
	out = appendStr(out, e.From)
	out = appendStr(out, e.To)
	out = appendStr(out, e.EphemeralPubHex)
	out = appendStr(out, e.NonceHex)
	ctHash := sha256.Sum256([]byte(e.CiphertextB64))
	out = append(out, ctHash[:]...)
	out = appendStr(out, e.CommitmentHex)
	out = binary.BigEndian.AppendUint64(out, uint64(e.TipUgnot))
	out = binary.BigEndian.AppendUint64(out, e.EscrowID)
	out = binary.BigEndian.AppendUint64(out, uint64(e.Height))
	return out
}

// LeafHash returns the RFC 6962 leaf hash via gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2.
func (e SealedEnvelope) LeafHash() [32]byte {
	return assurance.LeafHash(e.Encode())
}

// EscrowRecord represents a conditional GNOT escrow attached to an encrypted Whisper message.
type EscrowRecord struct {
	ID            uint64
	MessageID     uint64
	Sender        string
	Recipient     string
	AmountUgnot   int64
	FeeBps        int64  // settlement fee locked at creation time (unaffected by later SetPricing)
	HashLockHex   string // empty = open recipient claim; 64-hex = SHA-256(preimage) HTLC
	ExpiryHeight  int64
	Status        EscrowStatus
	CreatedHeight int64
	SettledHeight int64
}

// Encode serializes EscrowRecord state for RFC 6962 evidence anchoring.
func (r EscrowRecord) Encode() []byte {
	out := make([]byte, 0, 232)
	out = appendStr(out, DomainEscrow)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, r.ID)
	out = binary.BigEndian.AppendUint64(out, r.MessageID)
	out = appendStr(out, r.Sender)
	out = appendStr(out, r.Recipient)
	out = binary.BigEndian.AppendUint64(out, uint64(r.AmountUgnot))
	out = binary.BigEndian.AppendUint64(out, uint64(r.FeeBps))
	out = appendStr(out, r.HashLockHex)
	out = binary.BigEndian.AppendUint64(out, uint64(r.ExpiryHeight))
	out = appendStr(out, string(r.Status))
	out = binary.BigEndian.AppendUint64(out, uint64(r.CreatedHeight))
	out = binary.BigEndian.AppendUint64(out, uint64(r.SettledHeight))
	return out
}

// LeafHash returns the RFC 6962 leaf hash via gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2.
func (r EscrowRecord) LeafHash() [32]byte {
	return assurance.LeafHash(r.Encode())
}

// ComputeHashLock computes SHA-256(preimage) as 64 lowercase hex characters for HTLC escrows.
func ComputeHashLock(preimage string) string {
	return assurance.Hex(assurance.HashString(preimage))
}

func appendStr(out []byte, s string) []byte {
	out = binary.BigEndian.AppendUint32(out, uint32(len(s)))
	return append(out, []byte(s)...)
}
