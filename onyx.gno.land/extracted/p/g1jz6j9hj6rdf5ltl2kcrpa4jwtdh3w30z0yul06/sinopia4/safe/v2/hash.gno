package safe

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

// MaxMerkleDepth bounds a proof: 2^32 leaves is far beyond any allowlist.
const MaxMerkleDepth = 32

func Sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// --- commit–reveal v2 (design §4.2) --------------------------------------
//
// Every formula is domain-separated by platform, purpose, version, chain and
// collection, so a secret or commit is useless anywhere else (RA M-5). They
// live here, not in core, so the frontend's verifier, the beacon service and
// the tests all port one definition.

// Commit is the value a creator ("creator") or the beacon ("beacon") commits
// to for collection cid on chain chainID.
func Commit(chainID, cid, role, secret string) string {
	return Sha256Hex(Domain + "|commit|v2|" + chainID + "|" + cid + "|" + role + "|" + secret)
}

// InitialEntropy seeds a collection's mint-entropy accumulator.
func InitialEntropy(chainID, cid string) string {
	return Sha256Hex(Domain + "|acc|v2|" + chainID + "|" + cid)
}

// MixEntropy folds one mint call into the accumulator. The inputs are
// public, but none existed when the secrets were committed, which is what
// stops a committer from choosing the map their own mints receive.
func MixEntropy(acc string, to address, height, first, last int64) string {
	return Sha256Hex(acc + "|" + to.String() + "|" + strconv.FormatInt(height, 10) + "|" +
		strconv.FormatInt(first, 10) + "-" + strconv.FormatInt(last, 10))
}

// Salt binds both secrets ("" when not revealed) to the final accumulator.
func Salt(cid, creatorSecret, beaconSecret, acc string) string {
	return Sha256Hex(Domain + "|salt|v2|" + cid + "|" + creatorSecret + "|" + beaconSecret + "|" + acc)
}

// Seed is the per-token engine seed once the salt is final.
func Seed(cid, tid, salt string) string {
	return Sha256Hex(Domain + "|seed|v1|" + cid + "|" + tid + "|" + salt)
}

// --- allowlist merkle proofs (design §4.6) -------------------------------

// AllowlistLeaf is the leaf for addr in collection cid's allowlist tree.
func AllowlistLeaf(cid string, addr address) string {
	return Sha256Hex(Domain + "|al|v1|" + cid + "|" + addr.String())
}

// MerkleVerify checks a sorted-pair sha256 proof ("hex,hex,…", leaf to
// root). An empty proof means the tree has a single leaf equal to the root.
// Malformed input is simply false: proofs come from untrusted callers.
func MerkleVerify(rootHex, leafHex, proof string) bool {
	root, err := hex.DecodeString(rootHex)
	if err != nil || len(root) != 32 {
		return false
	}
	node, err := hex.DecodeString(leafHex)
	if err != nil || len(node) != 32 {
		return false
	}
	if proof != "" {
		steps := strings.Split(proof, ",")
		if len(steps) > MaxMerkleDepth {
			return false
		}
		for _, step := range steps {
			sibling, err := hex.DecodeString(step)
			if err != nil || len(sibling) != 32 {
				return false
			}
			node = hashPair(node, sibling)
		}
	}
	return bytes.Equal(node, root)
}

// MerkleNodeTag prefixes every inner node (SA-I2): an inner node hashes
// 0x01 || lo || hi, while a leaf is the hash of a text that starts with
// Domain ("art|al|v1|…"), so an inner node can never be presented as a leaf
// or the other way round.
const MerkleNodeTag = byte(0x01)

// hashPair hashes the two children in byte order, so a proof needs no
// left/right flags.
func hashPair(a, b []byte) []byte {
	if bytes.Compare(b, a) < 0 {
		a, b = b, a
	}
	buf := make([]byte, 0, 65)
	buf = append(buf, MerkleNodeTag)
	buf = append(buf, a...)
	buf = append(buf, b...)
	sum := sha256.Sum256(buf)
	return sum[:]
}

// MerkleParent is hashPair on hex nodes, for tests and the off-chain builder.
func MerkleParent(aHex, bHex string) string {
	a, errA := hex.DecodeString(aHex)
	b, errB := hex.DecodeString(bHex)
	if errA != nil || errB != nil {
		panic("MerkleParent: invalid hex")
	}
	return hex.EncodeToString(hashPair(a, b))
}
