package rulecalc

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// App is one grant application. Its ID is its index in the revealed list.
type App struct {
	Title   string
	PkgPath string
	Payout  address
}

// AppsDigest is the commitment to an application list, published before the
// rule phase and checked at reveal: hex(sha256) of one "Title|PkgPath|Payout\n"
// line per app, in order, followed by salt.
// It panics if a field contains "|" or a newline, or the salt contains a
// newline, since the same digest could then open to a different list.
//
// Off-chain equivalent:
//
//	printf 'Title|PkgPath|Payout\n...salt' | sha256sum
func AppsDigest(apps []App, salt string) string {
	if strings.Contains(salt, "\n") {
		panic("rulecalc: salt contains newline")
	}
	var b strings.Builder
	for _, a := range apps {
		fields := []string{a.Title, a.PkgPath, string(a.Payout)}
		for _, f := range fields {
			if strings.ContainsAny(f, "|\n") {
				panic("rulecalc: application field contains | or newline")
			}
		}
		b.WriteString(strings.Join(fields, "|"))
		b.WriteString("\n")
	}
	b.WriteString(salt)
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}
