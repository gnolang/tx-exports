package home

import (
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice   = testutils.TestAddress("alice")
	mallory = testutils.TestAddress("mallory")
)

// setDay moves the block time to noon on the given day since 1970-01-01 UTC.
func setDay(day int64) {
	ctx := testing.GetContext()
	ctx.Time = time.Unix(day*86400+43200, 0)
	testing.SetContext(ctx)
}

func TestDefaultPage(t *testing.T) {
	setDay(launchDay)
	page := Render("")
	for _, want := range []string{
		"![David G., developer engineer at Samouraï Coop](data:image/svg+xml;base64,", "I'm a developer engineer at [Samouraï Coop](https://www.samourai.world/), in [samcrew](/u/samcrew)", "## Gno core", "## Projects", "## Peer Dev",
		"## Gnordle", "[Play puzzle #1](" + home + ":wordle)", "[GnoVM, explained](",
		"## Hearts", "**0** so far.", "$help&func=Heart",
	} {
		uassert.True(t, strings.Contains(page, want), "missing: "+want)
	}
}

func TestSetGetDelete(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	Set(cross(cur), "bio", "Building on gno.")
	uassert.Equal(t, "Building on gno.", Get("bio"))
	Set(cross(cur), "order", "bio")
	uassert.True(t, strings.HasPrefix(Render(""), "Building on gno."))

	Delete(cross(cur), "bio")
	uassert.Equal(t, "", Get("bio"))
	uassert.AbortsWithMessage(t, cur, "no such section: bio", func() { Delete(cross(cur), "bio") })
	uassert.AbortsWithMessage(t, cur, "reserved section: game", func() { Set(cross(cur), "game", "x") })
	uassert.AbortsWithMessage(t, cur, "invalid section name", func() { Set(cross(cur), "a,b", "x") })

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "unauthorized", func() { Set(cross(cur), "header", "pwned") })
	uassert.AbortsWithMessage(t, cur, "unauthorized", func() { Delete(cross(cur), "header") })

	for _, s := range defaultSlots {
		slots.Set(s.name, s.body)
	}
}

func TestHeart(cur realm, t *testing.T) {
	hearts = avl.NewTree()
	testing.SetRealm(testing.NewUserRealm(alice))
	Heart(cross(cur))
	uassert.Equal(t, 1, Hearts())
	uassert.True(t, HasHeart(alice))
	uassert.False(t, HasHeart(mallory))
	uassert.AbortsWithMessage(t, cur, "already sent: one heart per address", func() { Heart(cross(cur)) })
	uassert.True(t, strings.Contains(Render("hearts"), alice.String()))
	uassert.True(t, strings.Contains(Render(""), "**1** so far."))
}

func TestNotFound(t *testing.T) {
	uassert.True(t, strings.HasPrefix(Render("nope"), "# Not found"))
}
