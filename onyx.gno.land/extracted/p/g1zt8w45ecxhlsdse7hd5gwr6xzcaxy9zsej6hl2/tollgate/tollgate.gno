// Package tollgate provides pure, deterministic accounting, x402 invoice memo
// binding, tiered metering math, and cryptographic receipt commitments for the
// Tollgate on-chain HTTP 402 payment and metered pass protocol.
package tollgate

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
)

const (
	// ProtocolVersion identifies the canonical commitment and memo format.
	ProtocolVersion = "tollgate-v1"
	// ReceiptDomain separates receipt commitment hashes from other hashes.
	ReceiptDomain = "tollgate-receipt-v1"
	// MemoPrefix binds x402 extra.memo invoices to a Tollgate service and nonce.
	MemoPrefix = "tollgate:v1:"
	// MaxMemoBytes matches the gnolang/x402 facilitator memo limit.
	MaxMemoBytes = 256
	// MinChallengeBlocks is the minimum dispute window for metered settlements.
	MinChallengeBlocks int64 = 10
	// MaxChallengeBlocks caps the dispute window to prevent permanent lockups.
	MaxChallengeBlocks int64 = 100000

	maxInt64 int64 = 1<<63 - 1
)

var (
	ErrInvalidPrice   = errors.New("tollgate: unit price must be positive")
	ErrInvalidUnits   = errors.New("tollgate: units must be positive")
	ErrOverflow       = errors.New("tollgate: arithmetic overflow")
	ErrInvalidBalance = errors.New("tollgate: invalid balance accounting")
	ErrInvalidMemo    = errors.New("tollgate: invalid invoice memo or nonce")
	ErrInvalidHash    = errors.New("tollgate: invalid hex digest")
)

// ChargeBreakdown describes the deterministic cost of a metered batch.
type ChargeBreakdown struct {
	Units       int64
	UnitPrice   int64
	GrossUgnot  int64
	DiscountBps int64
	Discount    int64
	NetUgnot    int64
}

// TierDiscountBps returns the deterministic volume discount in basis points
// (1 bps = 0.01%) for a settled batch size.
func TierDiscountBps(units int64) int64 {
	switch {
	case units >= 1000:
		return 2000 // 20%
	case units >= 250:
		return 1500 // 15%
	case units >= 50:
		return 1000 // 10%
	case units >= 10:
		return 500 // 5%
	default:
		return 0
	}
}

// ComputeCharge calculates gross, volume discount, and net ugnot charge using
// overflow-checked integer arithmetic. Net charge is always at least 1 ugnot
// whenever unitPrice > 0 and units > 0.
func ComputeCharge(unitPrice int64, units int64) (ChargeBreakdown, error) {
	if unitPrice <= 0 {
		return ChargeBreakdown{}, ErrInvalidPrice
	}
	if units <= 0 {
		return ChargeBreakdown{}, ErrInvalidUnits
	}
	if units > maxInt64/unitPrice {
		return ChargeBreakdown{}, ErrOverflow
	}
	gross := unitPrice * units
	bps := TierDiscountBps(units)

	var discount int64
	if bps > 0 {
		if gross > maxInt64/bps {
			discount = (gross / 10000) * bps
		} else {
			discount = (gross * bps) / 10000
		}
	}
	net := gross - discount
	if net < 1 {
		net = 1
		discount = gross - net
	}
	return ChargeBreakdown{
		Units:       units,
		UnitPrice:   unitPrice,
		GrossUgnot:  gross,
		DiscountBps: bps,
		Discount:    discount,
		NetUgnot:    net,
	}, nil
}

// ComputeAvailable returns deposit - spent - pending with strict invariant checks.
func ComputeAvailable(deposit, spent, pending int64) (int64, error) {
	if deposit < 0 || spent < 0 || pending < 0 {
		return 0, ErrInvalidBalance
	}
	if spent > deposit || pending > deposit-spent {
		return 0, ErrInvalidBalance
	}
	return deposit - spent - pending, nil
}

// ValidateSlug checks that a service slug is 2..40 chars of [a-z0-9-] with
// alphanumeric start and end (no consecutive hyphens).
func ValidateSlug(slug string) bool {
	n := len(slug)
	if n < 2 || n > 40 {
		return false
	}
	prevHyphen := false
	for i := 0; i < n; i++ {
		c := slug[i]
		isAlphaNum := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
		if isAlphaNum {
			prevHyphen = false
			continue
		}
		if c == '-' && i > 0 && i < n-1 && !prevHyphen {
			prevHyphen = true
			continue
		}
		return false
	}
	return true
}

// ValidateNonce checks that a client/invoice nonce uses safe ASCII tokens
// [a-zA-Z0-9._-] with length 1..96.
func ValidateNonce(nonce string) bool {
	n := len(nonce)
	if n < 1 || n > 96 {
		return false
	}
	for i := 0; i < n; i++ {
		c := nonce[i]
		ok := (c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// IsValidHexDigest returns true iff s is a lowercase 64-character hex SHA-256 string.
func IsValidHexDigest(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < 64; i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// FormatInvoiceMemo builds the canonical x402 extra.memo string binding an
// HTTP 402 payment offer to a specific Tollgate service ID and nonce.
func FormatInvoiceMemo(serviceID uint64, nonce string) (string, error) {
	if serviceID == 0 || !ValidateNonce(nonce) {
		return "", ErrInvalidMemo
	}
	memo := MemoPrefix + strconv.FormatUint(serviceID, 10) + ":" + nonce
	if len(memo) > MaxMemoBytes {
		return "", ErrInvalidMemo
	}
	return memo, nil
}

// ParseInvoiceMemo parses a canonical x402 extra.memo created by FormatInvoiceMemo.
func ParseInvoiceMemo(memo string) (serviceID uint64, nonce string, ok bool) {
	if len(memo) > MaxMemoBytes || !strings.HasPrefix(memo, MemoPrefix) {
		return 0, "", false
	}
	rest := memo[len(MemoPrefix):]
	sep := strings.IndexByte(rest, ':')
	if sep <= 0 || sep >= len(rest)-1 {
		return 0, "", false
	}
	id, err := strconv.ParseUint(rest[:sep], 10, 64)
	if err != nil || id == 0 {
		return 0, "", false
	}
	n := rest[sep+1:]
	if !ValidateNonce(n) {
		return 0, "", false
	}
	return id, n, true
}

func appendLP(b *strings.Builder, s string) {
	b.WriteString(strconv.Itoa(len(s)))
	b.WriteByte(':')
	b.WriteString(s)
	b.WriteByte('|')
}

// ReceiptCommitment computes the canonical, length-prefixed, domain-separated
// SHA-256 hex digest of a Tollgate usage or x402 payment receipt.
// Identical implementations exist in the Go and TypeScript SDKs.
func ReceiptCommitment(
	chainID string,
	serviceID uint64,
	passID uint64,
	buyer string,
	provider string,
	units int64,
	amountUgnot int64,
	nonce string,
	resourceHash string,
) string {
	var b strings.Builder
	b.WriteString(ReceiptDomain)
	b.WriteByte('|')
	appendLP(&b, chainID)
	b.WriteString(strconv.FormatUint(serviceID, 10))
	b.WriteByte('|')
	b.WriteString(strconv.FormatUint(passID, 10))
	b.WriteByte('|')
	appendLP(&b, buyer)
	appendLP(&b, provider)
	b.WriteString(strconv.FormatInt(units, 10))
	b.WriteByte('|')
	b.WriteString(strconv.FormatInt(amountUgnot, 10))
	b.WriteByte('|')
	appendLP(&b, nonce)
	appendLP(&b, resourceHash)

	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

// VerifyReceiptCommitment performs a constant-time check of expectedHex against
// the recomputed canonical receipt commitment.
func VerifyReceiptCommitment(
	expectedHex string,
	chainID string,
	serviceID uint64,
	passID uint64,
	buyer string,
	provider string,
	units int64,
	amountUgnot int64,
	nonce string,
	resourceHash string,
) bool {
	if !IsValidHexDigest(expectedHex) {
		return false
	}
	got := ReceiptCommitment(
		chainID, serviceID, passID, buyer, provider,
		units, amountUgnot, nonce, resourceHash,
	)
	if len(got) != len(expectedHex) {
		return false
	}
	var diff byte
	for i := 0; i < len(got); i++ {
		diff |= got[i] ^ expectedHex[i]
	}
	return diff == 0
}

// HashResource computes the lowercase SHA-256 hex digest of a canonical HTTP
// resource descriptor (for example, "GET /v1/inference?model=fast").
func HashResource(descriptor string) string {
	sum := sha256.Sum256([]byte(descriptor))
	return hex.EncodeToString(sum[:])
}
