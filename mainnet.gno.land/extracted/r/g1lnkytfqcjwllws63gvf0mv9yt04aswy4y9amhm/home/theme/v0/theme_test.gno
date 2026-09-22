package theme

import (
	"encoding/base64"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home"
)

const self = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home/theme/v0"

// install stands in for the deploy-and-accept sequence: the harness does not
// deliver this realm's init as a transaction, so the registration is redone
// here, then accepted by the authority.
func install(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(self))
	home.Register(cross(cur), instance)
	testing.SetRealm(testing.NewUserRealm(home.Admin))
	home.Accept(cross(cur), self)
}

func set(cur realm, slug, body string) {
	testing.SetRealm(testing.NewUserRealm(home.Admin))
	home.Set(cross(cur), slug, body)
}

// decodeCard pulls the SVG back out of the first data: image in out.
func decodeCard(t *testing.T, out string) string {
	const marker = "data:image/svg+xml;base64,"
	i := strings.Index(out, marker)
	if i < 0 {
		t.Fatalf("no svg image in output:\n%s", out)
	}
	rest := out[i+len(marker):]
	end := strings.Index(rest, ")")
	raw, err := base64.StdEncoding.DecodeString(rest[:end])
	uassert.NoError(t, err)
	return string(raw)
}

func TestRenderProfilePage(cur realm, t *testing.T) {
	if home.LivePath() != self {
		install(cur)
	}
	set(cur, "name", "Clockwork")
	set(cur, "tagline", "Lead Frontend Engineer <at> AiB")
	set(cur, "handle", "@clockworkgr")
	set(cur, "now", "shipping")

	out := home.Render("")
	uassert.True(t, strings.HasPrefix(out, "![Clockwork](data:image/svg+xml;base64,"), out)
	uassert.True(t, strings.Contains(out, "## Now\n\nshipping\n"), out)
	uassert.True(t, strings.Contains(out, "<gno-columns>"), out)
	uassert.True(t, strings.Contains(out, ":intro:"), "an unset slot stays visible: "+out)
	uassert.True(t, strings.Contains(out, "theme `"+self+"`"), out)
	uassert.True(t, strings.Contains(out, "[edit](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home:edit)"), out)

	svg := decodeCard(t, out)
	uassert.True(t, strings.Contains(svg, ">Clockwork</text>"), svg)
	uassert.True(t, strings.Contains(svg, "Lead Frontend Engineer &lt;at&gt; AiB"), "text is escaped: "+svg)
	uassert.True(t, strings.Contains(svg, "@clockworkgr · rev "), svg)
	uassert.True(t, strings.Contains(svg, `fill="#D9A441"`), "default accent: "+svg)
}

func TestStyleKnobs(cur realm, t *testing.T) {
	if home.LivePath() != self {
		install(cur)
	}
	set(cur, "name", "Clockwork")
	set(cur, "layout", ":header:\n\n:divider:\n")

	set(cur, "style.accent", "#00AAFF")
	svg := decodeCard(t, home.Render(""))
	uassert.True(t, strings.Contains(svg, `fill="#00AAFF"`), svg)

	set(cur, "style.accent", "red; injected")
	svg = decodeCard(t, home.Render(""))
	uassert.True(t, strings.Contains(svg, `fill="#D9A441"`), "a malformed color falls back: "+svg)
	uassert.False(t, strings.Contains(svg, "injected"))

	set(cur, "style.header", "plain")
	out := home.Render("")
	uassert.True(t, strings.HasPrefix(out, "# Clockwork\n"), out)
	uassert.True(t, strings.Contains(out, "data:image/svg+xml"), "the divider is still an image")

	set(cur, "style.header", "none")
	out = home.Render("")
	uassert.True(t, strings.HasPrefix(out, "\n\n![](data:image/svg+xml"), out)
}

func TestOtherPathsDelegate(cur realm, t *testing.T) {
	if home.LivePath() != self {
		install(cur)
	}
	uassert.True(t, strings.Contains(home.Render("slots"), "# Slots"))
	uassert.True(t, strings.Contains(home.Render("system"), "["+self+"]"))
	uassert.True(t, strings.Contains(home.Render("edit"), "<gno-form exec=\"Set\">"))
}

func TestHexColor(t *testing.T) {
	uassert.True(t, isHexColor("#abcdef"))
	uassert.True(t, isHexColor("#ABCDEF"))
	uassert.False(t, isHexColor("abcdef"))
	uassert.False(t, isHexColor("#abc"))
	uassert.False(t, isHexColor("#abcdeg"))
	uassert.False(t, isHexColor("#abcdef\" onload=\"x"))
}
