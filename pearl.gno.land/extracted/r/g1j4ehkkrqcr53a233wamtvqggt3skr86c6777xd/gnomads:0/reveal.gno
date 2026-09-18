package gnomads

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/gnomads/grc721/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	revealStateVeiled         = "VEILED"
	revealStateCommitted      = "REVEAL_COMMITTED"
	revealStateRevealing      = "REVEALING"
	revealStateRevealed       = "REVEALED"
	revealStateUnveiledFrozen = "UNVEILED_FROZEN"
	maxRevealBatch            = 20
)

var (
	revealState       = revealStateVeiled
	provenanceRoot    string
	revealCommitment  string
	finalBaseURI      string
	revealDeadline    int64
	revealSeedHash    string
	permutationA      int64
	permutationB      int64
	revealTarget      int64
	revealProcessed   int64
)

func RevealState() string { return revealState }

func ProvenanceRoot() string { return provenanceRoot }

func RevealCommitment() string { return revealCommitment }

func FinalBaseURI() string { return finalBaseURI }

func RevealDeadline() int64 { return revealDeadline }

func RevealSeedHash() string { return revealSeedHash }

func RevealTarget() int64 { return revealTarget }

func RevealProcessed() int64 { return revealProcessed }

func RevealOverdue() bool {
	return revealState == revealStateCommitted && time.Now().Unix() > revealDeadline
}

// ConfigureReveal permanently commits provenance, secret hash and final URI
// layout before the first token can be minted.
func ConfigureReveal(cur realm, provenance, commitment, baseURI string, deadline int64) {
	assertAdmin(cur.Previous().Address())
	if revealState != revealStateVeiled {
		panic("gnomads: reveal configuration already committed")
	}
	if token.TotalSupply() != 0 || !salePaused {
		panic("gnomads: configure reveal before minting and sale activation")
	}
	normalizedProvenance := normalizeHash(provenance)
	if normalizedProvenance == "" {
		panic("gnomads: invalid provenance root")
	}
	normalizedCommitment := normalizeHash(commitment)
	if normalizedCommitment == "" {
		panic("gnomads: invalid reveal commitment")
	}
	if !validFinalBaseURI(baseURI) {
		panic("gnomads: final base uri must be ipfs/https and end with slash")
	}
	if deadline <= time.Now().Unix() {
		panic("gnomads: reveal deadline must be in the future")
	}

	provenanceRoot = normalizedProvenance
	revealCommitment = normalizedCommitment
	finalBaseURI = baseURI
	revealDeadline = deadline
	revealState = revealStateCommitted

	chain.Emit(
		"RevealConfigured",
		"provenance", provenanceRoot,
		"commitment", revealCommitment,
		"deadline", ufmt.Sprintf("%d", revealDeadline),
	)
}

// ComputeRevealCommitment is deterministic but production secrets should be
// committed with the offline helper, never exposed through a public RPC query.
func ComputeRevealCommitment(secret string) string {
	payload := runtime.ChainID() + "|" + CollectionID() + "|REVEAL|" + secret
	return hashBytes([]byte(payload))
}

// Reveal is permissionless after public sale end (or sold out). Knowledge of
// the committed secret is the authorization, enabling an emergency reveal.
func Reveal(secret string) {
	if revealState != revealStateCommitted {
		panic("gnomads: reveal is not committed")
	}
	if len(secret) < 8 || len(secret) > 256 {
		panic("gnomads: reveal secret length must be 8..256")
	}
	if !saleConfigured || (time.Now().Unix() < saleConfig.publicEnd && token.TotalSupply() < maxSupply) {
		panic("gnomads: public sale has not ended")
	}
	if ComputeRevealCommitment(secret) != revealCommitment {
		panic("gnomads: reveal secret does not match commitment")
	}
	if token.TotalSupply() == 0 {
		panic("gnomads: cannot reveal an empty collection")
	}

	revealSeedHash = hashBytes([]byte("GNOMADS|SEED|" + secret))
	permutationA = derivePermutationA(secret)
	permutationB = deriveSeedNumber("B", secret) % maxSupply
	revealTarget = token.TotalSupply()
	revealProcessed = 0
	revealState = revealStateRevealing

	chain.Emit(
		"RevealStarted",
		"seedHash", revealSeedHash,
		"target", ufmt.Sprintf("%d", revealTarget),
	)
}

// ApplyRevealBatch updates sequentially minted tokens. Anyone may execute the
// deterministic batch, so the project operator cannot block progress.
func ApplyRevealBatch(startTokenID int64, quantity int) {
	if revealState != revealStateRevealing {
		panic("gnomads: reveal batch is not active")
	}
	if quantity < 1 || quantity > maxRevealBatch {
		panic("gnomads: reveal batch quantity must be 1..20")
	}
	if startTokenID != revealProcessed+1 {
		panic("gnomads: reveal batch must continue sequentially")
	}
	end := startTokenID + int64(quantity) - 1
	if end > revealTarget {
		panic("gnomads: reveal batch exceeds target")
	}

	for tokenID := startTokenID; tokenID <= end; tokenID++ {
		metadataID := MetadataID(tokenID)
		uri := finalBaseURI + metadataFilename(metadataID)
		if err := metadataLedger.SetTokenURI(grc721.TokenID(ufmt.Sprintf("%d", tokenID)), uri); err != nil {
			panic(err)
		}
	}
	revealProcessed = end
	if revealProcessed == revealTarget {
		revealState = revealStateRevealed
	}

	chain.Emit(
		"RevealBatchApplied",
		"startTokenId", ufmt.Sprintf("%d", startTokenID),
		"endTokenId", ufmt.Sprintf("%d", end),
		"processed", ufmt.Sprintf("%d", revealProcessed),
	)
}

// metadataFilename matches the immutable IPFS release layout (0001.json–3333.json).
func metadataFilename(metadataID int64) string {
	serial := ufmt.Sprintf("%d", metadataID)
	for len(serial) < 4 {
		serial = "0" + serial
	}
	return serial + ".json"
}

func MetadataID(tokenID int64) int64 {
	if revealState != revealStateRevealing &&
		revealState != revealStateRevealed &&
		revealState != revealStateUnveiledFrozen {
		panic("gnomads: metadata mapping is not revealed")
	}
	if tokenID < 1 || tokenID > revealTarget {
		panic("gnomads: token id outside reveal target")
	}
	return (permutationA*(tokenID-1)+permutationB)%maxSupply + 1
}

func FreezeMetadata(cur realm) {
	assertAdmin(cur.Previous().Address())
	if revealState != revealStateRevealed || revealProcessed != revealTarget {
		panic("gnomads: complete reveal before freezing metadata")
	}
	revealState = revealStateUnveiledFrozen
	chain.Emit("MetadataFrozen", "provenance", provenanceRoot, "seedHash", revealSeedHash)
}

func assertMintingAllowed() {
	if revealState != revealStateVeiled && revealState != revealStateCommitted {
		panic("gnomads: minting is closed after reveal starts")
	}
}

func validFinalBaseURI(uri string) bool {
	return (strings.HasPrefix(uri, "ipfs://") || strings.HasPrefix(uri, "https://")) &&
		strings.HasSuffix(uri, "/")
}

func derivePermutationA(secret string) int64 {
	candidate := deriveSeedNumber("A", secret) % maxSupply
	if candidate == 0 {
		candidate = 1
	}
	for gcd(candidate, maxSupply) != 1 {
		candidate++
		if candidate >= maxSupply {
			candidate = 1
		}
	}
	return candidate
}

func deriveSeedNumber(label, secret string) int64 {
	hash := hashBytes([]byte("GNOMADS|PERMUTATION|" + label + "|" + secret))
	value, err := strconv.ParseInt(hash[:15], 16, 64)
	if err != nil {
		panic(err)
	}
	return value
}

func gcd(first, second int64) int64 {
	for second != 0 {
		first, second = second, first%second
	}
	return first
}

func normalizeHash(value string) string {
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) != sha256.Size {
		return ""
	}
	return hex.EncodeToString(decoded)
}
