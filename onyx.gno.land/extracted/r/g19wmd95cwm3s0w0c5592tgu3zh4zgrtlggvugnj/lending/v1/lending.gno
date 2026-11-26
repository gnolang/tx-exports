// Package lending is the demo's integrator: a lending desk that only takes
// a vault as a collateral source after asking Bouncer. It holds no coins
// and does no lending maths; it shows the integration pattern.
//
// Integrate calls bouncer.Check(vault, bouncer.Standard()): the vault's
// latest attestation must score 75 or more with no PROVEN Critical or High
// finding. A vault that fails is refused with its live score and verdict.
// Render re-checks every accepted vault, so a later attestation that turns
// red shows up here at once.
package lending

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	bouncer "gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/v2"
)

var (
	owner    address         // the deployer; only it adds vaults
	accepted = avl.NewTree() // vault pkgpath -> block height accepted
)

func init(cur realm) {
	// Under gno test the deployer has no address; then no owner is set,
	// which locks Integrate rather than opening it.
	owner = cur.Previous().Address()
}

// Integrate accepts vault as a collateral source if it passes Bouncer's
// Standard policy, and panics with the reason otherwise.
func Integrate(cur realm, vault string) {
	if !cur.IsCurrent() {
		panic("not current")
	}
	caller := cur.Previous().Address()
	if owner == "" || caller != owner {
		panic("owner only")
	}
	if !validVault(vault) {
		panic("not a realm path: " + vault)
	}
	if accepted.Has(vault) {
		panic("already accepted")
	}
	if !bouncer.Check(vault, bouncer.Standard()) {
		panic(vault + " did not pass Bouncer's Standard policy: " + status(vault))
	}
	accepted.Set(vault, runtime.ChainHeight())
	chain.Emit("Integrated", "vault", vault)
}

// Accepted returns the accepted vaults, in path order.
func Accepted() []string {
	out := make([]string, 0, accepted.Size())
	accepted.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

// status describes vault's latest attestation in one line.
func status(vault string) string {
	a, ok := bouncer.Latest(vault)
	if !ok {
		return "not attested by Bouncer yet"
	}
	return strconv.Itoa(a.Score) + " / " + a.Grade + ", " + verdictText(a.Verdict)
}

func verdictText(v string) string {
	switch v {
	case bouncer.VerdictNotRecommended:
		return "🔴 not recommended for integration"
	case bouncer.VerdictReview:
		return "🟠 review before integration"
	case bouncer.VerdictClear:
		return "🟢 no known Critical or High issues"
	}
	return v
}

// validVault accepts gno.land/r/ paths of lowercase letters, digits,
// underscores and slashes, so a path is safe to print in Markdown.
func validVault(p string) bool {
	rest, ok := strings.CutPrefix(p, "gno.land/r/")
	if !ok || rest == "" || len(p) > 256 || strings.Contains(rest, "//") || strings.HasSuffix(rest, "/") {
		return false
	}
	for _, c := range rest {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '/') {
			return false
		}
	}
	return true
}

func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Lending desk\n\n")
	b.WriteString("This desk only takes a vault as a collateral source after asking ")
	b.WriteString("[Bouncer](/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/v2): ")
	b.WriteString("`bouncer.Check(vault, bouncer.Standard())` must pass, meaning a score of 75 or more ")
	b.WriteString("and no PROVEN Critical or High finding. A vault that fails is refused with its score and verdict.\n\n")
	b.WriteString("## Accepted vaults\n\n")
	if accepted.Size() == 0 {
		b.WriteString("None yet.\n\n")
	} else {
		b.WriteString("| Vault | Bouncer now | Still passes |\n| --- | --- | --- |\n")
		for _, v := range Accepted() {
			still := "✅"
			if !bouncer.Check(v, bouncer.Standard()) {
				still = "❌ (a later scan changed the verdict)"
			}
			b.WriteString("| [`" + v + "`](" + strings.TrimPrefix(v, "gno.land") + ") | " + status(v) + " " + bouncer.Badge(v) + " | " + still + " |\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("## Add a vault (owner only)\n\n")
	b.WriteString("<gno-form exec=\"Integrate\">\n  <gno-input name=\"vault\" placeholder=\"gno.land/r/.../vault/v2\" />\n</gno-form>\n")
	return b.String()
}
