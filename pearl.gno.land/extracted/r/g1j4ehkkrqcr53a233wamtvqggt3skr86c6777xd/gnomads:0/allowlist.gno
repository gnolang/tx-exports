package gnomads

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

const maxMerkleProofDepth = 32

var (
	allowlistRoot       string
	allowlistRootLocked bool
)

func AllowlistRoot() string { return allowlistRoot }

func AllowlistRootLocked() bool { return allowlistRootLocked }

// SetAllowlistRoot accepts a lowercase/uppercase 32-byte SHA-256 hash in hex.
// The first sale unpause permanently locks the root for this deployment.
func SetAllowlistRoot(cur realm, root string) {
	assertAdmin(cur.Previous().Address())
	if !salePaused {
		panic("gnomads: pause sale before setting allowlist root")
	}
	if allowlistRootLocked {
		panic("gnomads: allowlist root is locked")
	}
	decoded, ok := decodeMerkleHash(root)
	if !ok || len(decoded) != sha256.Size {
		panic("gnomads: invalid allowlist root")
	}
	allowlistRoot = hex.EncodeToString(decoded)
	chain.Emit("AllowlistRootConfigured", "root", allowlistRoot)
}

// AllowlistLeaf binds a claim to this chain, collection, phase, address,
// individual allowance and configured unit price.
func AllowlistLeaf(owner address, allowance int, unitPrice int64) string {
	payload := runtime.ChainID() + "|" +
		CollectionID() + "|" +
		salePhaseAllowlist + "|" +
		owner.String() + "|" +
		ufmt.Sprintf("%d", allowance) + "|" +
		ufmt.Sprintf("%d", unitPrice)
	return hashBytes([]byte(payload))
}

// VerifyAllowlist expects comma-separated 64-character hex sibling hashes.
// Pair hashing is sorted, so proofs do not need left/right direction flags.
func VerifyAllowlist(owner address, allowance int, unitPrice int64, proof string) bool {
	if allowlistRoot == "" || allowance < 1 || allowance > maxSupplyAsInt() {
		return false
	}

	computed := AllowlistLeaf(owner, allowance, unitPrice)
	siblings, ok := parseMerkleProof(proof)
	if !ok {
		return false
	}
	for _, sibling := range siblings {
		computed = hashMerklePair(computed, sibling)
	}
	return computed == allowlistRoot
}

func MintAllowlist(cur realm, quantity, allowance int, unitPrice int64, proof string) {
	if !cur.Previous().IsUserCall() {
		panic("gnomads: only direct user calls can mint")
	}
	if SalePhase() != salePhaseAllowlist {
		panic("gnomads: allowlist sale is not active")
	}
	if unitPrice != saleConfig.allowlistPrice {
		panic("gnomads: allowlist price mismatch")
	}
	if allowance < 1 || allowance > saleConfig.allowlistLimit {
		panic("gnomads: invalid allowlist allowance")
	}

	caller := cur.Previous().Address()
	if !VerifyAllowlist(caller, allowance, unitPrice, proof) {
		panic("gnomads: invalid allowlist proof")
	}
	assertSaleMint(quantity, AllowlistMinted(caller), allowance)
	required := requiredPayment(unitPrice, quantity)
	sent := unsafe.OriginSend()
	assertExactPayment(sent, required)

	mintTokens(caller, quantity)
	allowlistMintedByWallet.Set(caller.String(), AllowlistMinted(caller)+quantity)
	forwardPayment(cur, sent)

	chain.Emit(
		"AllowlistMint",
		"minter", caller.String(),
		"quantity", ufmt.Sprintf("%d", quantity),
		"allowance", ufmt.Sprintf("%d", allowance),
		"paid", ufmt.Sprintf("%d", required),
	)
}

func parseMerkleProof(proof string) ([]string, bool) {
	if proof == "" {
		return []string{}, true
	}
	parts := strings.Split(proof, ",")
	if len(parts) > maxMerkleProofDepth {
		return nil, false
	}
	for i, part := range parts {
		decoded, ok := decodeMerkleHash(part)
		if !ok {
			return nil, false
		}
		parts[i] = hex.EncodeToString(decoded)
	}
	return parts, true
}

func hashMerklePair(first, second string) string {
	left, leftOK := decodeMerkleHash(first)
	right, rightOK := decodeMerkleHash(second)
	if !leftOK || !rightOK {
		return ""
	}
	if second < first {
		left, right = right, left
	}
	combined := make([]byte, 0, sha256.Size*2)
	combined = append(combined, left...)
	combined = append(combined, right...)
	return hashBytes(combined)
}

func hashBytes(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func decodeMerkleHash(value string) ([]byte, bool) {
	if len(value) != sha256.Size*2 {
		return nil, false
	}
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) != sha256.Size {
		return nil, false
	}
	return decoded, true
}

func maxSupplyAsInt() int { return int(maxSupply) }
