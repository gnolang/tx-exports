package lending

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

var (
	boss  = address("g1lqns2s8wc0h4t5wx6g0j6gkzl46x6tzgx9gcyn")
	alice = address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
)

func TestIntegrateRefusals(cur realm, t *testing.T) {
	// gno test runs init with an empty caller: no owner, so Integrate is locked.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "owner only", func() { Integrate(cross(cur), "gno.land/r/demo/vault") })

	owner = boss
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "owner only", func() { Integrate(cross(cur), "gno.land/r/demo/vault") })
	testing.SetRealm(testing.NewUserRealm(boss))
	uassert.AbortsWithMessage(t, cur, "not a realm path: gno.land/p/nt/avl/v0", func() { Integrate(cross(cur), "gno.land/p/nt/avl/v0") })
	testing.SetRealm(testing.NewUserRealm(boss))
	uassert.AbortsWithMessage(t, cur, "not a realm path: gno.land/r/x/[a](b)", func() { Integrate(cross(cur), "gno.land/r/x/[a](b)") })
	// Not attested: Check fails, and the reason says so.
	testing.SetRealm(testing.NewUserRealm(boss))
	uassert.AbortsWithMessage(t, cur, "gno.land/r/demo/vault did not pass Bouncer's Standard policy: not attested by Bouncer yet", func() {
		Integrate(cross(cur), "gno.land/r/demo/vault")
	})
	uassert.Equal(t, 0, len(Accepted()))
}

func TestValidVault(t *testing.T) {
	for p, want := range map[string]bool{
		"gno.land/r/g1abc/vault/v2": true,
		"gno.land/r/demo/vault":     true,
		"gno.land/p/demo/avl":       false,
		"gno.land/r/":               false,
		"gno.land/r/a//b":           false,
		"gno.land/r/a/b/":           false,
		"gno.land/r/A/b":            false,
		"gno.land/r/a b":            false,
	} {
		uassert.Equal(t, want, validVault(p), p)
	}
}

func TestRenderEmpty(t *testing.T) {
	out := Render("")
	uassert.True(t, len(out) > 0)
	uassert.False(t, strings.Contains(out, "| Vault |"))
}
