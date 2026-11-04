package media

import (
	"crypto/sha256"
	"strconv"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
)

// Token → artwork assignment (design §7; frontend chain/perm.ts is the twin).
//
//	K         = sha256hex(PermDomain + collectionID + "|" + salt)
//	slot(tid) = Permute(K, slots, tid-1)    (single-artwork store: tid-1)
//
// The salt exists only once the collection is Final (commit–reveal v2), so
// nobody, the creator included, knows any token's slot before every token
// was sold and both secrets were revealed.

// PermKey is the permutation key of collection cid with its final salt.
func PermKey(cid, salt string) string {
	return safe.Sha256Hex(PermDomain + cid + "|" + salt)
}

// Permute is a bijection on [0, n): a 4-round Feistel network over b bits
// (b = bitlen(n-1) rounded up to an even number ≥ 2, so 2^b < 4n) with cycle
// walking. Round function: F = big-endian uint64 of the first 8 bytes of
// sha256(keyHex + "|" + r + "|" + R), masked to h = b/2 bits, with r and R
// in decimal. It panics unless 1 ≤ n and 0 ≤ x < n.
func Permute(keyHex string, n, x int64) int64 {
	if n < 1 || x < 0 || x >= n {
		panic("media: permute: need 0 <= x < n")
	}
	if n == 1 {
		return 0
	}
	b := bitLen(uint64(n - 1))
	if b < 2 {
		b = 2
	}
	if b%2 == 1 {
		b++
	}
	h := uint(b / 2)
	mask := uint64(1)<<h - 1
	prefix := keyHex + "|"
	v := uint64(x)
	// The walk stays on x's cycle, which contains x itself (< n), so it
	// ends; the bound only guards against a broken hash.
	for walk := 0; walk < 1<<uint(b); walk++ {
		l, r := v>>h, v&mask
		for round := 0; round < 4; round++ {
			f := roundF(prefix+strconv.Itoa(round)+"|", r) & mask
			l, r = r, l^f
		}
		v = l<<h | r
		if v < uint64(n) {
			return int64(v)
		}
	}
	panic("media: permute: cycle walk did not terminate")
}

func roundF(prefix string, r uint64) uint64 {
	sum := sha256.Sum256([]byte(prefix + strconv.FormatUint(r, 10)))
	return uint64(sum[0])<<56 | uint64(sum[1])<<48 | uint64(sum[2])<<40 | uint64(sum[3])<<32 |
		uint64(sum[4])<<24 | uint64(sum[5])<<16 | uint64(sum[6])<<8 | uint64(sum[7])
}

func bitLen(v uint64) int {
	n := 0
	for v > 0 {
		n++
		v >>= 1
	}
	return n
}

// Slot is the slot of token tid (1-based) in a store of `artworks`
// artworks and `slots` slots: the identity tid-1 for a single-artwork store
// (1/1 and editions: "Edition 3 of 50"), Permute(K, slots, tid-1) otherwise.
func Slot(keyHex string, artworks, slots, tid int64) int64 {
	if tid < 1 || tid > slots {
		panic("media: slot: token id out of range")
	}
	if artworks == 1 {
		return tid - 1
	}
	return Permute(keyHex, slots, tid-1)
}
