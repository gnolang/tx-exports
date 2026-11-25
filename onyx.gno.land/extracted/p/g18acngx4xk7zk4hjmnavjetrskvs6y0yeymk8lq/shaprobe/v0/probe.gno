// Package shaprobe is a deployment probe importing an old crypto stdlib, so its
// approval status can be compared with bnprobe's.
package shaprobe

import "crypto/solsha3"

// Sum returns the sha3 sum of b.
func Sum(b []byte) []byte {
	return solsha3.Sum256(b)[:]
}
