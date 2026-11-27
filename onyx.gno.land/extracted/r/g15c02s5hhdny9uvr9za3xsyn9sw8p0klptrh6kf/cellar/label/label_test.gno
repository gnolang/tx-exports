package label

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const (
	ash   = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")
	briar = address("g19cyxvfmzdnxlf4ul6328wqq4hy3ssqmqcgul0k")
)

func TestChalkShowsInRegister(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	Chalk(cross(cur), "the 1811 smells of apricot")
	uassert.True(t, strings.Contains(Render(string(ash)), "the 1811 smells of apricot"))
	uassert.False(t, strings.Contains(Render(""), "apricot"), "the front page must not spoil guests' notes")
}

func TestChalkLimits(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "1 to 280", func() { Chalk(cross(cur), "") })
	uassert.AbortsContains(t, cur, "1 to 280", func() { Chalk(cross(cur), strings.Repeat("x", 281)) })
}

func TestOnlyMasterSeals(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "only the cellar master", func() { Seal(cross(cur), ash) })
}

func TestInspectWithoutForgeryFails(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(briar))
	Chalk(cross(cur), "Sealed by the cellar master: "+briar.String())
	uassert.AbortsContains(t, cur, "finds no seal for you", func() { Inspect(cross(cur)) })
	uassert.False(t, captures.Captured(briar))
}

func TestRealSealIsNotAForgery(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(master))
	Seal(cross(cur), briar)
	testing.SetRealm(testing.NewUserRealm(briar))
	uassert.AbortsContains(t, cur, "real seal", func() { Inspect(cross(cur)) })
}

func TestRenderRejectsBadPaths(t *testing.T) {
	uassert.True(t, strings.Contains(Render("`](javascript:x)"), "No such guest"))
}
