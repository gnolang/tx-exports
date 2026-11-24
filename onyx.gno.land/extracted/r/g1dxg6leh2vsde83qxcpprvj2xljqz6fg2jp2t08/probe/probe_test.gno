package probe

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestBump(cur realm, t *testing.T) {
	uassert.True(t, strings.Contains(Render(""), "Counter: 0"), "starts at zero")
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, 1, Bump(cross(cur)))
	uassert.Equal(t, 2, Bump(cross(cur)))
	uassert.True(t, strings.Contains(Render(""), "Counter: 2"), "render shows the count")
	uassert.True(t, strings.Contains(Render(""), alice.String()), "render shows the last caller")
}
