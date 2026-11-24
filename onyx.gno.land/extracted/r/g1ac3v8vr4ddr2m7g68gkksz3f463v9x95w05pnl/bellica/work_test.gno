package bellica

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const cid = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"

func TestCategoriesScoringAndFilter(cur realm, t *testing.T) {
	host := testutils.TestAddress("wk-host")
	d := catBounty(cur, host, "Mascot illustration", "Design")
	c := catBounty(cur, host, "Faster tokenizer", "code")
	o := catBounty(cur, host, "Anything goes", "")
	uassert.Equal(t, "design", mustBounty(d).Category)
	uassert.Equal(t, "other", mustBounty(o).Category)
	uassert.Equal(t, "judge", scoringOf("design"))
	uassert.Equal(t, "metric", scoringOf("data"))
	testing.SetRealm(testing.NewUserRealm(host))
	testing.SetOriginSend(coins(1_000_000))
	uassert.AbortsWithMessage(t, cur, "unknown category: use one of code, design, image, video, audio, writing, data, research, other", func() {
		CreateBounty(cross(cur), "Bad category", "", "score", true, "100", 60, 60, "", "nft", 0)
	})
	testing.SetOriginSend(nil)
	js := Render("json/bounties/design")
	uassert.True(t, strings.Contains(js, `"id":`+itoa(d)+`,`), js)
	uassert.False(t, strings.Contains(js, `"id":`+itoa(c)+`,`), js)
	uassert.True(t, strings.Contains(js, `"scoring":"judge"`), js)
	uassert.Equal(t, js, Render("json/bounties?cat=design"))
	uassert.True(t, strings.Contains(Render("json/bounty/"+itoa(c)), `"scoring":"metric"`))
	home := Render("cat/design")
	uassert.True(t, strings.Contains(home, "Mascot illustration"), home)
	uassert.False(t, strings.Contains(home, "Faster tokenizer"), home)
	uassert.True(t, strings.Contains(Render("?cat=code"), "Faster tokenizer"))
	uassert.True(t, strings.Contains(Render("cat/nope"), "# 404"))
	uassert.True(t, strings.Contains(Render("bounty/"+itoa(d)), "judge-scored"))
	uassert.True(t, strings.Contains(Render("bounty/"+itoa(c)), "metric-scored"))
	uassert.True(t, strings.Contains(Render("json/categories"), `{"id":"video","scoring":"judge"}`))
}

func TestDeliverableValidation(cur realm, t *testing.T) {
	ok := func(kind, url, hash, text string) []string {
		k, u, h, x := mustDeliverable(kind, url, hash, text)
		return []string{k, u, h, x}
	}
	bad := func(msg, kind, url, hash, text string) {
		uassert.PanicsWithMessage(t, cur, msg, func() { mustDeliverable(kind, url, hash, text) })
	}
	r := ok("Image", "ipfs://"+cid+"/a.png", "SHA256:"+strings.Repeat("AB", 32), "")
	uassert.Equal(t, "image", r[0])
	uassert.Equal(t, strings.Repeat("ab", 32), r[2])
	ok("link", "https://drive.google.com/file/d/xyz/view", "", "")
	ok("text", "", "", "line one\nline two")
	bad("unknown deliverable kind: use one of link, image, video, file, text, repo", "zip", "https://example.com/a", "", "")
	bad("url must start with https:// or ipfs://", "link", "http://example.com/a", "", "")
	bad("url must start with https:// or ipfs://", "link", "javascript:alert1", "", "")
	bad("url contains characters that are not allowed in a URL", "link", "javascript:alert(1)", "", "")
	bad("url must start with https:// or ipfs://", "link", "data:text/html,xx", "", "")
	bad("url needs a valid https host", "link", "https://user@evil.com/x", "", "")
	bad("url needs a valid https host", "link", "https:///nohost", "", "")
	bad("url contains characters that are not allowed in a URL", "link", "https://e.com/a)b", "", "")
	bad("url contains characters that are not allowed in a URL", "link", "https://e.com/a\"onx", "", "")
	bad("url needs a valid ipfs CID", "image", "ipfs://short", "", "")
	bad("url needs a valid ipfs CID", "image", "ipfs://bafy-bad-cid-xx/a", "", "")
	bad("url must be 10-256 characters", "link", "https://e.com/"+strings.Repeat("a", 250), "", "")
	bad("sha256 must be 64 hex characters", "link", "https://e.com/a", "abc", "")
	bad("sha256 must be 64 hex characters", "link", "https://e.com/a", strings.Repeat("g", 64), "")
	bad("text must be 1-2000 characters", "text", "", "", strings.Repeat("word ", 401))
	bad("text must be 1-2000 characters", "text", "", "", "   ")
	bad("text must be at most 40 lines", "text", "", "", strings.Repeat("x\n", 41))
	bad("text is only for kind text; link the file instead", "image", "https://e.com/a.png", "", "hello")
	bad("url must be 10-256 characters", "file", "", "", "")
	// bidi / control characters are stripped before validation (F1)
	r = ok("text", "", "", "a\u202eb\u200bc")
	uassert.Equal(t, "abc", r[3])
}

func TestDeliverableRendering(cur realm, t *testing.T) {
	host, ag := testutils.TestAddress("wr-host"), testutils.TestAddress("wr-agent")
	register(cur, ag, "wr-agent")
	testing.IssueCoins(pkgAddr, coins(1_000_000))
	testing.SetRealm(testing.NewUserRealm(host))
	testing.SetOriginSend(coins(1_000_000))
	id := CreateBounty(cross(cur), "Short story", "", "judge score", true, "100", 60, 60, "", "writing", 0)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(ag))
	SubmitWork(cross(cur), id, "text", "", "", "# Title\n- not a list\n1. not ordered\n===\n[x](javascript:alert(1)) <img src=x>", "my story", 90)
	page := Render("bounty/" + itoa(id))
	uassert.True(t, strings.Contains(page, "> \\# Title"), page)
	uassert.True(t, strings.Contains(page, "> \\- not a list"), page)
	uassert.True(t, strings.Contains(page, "> 1\\. not ordered"), page)
	uassert.True(t, strings.Contains(page, "> \\=\\=\\=") || strings.Contains(page, "> \\==="), page)
	uassert.False(t, strings.Contains(page, "](javascript:"), page)
	uassert.False(t, strings.Contains(page, "<img src=x>"), page)
	js := Render("json/bounty/" + itoa(id))
	uassert.True(t, strings.Contains(js, `"kind":"text"`), js)
	uassert.True(t, strings.Contains(js, `"text":"# Title\n- not a list`), js)
	uassert.Equal(t, "[ipfs://bafybeigdyrzt5sfp7udm7h…](https://ipfs.io/ipfs/"+cid+")", workLink("ipfs://"+cid))
	// Submit (repo) now only takes https/ipfs too
	testing.SetRealm(testing.NewUserRealm(ag))
	uassert.AbortsWithMessage(t, cur, "repoURL must start with https:// or ipfs://", func() {
		Submit(cross(cur), id, "git://github.com/a/b", "abcd123", "", 1)
	})
}

func catBounty(cur realm, host address, title, cat string) int {
	testing.IssueCoins(pkgAddr, coins(1_000_000))
	testing.SetRealm(testing.NewUserRealm(host))
	testing.SetOriginSend(coins(1_000_000))
	id := CreateBounty(cross(cur), title, "", "score", true, "100", 60, 60, "", cat, 0)
	testing.SetOriginSend(nil)
	return id
}
