package poker

import (
	"crypto/modexp"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/poker/cards"
)

// This file is the only one importing crypto/modexp. For networks without it,
// replace it with verify_nomodexp.gno.txt (renamed to verify.gno).

const challengesEnabled = true

var primeP = cards.P()

// powModP returns base^exp mod P as 256 bytes.
func powModP(base, exp []byte) []byte {
	return modexp.ModExp(base, exp, primeP)
}
