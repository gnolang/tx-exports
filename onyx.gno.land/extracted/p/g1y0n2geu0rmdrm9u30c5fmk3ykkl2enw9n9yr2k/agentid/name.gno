// Package agentid is the Agent ID name standard.
//
// A registry realm stores which wallet owns a name. This package only
// decides which strings are names. The display suffix is not part of the
// on-chain key.
package agentid

const (
	// MinLen is the shortest claimable name.
	MinLen = 3
	// MaxLen is the longest claimable name.
	MaxLen = 15
	// Suffix is the label shown to people. Claim and Pay use the bare name.
	Suffix = ".agent"
)

// Valid reports whether name is 3–15 lowercase letters or digits.
func Valid(name string) bool {
	if len(name) < MinLen || len(name) > MaxLen {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

// Reserved reports whether name is held back from claims.
func Reserved(name string) bool {
	switch name {
	case "gno", "admin", "root", "sys", "system", "ugnot":
		return true
	default:
		return false
	}
}
