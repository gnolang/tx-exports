package tokeninfo

import (
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	alice   = testutils.TestAddress("alice")   // holds the name "alice"
	bob     = testutils.TestAddress("bob")     // deploys under his own address
	carol   = testutils.TestAddress("carol")   // an editor
	mallory = testutils.TestAddress("mallory") // nobody
	mod     = testutils.TestAddress("mod")     // the moderator

	aliceTok = "gno.land/r/alice/tok.TOK"
	bobTok   = "gno.land/r/" + bob.String() + "/coin.BOB"
	missing  = "gno.land/r/alice/ghost.GHOST"
)

// reset stands in for grc20reg and r/sys/users and empties the registry.
func reset() {
	profiles, editors, hidden = avl.NewTree(), avl.NewTree(), avl.NewTree()
	admin = mod
	tokenExists = func(token string) bool { return token == aliceTok || token == bobTok }
	tokenName = func(token string) string { return "Test token" }
	resolveName = func(name string) (address, bool) {
		if name == "alice" {
			return alice, true
		}
		return "", false
	}
}

func setDesc(cur realm, token, desc string) {
	SetProfile(cross(cur), token, desc, "", "", "", "", "", "")
}

func TestNameOwnerWritesProfile(cur realm, t *testing.T) {
	reset()
	testing.SetHeight(42)
	testing.SetRealm(testing.NewUserRealm(alice))
	SetProfile(cross(cur), aliceTok, "A test token", "https://tok.example", "https://tok.example/logo.png",
		"@tok_x", "tok_chat", "https://discord.gg/abc", "alice/tok")

	p, ok := Get(aliceTok)
	urequire.True(t, ok)
	uassert.Equal(t, "A test token", p.Description)
	uassert.Equal(t, "https://tok.example", p.Website)
	uassert.Equal(t, "tok_x", p.X) // @ dropped
	uassert.Equal(t, "tok_chat", p.Telegram)
	uassert.Equal(t, "alice/tok", p.GitHub)
	uassert.Equal(t, alice.String(), p.UpdatedBy.String())
	uassert.Equal(t, int64(42), p.UpdatedAt)
	uassert.Equal(t, RoleOwner, p.Role)
	uassert.Equal(t, 1, Count())

	desc, site, _, _, _, _, _, by, _, role := Fields(aliceTok)
	uassert.Equal(t, "A test token", desc)
	uassert.Equal(t, "https://tok.example", site)
	uassert.Equal(t, alice.String(), by)
	uassert.Equal(t, RoleOwner, role)
}

func TestAddressNamespaceOwner(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(bob))
	setDesc(cur, bobTok, "Bob's coin")
	p, _ := Get(bobTok)
	uassert.Equal(t, RoleOwner, p.Role)
	uassert.True(t, CanEdit(bobTok, bob))
	uassert.False(t, CanEdit(bobTok, alice))
}

func TestStrangersCannotWrite(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsContains(t, cur, "does not own gno.land/r/alice/tok", func() { setDesc(cur, aliceTok, "scam") })
	// Owning one namespace says nothing about another.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "does not own", func() { setDesc(cur, aliceTok, "scam") })
	// A name that is not registered gives nobody rights.
	resolveName = func(string) (address, bool) { return "", false }
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "does not own", func() { setDesc(cur, aliceTok, "x") })
	uassert.Equal(t, 0, Count())
}

func TestTokenMustBeListed(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not listed in grc20reg", func() { setDesc(cur, missing, "x") })
	uassert.AbortsContains(t, cur, "is not a token path", func() { setDesc(cur, "gno.land/r/alice/tok", "x") })
	uassert.AbortsContains(t, cur, "is not a token path", func() { setDesc(cur, "gno.land/p/alice/tok.TOK", "x") })
}

func TestTokenRealmWritesItsOwnProfile(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/alice/tok"))
	setDesc(cur, aliceTok, "Written by the token realm")
	p, _ := Get(aliceTok)
	uassert.Equal(t, RoleRealm, p.Role)

	// Any other realm is refused, even one in the same namespace.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/alice/other"))
	uassert.AbortsContains(t, cur, "only gno.land/r/alice/tok can write", func() { setDesc(cur, aliceTok, "x") })
}

func TestEditors(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	AddEditor(cross(cur), aliceTok, carol)
	uassert.True(t, IsEditor(aliceTok, carol))
	uassert.Equal(t, 1, len(Editors(aliceTok)))

	testing.SetRealm(testing.NewUserRealm(carol))
	setDesc(cur, aliceTok, "by carol")
	p, _ := Get(aliceTok)
	uassert.Equal(t, RoleEditor, p.Role)
	uassert.AbortsContains(t, cur, "editors cannot add editors", func() { AddEditor(cross(cur), aliceTok, mallory) })
	uassert.AbortsContains(t, cur, "editors can only remove themselves", func() { RemoveEditor(cross(cur), aliceTok, alice) })
	RemoveEditor(cross(cur), aliceTok, carol)
	uassert.False(t, IsEditor(aliceTok, carol))
	uassert.AbortsContains(t, cur, "does not own", func() { setDesc(cur, aliceTok, "again") })

	// Editors of one token cannot touch another.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddEditor(cross(cur), aliceTok, carol)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "does not own", func() { setDesc(cur, bobTok, "x") })
}

func TestClearProfile(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	setDesc(cur, aliceTok, "soon gone")
	ClearProfile(cross(cur), aliceTok)
	_, ok := Get(aliceTok)
	uassert.False(t, ok)
	uassert.AbortsContains(t, cur, "has no profile", func() { ClearProfile(cross(cur), aliceTok) })
}

func TestValidation(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	set := func(desc, site, logo, x, tg, discord, gh string) func() {
		return func() { SetProfile(cross(cur), aliceTok, desc, site, logo, x, tg, discord, gh) }
	}
	uassert.AbortsContains(t, cur, "must be an https:// URL", set("", "http://tok.example", "", "", "", "", ""))
	uassert.AbortsContains(t, cur, "must be an https:// URL", set("", "javascript:alert(1)", "", "", "", "", ""))
	uassert.AbortsContains(t, cur, "must be an https:// URL", set("", "https:///evil", "", "", "", "", ""))
	uassert.AbortsContains(t, cur, "not allowed", set("", "", "https://x.example/a)b", "", "", "", ""))
	uassert.AbortsContains(t, cur, "not allowed", set("", "https://x.example/a b", "", "", "", "", ""))
	uassert.AbortsContains(t, cur, "not allowed", set("", "https://x.example/\"onload", "", "", "", "", ""))
	uassert.AbortsContains(t, cur, "longer than the limit", set("", "https://x.example/"+strings.Repeat("a", 200), "", "", "", "", ""))
	uassert.AbortsContains(t, cur, "invite link", set("", "", "", "", "", "https://evil.example/discord", ""))
	uassert.AbortsContains(t, cur, "wrong length", set("", "", "", "a_very_long_handle", "", "", ""))
	uassert.AbortsContains(t, cur, "not allowed", set("", "", "", "bad-handle", "", "", ""))
	uassert.AbortsContains(t, cur, "wrong length", set("", "", "", "", "abc", "", ""))
	uassert.AbortsContains(t, cur, "github", set("", "", "", "", "", "", "-alice"))
	uassert.AbortsContains(t, cur, "github repo", set("", "", "", "", "", "", "alice/.."))
	uassert.AbortsContains(t, cur, "github repo", set("", "", "", "", "", "", "alice/a/b"))
	uassert.AbortsContains(t, cur, "line break", set("two\nlines", "", "", "", "", "", ""))
	uassert.AbortsContains(t, cur, "longer than the limit", set(strings.Repeat("é", 281), "", "", "", "", "", ""))

	// The limits themselves are fine, and so is non-ASCII text.
	uassert.NotAborts(t, cur, set(strings.Repeat("é", 280), "", "", "fifteen_chars__", "", "https://discord.com/invite/x", "a-b/c.d_e"))
	uassert.Equal(t, 1, Count())
}

func TestModeration(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	setDesc(cur, aliceTok, "phishing")
	uassert.AbortsContains(t, cur, "admin only", func() { Hide(cross(cur), aliceTok, "spam") })

	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "a reason is required", func() { Hide(cross(cur), aliceTok, " ") })
	Hide(cross(cur), aliceTok, "phishing link")
	_, ok := Get(aliceTok)
	uassert.False(t, ok)
	desc, _, _, _, _, _, _, _, _, _ := Fields(aliceTok)
	uassert.Equal(t, "", desc)
	uassert.Equal(t, "phishing link", HiddenReason(aliceTok))
	uassert.True(t, strings.Contains(Render(aliceTok), "hidden by the moderator: phishing link"))

	// Hiding does not let the moderator write, and the owner keeps the profile.
	uassert.AbortsContains(t, cur, "does not own", func() { setDesc(cur, aliceTok, "x") })
	Unhide(cross(cur), aliceTok)
	p, ok := Get(aliceTok)
	uassert.True(t, ok)
	uassert.Equal(t, "phishing", p.Description)

	TransferAdmin(cross(cur), bob)
	uassert.Equal(t, bob.String(), Admin().String())
	uassert.AbortsContains(t, cur, "admin only", func() { Hide(cross(cur), aliceTok, "x") })
}

func TestRender(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	SetProfile(cross(cur), aliceTok, "Hi [click](javascript:alert(1)) <script>x</script> **bold**",
		"https://tok.example", "https://tok.example/logo.png", "tok", "", "", "alice/tok")

	home := Render("")
	uassert.True(t, strings.Contains(home, "# Token profiles"))
	uassert.True(t, strings.Contains(home, "**1** tokens have a profile"))
	uassert.True(t, strings.Contains(home, ":"+aliceTok+")"))

	page := Render(aliceTok)
	uassert.True(t, strings.Contains(page, "# TOK: Test token"))
	uassert.True(t, strings.Contains(page, "![TOK logo](https://tok.example/logo.png)"))
	uassert.True(t, strings.Contains(page, "[@tok](https://x.com/tok)"))
	uassert.True(t, strings.Contains(page, "(https://github.com/alice/tok)"))
	uassert.True(t, strings.Contains(page, "(namespace owner)"))
	// Markdown and HTML in the description stay text.
	uassert.False(t, strings.Contains(page, "](javascript:"))
	uassert.False(t, strings.Contains(page, "<script>"))
	uassert.False(t, strings.Contains(page, "**bold**"))

	uassert.True(t, strings.Contains(Render(bobTok), "No profile yet"))
	uassert.True(t, strings.Contains(Render("gno.land/r/alice/tok"), "Not a token path"))
	uassert.True(t, strings.Contains(Render("?page=2"), "No profiles on this page"))

	// Paths come from whoever opens the page: anything but a clean token path
	// gets the same fixed answer, and nothing echoes it into a link.
	for _, bad := range []string{
		"gno.land/r/x) [evil](https://evil.example/a.TOK",
		"gno.land/r/x/y.TOK](https://evil.example)",
		"abc.X", "gno.land/r/.TOK", "gno.land/r//a.TOK", "gno.land/r/A/b.TOK",
		"gno.land/r/a/b." + strings.Repeat("S", 33),
	} {
		out := Render(bad)
		uassert.True(t, strings.HasPrefix(out, "# Not a token path"), bad)
		uassert.False(t, strings.Contains(out, "evil"), bad)
	}
}

func TestTokenPathRules(cur realm, t *testing.T) {
	reset()
	tokenExists = func(string) bool { return true }
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "is not a token path", func() { setDesc(cur, "gno.land/r/alice/a b.TOK", "x") })
	uassert.AbortsContains(t, cur, "is not a token path", func() { setDesc(cur, "gno.land/r/alice/tok.T)K", "x") })
	uassert.AbortsContains(t, cur, "is not a token path", func() { setDesc(cur, "gno.land/r/Alice/tok.TOK", "x") })
	uassert.NotAborts(t, cur, func() { setDesc(cur, "gno.land/r/alice/deep/tok_v2.TOK-2", "x") })
	uassert.False(t, CanEdit("gno.land/r/alice", alice))
	uassert.True(t, CanEdit("gno.land/r/alice/any.X", alice))
}
