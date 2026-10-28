package memba_collections

import (
	"crypto/sha256"
	"encoding/hex"
)

// Merkle allowlist verifier (frozen, §5).
//   leaf = sha256(0x00 ‖ addr.String() ‖ ":" ‖ itoa(maxQty))   (bech32 string form, S-5)
//   node = sha256(0x01 ‖ sortedConcat(l, r))                    (domain-separated, sorted-pair)
// The sorted pair makes the proof order-independent and second-preimage safe.

func leafHash(addr address, maxQty int64) []byte {
	data := append([]byte{0x00}, []byte(addr.String()+":"+itoa(maxQty))...)
	h := sha256.Sum256(data)
	return h[:]
}

func parentHash(a, b []byte) []byte {
	var lo, hi []byte
	if compareBytes(a, b) <= 0 {
		lo, hi = a, b
	} else {
		lo, hi = b, a
	}
	data := make([]byte, 0, 1+len(lo)+len(hi))
	data = append(data, 0x01)
	data = append(data, lo...)
	data = append(data, hi...)
	h := sha256.Sum256(data)
	return h[:]
}

func compareBytes(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

// verifyAllowlist reconstructs the leaf from (addr, maxQty), folds the proof,
// and checks the computed root against the hex-encoded `root`. A single-leaf
// tree (empty proof) is valid when leaf == root. An empty root rejects.
func verifyAllowlist(root string, addr address, maxQty int64, proof []string) bool {
	if root == "" {
		return false
	}
	cur := leafHash(addr, maxQty)
	for _, sibHex := range proof {
		sib, err := hex.DecodeString(sibHex)
		if err != nil {
			return false
		}
		cur = parentHash(cur, sib)
	}
	return hex.EncodeToString(cur) == root
}
