package fishcut

import "crypto/sha256"

func Version() string { return "cut-1" }

func Sum() int {
	sum := sha256.Sum256([]byte("shoal"))
	return int(sum[0])
}
