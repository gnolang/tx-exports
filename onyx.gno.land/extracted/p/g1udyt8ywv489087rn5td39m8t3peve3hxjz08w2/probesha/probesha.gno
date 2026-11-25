package probesha

import "crypto/sha256"

// Sum is the smallest possible use of crypto/sha256 in a gno package.
func Sum(s string) string {
	h := sha256.Sum256([]byte(s))
	return string(h[:4])
}
