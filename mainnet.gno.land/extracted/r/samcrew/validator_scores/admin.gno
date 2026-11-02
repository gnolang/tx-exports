package validator_scores

import "strings"

// admin is the samcrew 2-of-3 multisig. Its only power is SetPublisher.
const admin address = "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf"

var publisher address = initialPublisher

// caller returns the frame-verified caller of a crossing function.
func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("validator_scores: stale realm")
	}
	return cur.Previous().Address()
}

func requirePublisher(cur realm) {
	if caller(cur) != publisher {
		panic("validator_scores: publisher only")
	}
}

// isCanonicalAddress accepts only a lowercase, checksummed g1 address.
func isCanonicalAddress(s string) bool {
	if len(s) != 40 || !strings.HasPrefix(s, "g1") || strings.ToLower(s) != s {
		return false
	}
	return address(s).IsValid()
}

// SetPublisher replaces the publisher. Admin only.
func SetPublisher(cur realm, addr address) {
	if caller(cur) != admin {
		panic("validator_scores: admin only")
	}
	if !isCanonicalAddress(string(addr)) {
		panic("validator_scores: invalid publisher address")
	}
	publisher = addr
}

// GetAdmin returns the admin address, for post-deployment checks.
func GetAdmin() string { return string(admin) }

// GetPublisher returns the current publisher address.
func GetPublisher() string { return string(publisher) }
