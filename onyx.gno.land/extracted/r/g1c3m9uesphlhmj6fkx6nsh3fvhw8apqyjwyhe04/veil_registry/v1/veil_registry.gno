// Package veil_registry provides a minimal on-chain discovery registry for
// Groth16/BN254 verifier packages on Gno.land.
//
// SECURITY NOTICE: Registration in this registry does NOT imply that a circuit
// or verifying key is trustworthy, audited, or backed by a trusted-setup
// ceremony. Consumers must independently verify provenance and VK fingerprints.
package veil_registry

import (
	"chain/runtime"
	"strconv"
	"strings"
)

type VerifierRecord struct {
	ID              uint64
	PkgPath         string
	VKFingerprint   string
	ProofSystem     string
	Curve           string
	PublicInputs    int
	Publisher       address
	Metadata        string
	Version         string
	PublishedHeight int64
	Deprecated      bool
}

const (
	MaxPkgPathLen          = 256
	MaxFingerprintLen      = 128
	MaxMetadataLen         = 512
	MaxVersionLen          = 32
	MaxPublicInputs        = 64
	MaxRecords             = 1024
	MaxRecordsPerPublisher = 32
	MaxPageSize            = 50
)

var (
	nextID          uint64 = 1
	records                = make(map[uint64]*VerifierRecord)
	byPath                 = make(map[string]uint64)
	publisherCounts        = make(map[address]int)
)

// RegisterVerifier publishes a verifier package entry. Callers may only
// register packages under their own gno.land/{p,r}/<address>/ namespace
// (and are capped at MaxRecordsPerPublisher) to prevent path squatting and
// global record exhaustion.
func RegisterVerifier(
	cur realm,
	pkgPath string,
	vkFingerprint string,
	proofSystem string,
	curve string,
	publicInputs int,
	metadata string,
	version string,
) uint64 {
	if nextID > MaxRecords {
		panic("veil_registry: registry capacity reached")
	}
	if len(pkgPath) == 0 || len(pkgPath) > MaxPkgPathLen ||
		len(vkFingerprint) == 0 || len(vkFingerprint) > MaxFingerprintLen ||
		len(metadata) > MaxMetadataLen ||
		len(version) == 0 || len(version) > MaxVersionLen {
		panic("veil_registry: invalid or oversized verifier metadata")
	}
	if hasControlOrDelimiter(pkgPath) || hasControlOrDelimiter(vkFingerprint) ||
		hasControlOrDelimiter(metadata) || hasControlOrDelimiter(version) {
		panic("veil_registry: delimiter or control character not allowed")
	}
	if proofSystem != "groth16" || curve != "bn254" || publicInputs < 0 || publicInputs > MaxPublicInputs {
		panic("veil_registry: unsupported proof system, curve, or public input count")
	}
	publisher := cur.Previous().Address()
	if !publisher.IsValid() {
		panic("veil_registry: invalid publisher address")
	}
	prefixR := "gno.land/r/" + publisher.String() + "/"
	prefixP := "gno.land/p/" + publisher.String() + "/"
	if !strings.HasPrefix(pkgPath, prefixR) && !strings.HasPrefix(pkgPath, prefixP) {
		panic("veil_registry: caller does not own package namespace")
	}
	if publisherCounts[publisher] >= MaxRecordsPerPublisher {
		panic("veil_registry: publisher record limit reached")
	}
	if _, exists := byPath[pkgPath]; exists {
		panic("veil_registry: package path already registered")
	}
	id := nextID
	nextID++
	publisherCounts[publisher]++
	records[id] = &VerifierRecord{
		ID:              id,
		PkgPath:         pkgPath,
		VKFingerprint:   vkFingerprint,
		ProofSystem:     proofSystem,
		Curve:           curve,
		PublicInputs:    publicInputs,
		Publisher:       publisher,
		Metadata:        metadata,
		Version:         version,
		PublishedHeight: runtime.ChainHeight(),
		Deprecated:      false,
	}
	byPath[pkgPath] = id
	return id
}

// DeprecateVerifier marks a registered verifier as deprecated. Only the
// original publisher may deprecate it.
func DeprecateVerifier(cur realm, id uint64) {
	rec, ok := records[id]
	if !ok {
		panic("veil_registry: record not found")
	}
	if cur.Previous().Address() != rec.Publisher {
		panic("veil_registry: only publisher can deprecate")
	}
	if rec.Deprecated {
		panic("veil_registry: already deprecated")
	}
	rec.Deprecated = true
}

// GetRecordCount returns the total number of registered verifiers.
func GetRecordCount() uint64 {
	return nextID - 1
}

// GetVerifier returns a formatted summary of a verifier record.
func GetVerifier(id uint64) string {
	rec, ok := records[id]
	if !ok {
		return ""
	}
	dep := "active"
	if rec.Deprecated {
		dep = "deprecated"
	}
	return rec.PkgPath + "|" + rec.VKFingerprint + "|" + rec.ProofSystem + "/" + rec.Curve + "|" + strconv.Itoa(rec.PublicInputs) + "|" + rec.Version + "|" + dep
}

// ListVerifiersPaged returns up to MaxPageSize formatted verifier records
// starting at 0-based offset. Returns "" on invalid bounds.
func ListVerifiersPaged(offset, limit int) string {
	if offset < 0 || limit <= 0 || limit > MaxPageSize {
		return ""
	}
	total := int(nextID - 1)
	if offset >= total {
		return ""
	}
	end := offset + limit
	if end > total {
		end = total
	}
	var b strings.Builder
	for i := offset; i < end; i++ {
		if i > offset {
			b.WriteByte('\n')
		}
		id := uint64(i + 1)
		b.WriteByte('#')
		b.WriteString(strconv.FormatUint(id, 10))
		b.WriteString(": ")
		b.WriteString(GetVerifier(id))
	}
	return b.String()
}

// Render displays the registry disclaimer and up to the latest MaxPageSize verifiers.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Veil Verifier Registry\n\n")
	b.WriteString("> Disclaimer: Registration does NOT imply that a circuit is trustworthy, audited, or ceremony-backed.\n\n")
	total := nextID - 1
	start := uint64(1)
	if total > uint64(MaxPageSize) {
		start = total - uint64(MaxPageSize) + 1
	}
	for id := start; id <= total; id++ {
		b.WriteString("- #")
		b.WriteString(strconv.FormatUint(id, 10))
		b.WriteString(": ")
		b.WriteString(GetVerifier(id))
		b.WriteByte('\n')
	}
	return b.String()
}

func hasControlOrDelimiter(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '|' || c < 0x20 || c == 0x7f {
			return true
		}
	}
	return false
}
