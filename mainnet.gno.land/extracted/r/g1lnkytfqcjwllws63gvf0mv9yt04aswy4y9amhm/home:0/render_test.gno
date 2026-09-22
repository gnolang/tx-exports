package home

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// Tests that need no crossing: pure helpers and the built-in views. The
// crossing behavior (writes, authority, theme lifecycle) is in home_test.gno,
// from outside the package, because a call into one's own realm never crosses.

func TestValidSlug(t *testing.T) {
	for _, ok := range []string{"a", "now", "style.accent", "a-b_c.d", strings.Repeat("x", 64)} {
		uassert.True(t, validSlug(ok), ok)
	}
	for _, bad := range []string{"", "Now", "a:b", "a b", "a/b", strings.Repeat("x", 65)} {
		uassert.False(t, validSlug(bad), bad)
	}
}

func TestFence(t *testing.T) {
	uassert.Equal(t, "```", fence("plain"))
	uassert.Equal(t, "```", fence("has `one` and ``two``"))
	uassert.Equal(t, "````", fence("```go\nx\n```"))
	uassert.Equal(t, "`````", fence("````"))
}

func TestAttr(t *testing.T) {
	uassert.Equal(t, "a &amp; b &quot;c&quot; &lt;d&gt;\\n\\te", attr("a & b \"c\" <d>\r\n\te"))
}

func TestFillerIsLazySinglePassAndOrderIndependent(t *testing.T) {
	ResetForTest()
	SeedForTest("a", "A says :b:")
	SeedForTest("b", "B")
	calls := 0
	f := NewFiller()
	f.Add("expensive", func() string { calls++; return "X" })

	uassert.Equal(t, "A says :b: B :nope:", f.Fill(":a: :b: :nope:"))
	uassert.Equal(t, 0, calls, "an absent placeholder never runs its callback")
	uassert.Equal(t, "X", f.Fill(":expensive:"))

	// A later Add for a slot's name wins: that is how a theme widget overrides.
	f.Add("a", func() string { return "widget" })
	uassert.Equal(t, "widget", f.Fill(":a:"))
}

func TestRenderWithoutLayoutOrTheme(t *testing.T) {
	ResetForTest()
	out := Render("")
	uassert.True(t, strings.Contains(out, "# gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home"), out)
	uassert.True(t, strings.Contains(out, "No theme is live"), out)
	uassert.True(t, strings.Contains(out, "_no slots yet_"), out)
	uassert.True(t, strings.Contains(out, "theme built-in"), out)
	uassert.False(t, strings.Contains(out, ":slots:"), "computed placeholders must resolve")
}

func TestRenderLayoutSubstitution(t *testing.T) {
	ResetForTest()
	SeedForTest("intro", "Hello :rev: world") // placeholders inside a body stay put
	SeedForTest("layout", "# Page\n\n:intro:\n\nrev :rev: · :missing: · :realm:\n")

	uassert.Equal(t, "# Page\n\nHello :rev: world\n\nrev 2 · :missing: · gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home\n", Render(""))
}

func TestRenderIndexAndSlot(t *testing.T) {
	ResetForTest()
	SeedForTest("now", "```go\nx := 1\n```")

	idx := Render("slots")
	uassert.True(t, strings.Contains(idx, "| [now](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home:slots/now) |"), idx)
	uassert.True(t, strings.Contains(idx, "[edit](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home:edit/now)"), idx)

	raw := Render("slots/now")
	uassert.True(t, strings.Contains(raw, "# now\n"), raw)
	uassert.True(t, strings.Contains(raw, "````\n```go\nx := 1\n```\n````\n"), "fence must outgrow the body: "+raw)

	uassert.True(t, strings.Contains(Render("slots/nope"), "# Not found"))
	uassert.True(t, strings.Contains(Render("nope"), "# Not found"))
	uassert.True(t, strings.Contains(Render("slots?x=1"), "# Slots"), "query strings are ignored")
	uassert.Equal(t, Manifest(), Render("manifest"))
}

func TestSlugsEachManifest(t *testing.T) {
	ResetForTest()
	SeedForTest("b", "two")
	SeedForTest("a", "one")

	uassert.Equal(t, 2, len(Slugs()))
	uassert.Equal(t, "a", Slugs()[0])

	visited := []string{}
	Each(func(slug string, s Slot) bool {
		visited = append(visited, slug+"="+s.Body)
		return false
	})
	uassert.Equal(t, "a=one b=two", strings.Join(visited, " "))

	lines := strings.Split(strings.TrimSpace(Manifest()), "\n")
	uassert.Equal(t, 2, len(lines))
	uassert.True(t, strings.HasPrefix(lines[0], "a\t2\t3\t"), lines[0])
	uassert.Equal(t, 4, len(strings.Split(lines[0], "\t")))

	s, ok := Lookup("a")
	uassert.True(t, ok)
	uassert.Equal(t, 2, s.Rev)
	_, ok = Lookup("zzz")
	uassert.False(t, ok)
	uassert.Equal(t, "#000", Style("missing", "#000"))
}

func TestRenderEdit(t *testing.T) {
	ResetForTest()
	SeedForTest("intro", "line \"one\"\n<two> & three\ttab")

	blank := Render("edit")
	uassert.True(t, strings.Contains(blank, "<gno-form exec=\"Set\">"), blank)
	uassert.True(t, strings.Contains(blank, "<gno-form exec=\"Delete\">"), blank)
	uassert.True(t, strings.Contains(blank, "[edit](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home:edit/intro)"), blank)

	one := Render("edit/intro")
	uassert.True(t, strings.Contains(one, "value=\"intro\""), one)
	uassert.True(t, strings.Contains(one,
		"value=\"line &quot;one&quot;\\n&lt;two&gt; &amp; three\\ttab\""), one)

	missing := Render("edit/later")
	uassert.True(t, strings.Contains(missing, "Saving creates it"), missing)
}

func TestRenderSystem(t *testing.T) {
	ResetForTest()
	out := Render("system")
	uassert.True(t, strings.Contains(out, "built-in fallback"), out)
	uassert.True(t, strings.Contains(out, Admin.String()), out)
	uassert.True(t, strings.Contains(out, "$help&func=Rollback"), out)
	uassert.True(t, strings.Contains(out, "| last write | never |"), out)
}
