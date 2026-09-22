// Package home_test drives the realm from outside, the way transactions do:
// every write and every theme operation crosses into gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home,
// so the authority check sees whoever testing.SetRealm names as the caller.
package home_test

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home"
)

var stranger = testutils.TestAddress("mallory")

const (
	themeA = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home/theme/v0"
	themeB = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home/theme/v1"
)

// stubTheme wraps the page so a test can tell who answered.
type stubTheme struct{ tag string }

func (s stubTheme) Render(path string) string {
	if strings.HasPrefix(path, "custom") {
		return "custom by " + s.tag
	}
	if path != "" {
		return home.Fallback(path)
	}
	f := home.NewFiller()
	f.Add("widget", func() string { return "<" + s.tag + ">" })
	layout := home.Layout()
	if layout == "" {
		layout = "default of " + s.tag
	}
	return f.Fill(layout)
}

// brokenTheme panics on the profile page.
type brokenTheme struct{}

func (brokenTheme) Render(path string) string {
	if path == "" {
		panic("kaboom")
	}
	return home.Fallback(path)
}

// testing.SetRealm applies to the frame that calls it, so every test names
// its caller inline, right before the crossing call, rather than through a
// helper. A code realm stands in for a theme deployment: on chain the theme's
// init cross-calls Register, which the harness does not deliver as a
// transaction.
var (
	admin   = testing.NewUserRealm(home.Admin)
	mallory = testing.NewUserRealm(stranger)
)

// ---------------------------------------------------------------------------
// Slots

func TestSetGetDelete(cur realm, t *testing.T) {
	home.ResetForTest()
	testing.SetRealm(admin)

	home.Set(cross(cur), "intro", "Building on gno.")
	uassert.Equal(t, "Building on gno.", home.Get("intro"))
	uassert.Equal(t, 1, home.Revision())
	uassert.True(t, home.Has("intro"))

	home.Set(cross(cur), "intro", "Still building.")
	uassert.Equal(t, "Still building.", home.Get("intro"))
	uassert.Equal(t, 2, home.Revision())

	s, ok := home.Lookup("intro")
	uassert.True(t, ok)
	uassert.Equal(t, 2, s.Rev)

	home.Delete(cross(cur), "intro")
	uassert.Equal(t, "", home.Get("intro"))
	uassert.False(t, home.Has("intro"))
	uassert.Equal(t, 3, home.Revision())

	uassert.AbortsContains(t, cur, "no such slot: intro", func() {
		home.Delete(cross(cur), "intro")
	})
}

func TestAppendChunks(cur realm, t *testing.T) {
	home.ResetForTest()
	testing.SetRealm(admin)

	home.Set(cross(cur), "long", "part one. ")
	home.Append(cross(cur), "long", "part two.")
	uassert.Equal(t, "part one. part two.", home.Get("long"))

	home.Append(cross(cur), "fresh", "hello")
	uassert.Equal(t, "hello", home.Get("fresh"))
}

func TestWritesAreAuthorityOnly(cur realm, t *testing.T) {
	home.ResetForTest()
	testing.SetRealm(mallory)

	uassert.AbortsContains(t, cur, "restricted to the authority", func() {
		home.Set(cross(cur), "intro", "pwned")
	})
	uassert.AbortsContains(t, cur, "restricted to the authority", func() {
		home.Append(cross(cur), "intro", "pwned")
	})
	uassert.AbortsContains(t, cur, "restricted to the authority", func() {
		home.Delete(cross(cur), "intro")
	})
	uassert.Equal(t, 0, home.Revision())
}

func TestTransferAuthorityMovesEditing(cur realm, t *testing.T) {
	home.ResetForTest()
	testing.SetRealm(admin)
	home.TransferAuthority(cross(cur), stranger)

	uassert.AbortsContains(t, cur, "restricted to the authority", func() {
		home.Set(cross(cur), "intro", "old owner")
	})

	testing.SetRealm(mallory)
	home.Set(cross(cur), "intro", "new owner")
	uassert.Equal(t, "new owner", home.Get("intro"))
	uassert.True(t, strings.Contains(home.Authority(), stranger.String()))
}

func TestSlugRules(cur realm, t *testing.T) {
	home.ResetForTest()
	testing.SetRealm(admin)

	for _, bad := range []string{"", "Intro", "a:b", "with space", strings.Repeat("x", 65)} {
		uassert.AbortsContains(t, cur, "invalid slug", func() {
			home.Set(cross(cur), bad, "x")
		}, bad)
	}
	for _, reserved := range home.ReservedSlugsForTest() {
		uassert.AbortsContains(t, cur, "reserved slug", func() {
			home.Set(cross(cur), reserved, "x")
		}, reserved)
	}
	home.Set(cross(cur), "style.accent", "#D9A441")
	uassert.Equal(t, "#D9A441", home.Style("accent", "#000000"))
	uassert.Equal(t, 1, home.Revision())
}

// ---------------------------------------------------------------------------
// Themes

func TestThemeLifecycle(cur realm, t *testing.T) {
	home.ResetForTest()
	home.SeedForTest("layout", "page :widget: :rev:")

	testing.SetRealm(testing.NewCodeRealm(themeA))
	home.Register(cross(cur), stubTheme{"A"})
	testing.SetRealm(testing.NewCodeRealm(themeB))
	home.Register(cross(cur), stubTheme{"B"})
	uassert.Equal(t, "", home.LivePath())
	uassert.Equal(t, 2, len(home.PendingPaths()))
	uassert.Equal(t, "page :widget: 1", home.Render(""), "nothing serves before Accept")

	testing.SetRealm(admin)
	home.Accept(cross(cur), themeA)
	uassert.Equal(t, themeA, home.LivePath())
	uassert.Equal(t, "page <A> 1", home.Render(""))
	uassert.True(t, strings.Contains(home.Render("slots"), "# Slots"), "themes delegate other paths")
	uassert.True(t, strings.Contains(home.Render("system"), "["+themeA+"]"), home.Render("system"))
	uassert.True(t, strings.Contains(home.Render("system"), "value=\""+themeB+"\""), "pending themes get an Accept form")

	home.Accept(cross(cur), themeB)
	uassert.Equal(t, "page <B> 1", home.Render(""))
	uassert.Equal(t, 1, len(home.HistoryPaths()))
	uassert.Equal(t, themeA, home.HistoryPaths()[0])

	home.Rollback(cross(cur))
	uassert.Equal(t, "page <A> 1", home.Render(""))
	uassert.Equal(t, themeB, home.PendingPaths()[0], "the displaced theme returns to pending")

	// The slots were never in the theme, so switching never touched them.
	home.Set(cross(cur), "layout", ":widget: only")
	uassert.Equal(t, "<A> only", home.Render(""))
}

func TestBrokenThemeLeavesOperatorViews(cur realm, t *testing.T) {
	home.ResetForTest()
	home.SeedForTest("layout", "hello :rev:")
	testing.SetRealm(testing.NewCodeRealm(themeA))
	home.Register(cross(cur), stubTheme{"A"})
	testing.SetRealm(testing.NewCodeRealm(themeB))
	home.Register(cross(cur), brokenTheme{})
	testing.SetRealm(admin)
	home.Accept(cross(cur), themeA)
	uassert.Equal(t, "hello 1", home.Render(""))
	home.Accept(cross(cur), themeB)

	// The page is down: on chain this is a VM abort, not something this
	// realm can catch.
	uassert.AbortsContains(t, cur, "kaboom", func() { home.Render("") })

	// The views the rollback is done from never touch the theme.
	uassert.True(t, strings.Contains(home.Render("system"), "["+themeA+"]"))
	uassert.True(t, strings.Contains(home.Render("slots"), "# Slots"))
	uassert.True(t, strings.Contains(home.Render("edit"), "<gno-form exec=\"Set\">"))
	uassert.Equal(t, home.Manifest(), home.Render("manifest"))

	home.Rollback(cross(cur))
	uassert.Equal(t, themeA, home.LivePath())
	uassert.Equal(t, "hello 1", home.Render(""))
}

func TestThemeOwnsEveryOtherPath(cur realm, t *testing.T) {
	home.ResetForTest()
	testing.SetRealm(testing.NewCodeRealm(themeA))
	home.Register(cross(cur), stubTheme{"A"})
	testing.SetRealm(admin)
	home.Accept(cross(cur), themeA)

	uassert.Equal(t, "custom by A", home.Render("custom"), "a path the realm does not reserve reaches the theme")
	uassert.Equal(t, "custom by A", home.Render("custom?x=1"))
	uassert.True(t, strings.Contains(home.Render("slots?x=1"), "# Slots"), "reserved paths are matched without the query")
	uassert.True(t, strings.Contains(home.Render("slots/nope"), "# Not found"))
}

func TestRegisterRefusals(cur realm, t *testing.T) {
	home.ResetForTest()

	// A user cannot nominate a theme; only a deployed realm can.
	testing.SetRealm(admin)
	uassert.AbortsContains(t, cur, "only a deployed realm", func() {
		home.Register(cross(cur), stubTheme{"user"})
	})

	// A realm outside this path cannot either.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/mallory/theme"))
	uassert.AbortsContains(t, cur, "not nested", func() {
		home.Register(cross(cur), stubTheme{"foreign"})
	})
	uassert.Equal(t, 0, len(home.PendingPaths()))
}

func TestAcceptIsAuthorityOnly(cur realm, t *testing.T) {
	home.ResetForTest()
	testing.SetRealm(testing.NewCodeRealm(themeA))
	home.Register(cross(cur), stubTheme{"A"})

	testing.SetRealm(mallory)
	uassert.AbortsContains(t, cur, "not the authority", func() {
		home.Accept(cross(cur), themeA)
	})
	uassert.Equal(t, "", home.LivePath())
}

func TestFreezeKeepsEditing(cur realm, t *testing.T) {
	home.ResetForTest()
	testing.SetRealm(testing.NewCodeRealm(themeA))
	home.Register(cross(cur), stubTheme{"A"})
	testing.SetRealm(admin)
	home.Accept(cross(cur), themeA)
	home.Freeze(cross(cur))
	uassert.True(t, home.Frozen())

	uassert.AbortsContains(t, cur, "frozen", func() {
		home.Rollback(cross(cur))
	})
	home.Set(cross(cur), "layout", "still editable :widget:")
	uassert.Equal(t, "still editable <A>", home.Render(""))
	uassert.True(t, strings.Contains(home.Render("system"), "**frozen**"))
}
