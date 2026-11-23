package questmaster

import (
	"chain/runtime"
	"strings"
	"testing"

	"gno.land/p/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/escrow"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const base = "/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"

func has(t *testing.T, page, want, what string) {
	t.Helper()
	if !strings.Contains(page, want) {
		t.Fatalf("%s: page does not contain %q\n--- page ---\n%s", what, want, page)
	}
}

func hasNot(t *testing.T, page, bad, what string) {
	t.Helper()
	if strings.Contains(page, bad) {
		t.Fatalf("%s: page must not contain %q\n--- page ---\n%s", what, bad, page)
	}
}

// renders calls Render and fails the test (instead of crashing) on a panic.
func renders(t *testing.T, path string) string {
	t.Helper()
	var out string
	if r := revive(func() { out = Render(path) }); r != nil {
		t.Fatalf("Render(%q) panicked: %v", path, r)
	}
	return out
}

var allPaths = []string{
	"", "?page=2", "help", "paid", "paid?page=2",
	"quest/1", "quest/2", "quest/3", "quest/4", "quest/5", "quest/6",
	"poster/" + alice.String(), "builder/" + bob.String(), "poster/" + bob.String() + "?page=2",
}

func TestRenderEmptyBoard(cur realm, t *testing.T) {
	resetState()
	for _, p := range allPaths {
		renders(t, p)
	}
	home := renders(t, "")
	has(t, home, "# QuestMaster", "home title")
	has(t, home, "| 0 | 0 | 0 | 0 |", "empty totals")
	has(t, home, "No open quests right now.", "empty list")
	has(t, home, "[Post the first one]("+base+"$help&func=PostQuest&.send=1000000ugnot)", "post link with send")
	has(t, renders(t, "paid"), "No quest has been paid yet.", "empty paid")
	has(t, renders(t, "poster/"+alice.String()), "No quests yet.", "empty poster")
	has(t, renders(t, "quest/1"), "# Not found", "no quest 1 yet")
}

// board builds a board with quests in every state and more than one page of
// open quests. Known numbers:
//
//	1 Paid (approved, 2 GNOT)       2 Paid (timeout, 3 GNOT)
//	3 Cancelled (1.5 GNOT)          4 Claimed by bob
//	5 Submitted by bob              6 Open after one reject
//	7..31 Open (25 quests, 1 GNOT each)
func board(cur realm) {
	resetState()
	a := submitted(cur, 2*gnot)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	ApproveWork(cross(cur), a)

	b := submitted(cur, 3*gnot)
	testing.SkipHeights(escrow.ReviewBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimPayout(cross(cur), b)

	c := post(cur, alice, 1_500_000, "Cancelled quest")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), c)

	claimed(cur, 4*gnot)
	submitted(cur, 5*gnot)

	f := submitted(cur, 6*gnot)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	RejectWork(cross(cur), f, "Please add tests")

	for i := 0; i < 25; i++ {
		post(cur, carol, gnot, "Small task")
	}
}

func TestRenderFullBoard(cur realm, t *testing.T) {
	board(cur)
	for _, p := range allPaths {
		renders(t, p)
	}
	home := renders(t, "")
	// open: 6 + 25 = 26; locked: 4+5+6+25 = 40; paid 2+3 = 5; 2 quests paid
	has(t, home, "| 26 | 40 | 5 | 2 |", "totals")
	uassert.Equal(t, PageSize, strings.Count(home, "](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster:quest/"), "first page holds PageSize quests")
	has(t, home, "| 31 | [Small task]("+base+":quest/31) | 1 GNOT | 2,000 (about 117 minutes) | 0 |", "newest first")
	has(t, home, "Page 1 of 2 · [Older →]("+base+"?page=2)", "next link")
	hasNot(t, home, "Newer", "no prev link on page 1")

	p2 := renders(t, "?page=2")
	uassert.Equal(t, 6, strings.Count(p2, "](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster:quest/"), "second page")
	has(t, p2, "| 6 | [claimed quest]("+base+":quest/6) | 6 GNOT | 2,000 (about 117 minutes) | 1 |", "rejected quest shows count")
	has(t, p2, "Page 2 of 2 · [← Newer]("+base+"?page=1)", "prev link")
	has(t, renders(t, "?page=3"), "This page is empty.", "past the end")

	paid := renders(t, "paid")
	has(t, paid, "2 quests, 5 GNOT in total", "paid summary")
	has(t, paid, "| 2 | [claimed quest]("+base+":quest/2) | 3 GNOT | "+userLink(bob, false)+" | 0 |", "paid row")

	poster := renders(t, "poster/"+alice.String())
	has(t, poster, "| 3 | [Cancelled quest]("+base+":quest/3) | 1.5 GNOT | Cancelled (refunded) | - |", "cancelled row")
	has(t, poster, "| 4 | [claimed quest]("+base+":quest/4) | 4 GNOT | Claimed (work in progress) |", "claimed row")
	builder := renders(t, "builder/"+bob.String())
	// builder history keeps quest 6 although bob was rejected
	has(t, builder, "| 6 | [claimed quest]("+base+":quest/6) | 6 GNOT | Open |", "history row")
	has(t, builder, "| 1 | [claimed quest]("+base+":quest/1) | 2 GNOT | Paid |", "paid in history")
	has(t, renders(t, "poster/"+carol.String()+"?page=2"), "Page 2 of 2", "poster page 2")
}

func TestRenderQuestStates(cur realm, t *testing.T) {
	board(cur)
	open := renders(t, "quest/7")
	has(t, open, "| State | **Open** |", "open state")
	has(t, open, "**Claim**", "claim step")
	has(t, open, "[Open in gnoweb]("+base+"$help&func=ClaimQuest&id=7)", "claim link")
	has(t, open, "[Open in gnoweb]("+base+"$help&func=CancelQuest&id=7)", "cancel link")
	has(t, open, `-pkgpath "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster" -func "ClaimQuest" -args "7"`, "gnokey claim")
	has(t, open, "-chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 KEY", "onyx pinned")
	hasNot(t, open, "ApproveWork", "no approve when open")

	claimedPage := renders(t, "quest/4")
	has(t, claimedPage, "| State | **Claimed (work in progress)** |", "claimed state")
	has(t, claimedPage, "func=SubmitWork&id=4", "submit link")
	has(t, claimedPage, "func=UnclaimQuest&id=4", "unclaim link")
	hasNot(t, claimedPage, "func=ReleaseQuest", "no release before deadline")
	has(t, claimedPage, "anyone can release the quest from block", "release explained")
	has(t, claimedPage, "| Work deadline | block ", "work deadline row")
	has(t, claimedPage, " left) |", "time left")

	sub := renders(t, "quest/5")
	has(t, sub, "| State | **Submitted (waiting for review)** |", "submitted")
	has(t, sub, "func=ApproveWork&id=5", "approve link")
	has(t, sub, "func=RejectWork&id=5", "reject link")
	has(t, sub, "| Work | [https://github\\.com/example/repo/pull/1](https://github.com/example/repo/pull/1) |", "work link")
	hasNot(t, sub, "func=ClaimPayout", "no payout before deadline")

	rejected := renders(t, "quest/6")
	has(t, rejected, "## Last reject reason", "reason heading")
	has(t, rejected, "> Please add tests  ", "reason text")
	has(t, rejected, "| Times rejected | 1 |", "reject count")

	has(t, renders(t, "quest/1"), "Nothing: this quest is finished and the builder was paid 2 GNOT.", "paid quest")
	has(t, renders(t, "quest/3"), "Nothing: this quest was cancelled and the reward went back to the poster", "cancelled quest")

	// after the deadlines the late moves appear and the early ones go
	testing.SkipHeights(escrow.ReviewBlocks + 1)
	late := renders(t, "quest/5")
	has(t, late, "func=ClaimPayout&id=5", "payout link after deadline")
	hasNot(t, late, "func=RejectWork", "no reject after deadline")
	has(t, late, "(passed) |", "deadline passed")
	lateClaim := renders(t, "quest/4")
	has(t, lateClaim, "func=ReleaseQuest&id=4", "release link after deadline")
	hasNot(t, lateClaim, "func=SubmitWork", "no submit after deadline")
}

// User text must never become Markdown structure. These asserts pin the exact
// escaped output for every dangerous character.
func TestRenderInjection(cur realm, t *testing.T) {
	resetState()
	title := "# A | `c` [x](y) ![i](z) <script> * _ ) @alice"
	details := "Line one\n# not a heading\n- not a list\n| a | b |\n|---|---|\n<script>alert(1)</script>\n![img](https://e.vil/i.png) [link](https://e.vil)\nsee g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 and @bob\n===\n\n\n    indented"
	id := postD(cur, alice, gnot, title, details)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimQuest(cross(cur), id)
	SubmitWork(cross(cur), id, "https://e.vil/a_(b)<c>`d`|e")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	RejectWork(cross(cur), id, "Bad\n## heading\n[x](https://e.vil) <b>")

	// second quest keeps the hostile link visible
	id2 := postD(cur, alice, gnot, "Link test", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimQuest(cross(cur), id2)
	SubmitWork(cross(cur), id2, "https://e.vil/a_(b)<c>`d`|e")

	escTitle := "\\# A | \\`c\\` \\[x\\]\\(y\\) \\!\\[i\\]\\(z\\) \\<script\\> \\* \\_ \\) \\@alice"
	escCellTitle := strings.ReplaceAll(escTitle, "|", "\\|")

	q := renders(t, "quest/1")
	has(t, q, "# Quest 1: "+escTitle+"\n", "title in heading")
	has(t, q, "> Line one  \n> \\# not a heading  \n> \\- not a list  \n> \\| a \\| b \\|  \n> \\|\\-\\-\\-\\|\\-\\-\\-\\|  \n"+
		"> \\<script\\>alert\\(1\\)\\</script\\>  \n> \\!\\[img\\]\\(https://e\\.vil/i\\.png\\) \\[link\\]\\(https://e\\.vil\\)  \n"+
		"> see&#32;g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 and \\@bob  \n> \\===  \n>\n> indented  \n", "details block")
	has(t, q, "> Bad  \n> \\#\\# heading  \n> \\[x\\]\\(https://e\\.vil\\) \\<b\\>  \n", "reason block")

	home := renders(t, "")
	has(t, renders(t, "poster/"+alice.String()), "| 2 | [Link test]("+base+":quest/2) |", "plain title")
	has(t, home, "| 1 | ["+escCellTitle+"]("+base+":quest/1) |", "title in table cell")

	q2 := renders(t, "quest/2")
	// ( ) < > ` | are percent-encoded in the target; the visible text is the
	// escaped URL itself
	has(t, q2, "| Work | [https://e\\.vil/a\\_\\(b\\)\\<c\\>\\`d\\`\\|e](https://e.vil/a_%28b%29%3Cc%3E%60d%60%7Ce) |", "hostile link made safe")
	hasNot(t, q2, "](https://e.vil/a_(", "no raw parenthesis in a link target")
	has(t, q2, "_No details given._", "empty details")

	for _, page := range []string{q, q2, home} {
		hasNot(t, page, "<script>", "raw script tag")
		hasNot(t, page, "![", "unescaped image")
		hasNot(t, page, "\n#  ", "stray heading")
		hasNot(t, page, " @alice", "raw mention")
		hasNot(t, page, " g1jg8m", "raw address mention")
	}
}

func TestRenderBadPaths(cur realm, t *testing.T) {
	board(cur)
	bad := []string{
		"nope", "quest", "quest/", "quest/abc", "quest/0", "quest/999", "quest/-1", "quest/1/2", "quest/+1",
		"quest/99999999999999999999999", "quest/1e3", "poster/", "poster/notanaddress",
		"poster/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf6", "builder/<script>", "builder/" + strings.Repeat("g", 500),
		"paid/x", "HELP", "../quest/1", "quest/1#x", "%00", "quest/1\n# injected",
	}
	for _, p := range bad {
		out := renders(t, p)
		has(t, out, "# Not found", "bad path "+p)
		has(t, out, "[Go to the QuestMaster board]("+base+")", "home link "+p)
		hasNot(t, out, "script", "path not echoed "+p)
		hasNot(t, out, "injected", "path not echoed "+p)
	}
	// bad page numbers fall back to page 1 or an empty page, never a panic
	for _, p := range []string{"?page=-5", "?page=0", "?page=abc", "?page=", "?page=1.5", "?%zz", "?page=99999999999999999999"} {
		has(t, renders(t, p), "Page 1 of 2", "page fallback "+p)
	}
	for _, p := range []string{"?page=1000000", "?page=999999999", "paid?page=999", "poster/" + carol.String() + "?page=50"} {
		has(t, renders(t, p), "This page is empty.", "huge page "+p)
	}
	// a valid address with no quests
	has(t, renders(t, "builder/"+testutils.TestAddress("nobody").String()), "No quests yet.", "unknown user")
	// query on a quest page is ignored
	has(t, renders(t, "quest/1?page=2"), "# Quest 1:", "quest with query")
}

func TestRenderHelp(cur realm, t *testing.T) {
	resetState()
	h := renders(t, "help")
	has(t, h, "**Onyx test network** (`onyx-1`)", "testnet note")
	has(t, h, "test GNOT", "test GNOT")
	for _, fn := range []string{"PostQuest", "ClaimQuest", "SubmitWork", "ApproveWork", "RejectWork", "CancelQuest", "UnclaimQuest", "ReleaseQuest", "ClaimPayout"} {
		has(t, h, `-func "`+fn+`"`, "command for "+fn)
	}
	has(t, h, `-func "PostQuest" -args "Fix a typo in the docs" -args "Details of the task" -args "20000" -send "5000000ugnot"`, "post with send")
	hasNot(t, h, "gnoland-1", "no mainnet")
	hasNot(t, h, "rpc.gno.land", "no mainnet rpc")
	hasNot(t, h, "rpc.latest", "no moving alias")
	uassert.Equal(t, 9, strings.Count(h, "-chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 KEY"), "every command pinned to Onyx")
}

func TestFormatHelpers(t *testing.T) {
	cases := map[int64]string{0: "0", 1: "0.000001", 10: "0.00001", 1_000_000: "1", 1_500_000: "1.5", 123_456_789: "123.456789", 5_250_000: "5.25", -2_500_000: "-2.5"}
	for in, want := range cases {
		uassert.Equal(t, want, gnotStr(in))
	}
	uassert.Equal(t, "0", blocksStr(0))
	uassert.Equal(t, "999", blocksStr(999))
	uassert.Equal(t, "1,000", blocksStr(1000))
	uassert.Equal(t, "2,200,000", blocksStr(2_200_000))
	uassert.Equal(t, "now", approx(0))
	uassert.Equal(t, "about a minute", approx(10))
	uassert.Equal(t, "about 58 minutes", approx(1_000))
	uassert.Equal(t, "about 3 days", approx(75_000))
	uassert.Equal(t, "about 7 days", approx(escrow.ReviewBlocks))
	uassert.Equal(t, "about 89 days", approx(2_200_000))
	uassert.Equal(t, "passed", left(10, 11))
	uassert.Equal(t, "about a minute left", left(10, 10))
}

func TestRenderClosing(cur realm, t *testing.T) {
	resetState()
	cl := claimed(cur, 2*gnot)
	sub := submitted(cur, 3*gnot)
	// before closing: the poster sees "Close quest" on claimed and submitted quests
	has(t, renders(t, "quest/1"), "**Close quest**", "close offered on claimed")
	has(t, renders(t, "quest/2"), "**Close quest**", "close offered on submitted")
	has(t, renders(t, "quest/1"), "func=CancelQuest&id=1", "close link")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), cl)
	CancelQuest(cross(cur), sub)

	c := renders(t, "quest/1")
	has(t, c, "| State | **Claimed (work in progress), closing** |", "closing state")
	has(t, c, "> **Closing**: the reward returns to the poster when the current builder's turn ends, unless the work is approved.", "closing note")
	has(t, c, "It is closing, so it ends and the reward goes back to the poster.", "unclaim text while closing")
	has(t, c, "anyone can end the quest from block", "release text while closing")
	hasNot(t, c, "**Close quest**", "no second close")
	s := renders(t, "quest/2")
	has(t, s, "The quest is closing, so it ends and the reward goes back to the poster.", "reject text while closing")
	hasNot(t, s, "**Close quest**", "no second close")
	has(t, renders(t, "poster/"+alice.String()), "Claimed (work in progress), closing", "closing mark in table")
	has(t, renders(t, ""), "No open quests right now.", "closing quests are not open")

	testing.SkipHeights(GetQuest(cl).WorkDeadline - runtime.ChainHeight() + 1)
	has(t, renders(t, "quest/1"), "so anyone can end the quest; the reward goes back to the poster.", "release while closing")
}

func TestRenderReviewWarningAndFooter(cur realm, t *testing.T) {
	board(cur)
	warn := "**Posters: check your quest.** If you do not approve or reject a submission within the review window (about 7 days), the builder is paid automatically."
	has(t, renders(t, ""), warn, "warning on home")
	has(t, renders(t, "help"), warn, "warning on help")
	has(t, renders(t, "help"), "Anyone except you can claim your quest while it is open; once it is claimed, closing it (below) stops new claims.", "claim note on help")
	foot := "\n---\n\nBuilt on [gno.land](https://gno.land) · [source](https://github.com/elangrr/questmaster)\n"
	for _, p := range append(allPaths, "nope", "quest/999") {
		out := renders(t, p)
		if !strings.HasSuffix(out, foot) {
			t.Fatalf("page %q does not end with the footer", p)
		}
	}
}

// Math ($...$) and mention links at the start of user text are neutralised.
func TestRenderMathAndLeadingAddress(cur realm, t *testing.T) {
	resetState()
	addr := "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
	id := postD(cur, alice, gnot, addr+" pays $x$", "$$y$$ and $z$\n"+addr+" line two")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimQuest(cross(cur), id)
	SubmitWork(cross(cur), id, "https://e.vil/$x$")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	RejectWork(cross(cur), id, addr+" no $$m$$")

	id2 := postD(cur, alice, gnot, "Link with dollars", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimQuest(cross(cur), id2)
	SubmitWork(cross(cur), id2, "https://e.vil/$x$")

	q := renders(t, "quest/1")
	has(t, q, "# Quest 1: &#103;1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 pays \\$x\\$\n", "title in heading")
	has(t, q, "> \\$\\$y\\$\\$ and \\$z\\$  \n> &#103;1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 line two  \n", "details lines")
	has(t, q, "> &#103;1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 no \\$\\$m\\$\\$  \n", "reason line")
	has(t, renders(t, "poster/"+alice.String()), "| 1 | [&#103;1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 pays \\$x\\$]("+base+":quest/1) |", "title in a table cell")
	has(t, renders(t, "quest/2"), "| Work | [https://e\\.vil/\\$x\\$](https://e.vil/$x$) |", "dollar in the link text")
	for _, p := range []string{q, renders(t, "quest/2")} {
		hasNot(t, p, " "+addr, "raw address after a space")
		hasNot(t, p, " $", "raw dollar after a space")
	}
}
