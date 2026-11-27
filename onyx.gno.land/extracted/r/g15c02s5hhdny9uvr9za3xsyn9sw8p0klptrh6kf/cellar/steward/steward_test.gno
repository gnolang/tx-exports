package steward

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/livery"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

func TestOnlyHeadOfHouseAdmits(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "only the head of house", func() { Admit(cross(cur), ash) })
}

func TestAdmitDresses(cur realm, t *testing.T) {
	guest := address("g1rh0vd3xzwjpcqehrf0tpjlqeq35079wf4zklar")
	testing.SetRealm(testing.NewUserRealm(headOfHouse))
	Admit(cross(cur), guest)
	uassert.True(t, livery.InLivery(guest))
}

func TestToastIsSanitized(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	Toast(cross(cur), func() string { return "to the cellar\n# hijacked" })
	uassert.False(t, strings.Contains(Render(""), "\n# hijacked"))
	uassert.True(t, strings.Contains(Render(""), "to the cellar"))
}
