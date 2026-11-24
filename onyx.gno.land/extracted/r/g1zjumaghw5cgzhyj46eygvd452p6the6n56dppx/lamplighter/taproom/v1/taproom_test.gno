package taproom

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v1"
)

var (
	registryAddr = chain.PackageAddress(registryPath)
	patron       = testutils.TestAddress("patron")
	lighter      = testutils.TestAddress("lighter")
)

// The whole point of the project in one test: this realm registered a
// callback with another realm at init, and a stranger calling that other
// realm changes this realm's state and is paid for it.
func TestStrangerRotatesTheTap(cur realm, t *testing.T) {
	uassert.Equal(t, "Gnomish Amber", OnTap())
	uassert.Equal(t, int64(0), Rotations())

	// A patron funds three rotations.
	oil := chain.Coins{{registry.Denom, 3 * reward}}
	testing.IssueCoins(registryAddr, oil)
	testing.SetRealm(testing.NewUserRealm(patron))
	testing.SetOriginSend(oil)
	registry.Fund(cross(cur), JobID())
	testing.SetOriginSend(nil)

	// Too early.
	testing.SetRealm(testing.NewUserRealm(lighter))
	uassert.False(t, registry.IsDue(JobID()))
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() {
		registry.Exec(cross(cur), JobID())
	})

	// 61 blocks of 5s is 305s, past the 300s rotation.
	testing.SkipHeights(61)
	uassert.True(t, registry.IsDue(JobID()))

	before := banker.NewReadonlyBanker().GetCoin(lighter, registry.Denom)
	testing.SetRealm(testing.NewUserRealm(lighter))
	registry.Exec(cross(cur), JobID())

	uassert.Equal(t, "Deep Root Stout", OnTap())
	uassert.Equal(t, int64(1), Rotations())
	uassert.Equal(t, before+reward, banker.NewReadonlyBanker().GetCoin(lighter, registry.Denom))

	// Same slot again is refused; the next slot works.
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() {
		registry.Exec(cross(cur), JobID())
	})
	testing.SkipHeights(60)
	testing.SetRealm(testing.NewUserRealm(lighter))
	registry.Exec(cross(cur), JobID())
	uassert.Equal(t, "Mushroom Mead", OnTap())
	uassert.Equal(t, int64(2), Rotations())
}

// Nobody but the registry can reach the callback.
func TestRotateRefusesOtherCallers(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(lighter))
	err := rotate(cross(cur))
	uassert.True(t, err != nil)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/impostor"))
	err = rotate(cross(cur))
	uassert.True(t, err != nil)
}

func TestRender(t *testing.T) {
	out := Render("")
	uassert.True(t, strings.Contains(out, "# The Taproom"))
	uassert.True(t, strings.Contains(out, "## On tap: "+OnTap()))
	uassert.True(t, strings.Contains(out, "/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v1:job/"))
}
