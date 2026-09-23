package home

import (
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	mallory = testutils.TestAddress("mallory")
)

func reset() {
	galleries = avl.NewTree()
	slots = avl.NewTree()
	rev = 0
	hearts = avl.NewTree()
	recent = nil
}

func seed(slug, body string) {
	rev++
	slots.Set(slug, &slot{body: body, rev: rev})
}

func TestDefaultPageRendersEverySection(t *testing.T) {
	// State as left by init: every default slot, no heart yet.
	page := Render("")
	for _, want := range []string{"data:image/svg+xml;base64,", "Founder, CEO & CTO", "## 今 Now", "## 組 Inside Memba", "BARRICADE", "256 merged pull requests", "Paris P2P Festival", "Contributing on Gno since | 2022", "## 源 Open source", "(https://www.youtube.com/watch?v=aG4M37FX4II)", "**0** hearts so far.", "gno.land/r/g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c/home"} {
		uassert.True(t, strings.Contains(page, want), "missing: "+want)
	}
	for _, s := range defaultSlots {
		uassert.False(t, strings.Contains(page, ":"+s.slug+":"), "unfilled placeholder :"+s.slug+":")
	}
	for _, g := range defaultGalleries {
		uassert.False(t, strings.Contains(page, ":gallery."+g.name+":"), "unfilled gallery :gallery."+g.name+":")
	}
	uassert.False(t, strings.Contains(page, ":hero:"))
}

func TestSetGetDelete(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(admin))

	Set(cross(cur), "bio", "Building on gno.")
	uassert.Equal(t, "Building on gno.", Get("bio"))
	Append(cross(cur), "bio", " Still.")
	uassert.Equal(t, "Building on gno. Still.", Get("bio"))
	uassert.Equal(t, 2, Revision())

	Delete(cross(cur), "bio")
	uassert.Equal(t, "", Get("bio"))
	uassert.AbortsWithMessage(t, cur, "no such slot: bio", func() {
		Delete(cross(cur), "bio")
	})
}

func TestWritesAreAdminOnly(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "restricted to admin", func() { Set(cross(cur), "bio", "pwned") })
	uassert.AbortsWithMessage(t, cur, "restricted to admin", func() { Append(cross(cur), "bio", "pwned") })
	uassert.AbortsWithMessage(t, cur, "restricted to admin", func() { Delete(cross(cur), "bio") })
}

func TestSlugRules(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(admin))
	uassert.AbortsContains(t, cur, "invalid slug", func() { Set(cross(cur), "Bad", "x") })
	uassert.AbortsContains(t, cur, "invalid slug", func() { Set(cross(cur), "a:b", "x") })
	uassert.AbortsContains(t, cur, "invalid slug", func() { Set(cross(cur), "", "x") })
	uassert.AbortsWithMessage(t, cur, "reserved slug: hearts", func() { Set(cross(cur), "hearts", "fake 9999") })
	uassert.AbortsContains(t, cur, "reserved slug: gallery.", func() { Set(cross(cur), "gallery.x", "fake") })
}

func TestFillIsSinglePass(t *testing.T) {
	reset()
	seed("layout", "A :a: B :missing: C 10:30 :b:")
	seed("a", "[:b:]")
	seed("b", "bee")
	uassert.Equal(t, "A [:b:] B :missing: C 10:30 bee", Render(""))
}

func TestFallbackLayout(t *testing.T) {
	reset()
	seed("bio", "hi")
	uassert.True(t, strings.HasPrefix(Render(""), "# zôÖma\n\nhi\n\n**0** hearts"))
}

func TestHeartOncePerAddress(cur realm, t *testing.T) {
	reset()
	seed("layout", ":hearts:")

	testing.SetRealm(testing.NewUserRealm(alice))
	Heart(cross(cur))
	uassert.Equal(t, 1, Hearts())
	uassert.True(t, HasHeart(alice))
	uassert.AbortsWithMessage(t, cur, "already sent: one <3 per address", func() { Heart(cross(cur)) })

	testing.SetRealm(testing.NewUserRealm(bob))
	Heart(cross(cur))
	uassert.Equal(t, 2, Hearts())
	uassert.Equal(t, bob, recent[0], "newest first")

	page := Render("")
	uassert.True(t, strings.Contains(page, "**2** hearts so far."))
	uassert.True(t, strings.Contains(page, "/u/"+bob.String()))
	uassert.True(t, strings.Contains(Render("hearts"), "/u/"+alice.String()))
}

func TestRecentIsBounded(cur realm, t *testing.T) {
	reset()
	for i := 0; i < maxRecent+3; i++ {
		testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("fan" + string(rune('a'+i)))))
		Heart(cross(cur))
	}
	uassert.Equal(t, maxRecent+3, Hearts())
	uassert.Equal(t, maxRecent, len(recent))
}

func TestOtherViews(t *testing.T) {
	reset()
	seed("bio", "hello")
	uassert.True(t, strings.Contains(Render("slots"), "[bio]"))
	uassert.True(t, strings.Contains(Render("slots/bio"), "hello"))
	uassert.True(t, strings.Contains(Render("slots/nope"), "Not found"))
	uassert.True(t, strings.Contains(Render("nope"), "Not found"))
}

func TestGallery(cur realm, t *testing.T) {
	reset()
	seed("layout", ":gallery.demo:")

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "restricted to admin", func() {
		SetGallery(cross(cur), "demo", "film | A | b | https://x.y")
	})

	testing.SetRealm(testing.NewUserRealm(admin))
	uassert.AbortsContains(t, cur, "needs 4 or 5 fields", func() { SetGallery(cross(cur), "demo", "film | A | b") })
	uassert.AbortsContains(t, cur, "must be https://", func() { SetGallery(cross(cur), "demo", "film | A | b | javascript:alert(1)") })
	uassert.AbortsContains(t, cur, "markdown would break", func() { SetGallery(cross(cur), "demo", "film | A | b | https://x.y/a)b") })

	SetGallery(cross(cur), "demo", "# comment\nfilm | One <&> | meta | https://a.b/1\nproduct | Two | m | /r/x\nevent | Three | m | https://a.b/3\nreport | Four | m | https://a.b/4")
	page := Render("")
	uassert.Equal(t, 2, strings.Count(page, "<gno-columns>"), "3 per row")
	uassert.Equal(t, 4, strings.Count(page, "data:image/svg+xml;base64,"))
	uassert.True(t, strings.Contains(page, "](https://a.b/1)"))
	uassert.True(t, strings.Contains(page, "](/r/x)"))

	// Titles are XML-escaped inside the poster.
	svg := poster(card{kind: "film", title: "One <&>", meta: "m", url: "https://a.b"})
	uassert.True(t, strings.Contains(svg, "One &lt;&amp;&gt;"))

	// An optional fifth field becomes the link's hover text.
	SetGallery(cross(cur), "demo", "memba | DAO Management | m | https://a.b/dao | Vote, execute, create.")
	uassert.True(t, strings.Contains(Render(""), `](https://a.b/dao "Vote, execute, create.")`))
	uassert.Equal(t, "MEMBA · PRODUCT", styleOf("memba").label, "every seeded kind has its own style")
	uassert.AbortsContains(t, cur, "without quotes", func() {
		SetGallery(cross(cur), "demo", "memba | A | m | https://a.b | say \"hi\"")
	})

	DeleteGallery(cross(cur), "demo")
	uassert.Equal(t, ":gallery.demo:", Render(""), "a missing gallery stays visible")
}

func TestWrap(t *testing.T) {
	uassert.Equal(t, 1, len(wrap("Short title", 24)))
	lines := wrap("The Underground Sistine Chapel is a very long title indeed", 24)
	uassert.Equal(t, 2, len(lines))
	uassert.True(t, strings.HasSuffix(lines[1], "…"))
}
