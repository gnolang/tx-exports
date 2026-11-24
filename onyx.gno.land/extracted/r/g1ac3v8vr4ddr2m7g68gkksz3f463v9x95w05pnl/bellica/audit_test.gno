package bellica

// Self-audit PoCs (AUDIT.md). Each TestAudit_* asserts the SAFE behaviour, so
// it failed on the pre-audit code (PoC) and now guards the fix (regression).

import (
	"chain"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// F1: bidi overrides / zero-width / control chars are stored and rendered verbatim
// ("‮gnp.exe" shows reversed, names can be visually spoofed).
func TestAudit_F1_BidiAndControlCharsStripped(cur realm, t *testing.T) {
	ev := testutils.TestAddress("f1evil")
	testing.SetRealm(testing.NewUserRealm(ev))
	Register(cross(cur), "turbo\u202Egnp.exe\u200B\x00\x1b", "", "bio\u2066x\u2069\u200F\x7f")
	a := agentOf(ev)
	for _, bad := range []string{"\u202E", "\u200B", "\x00", "\x1b", "\u2066", "\u2069", "\u200F", "\x7f"} {
		uassert.False(t, strings.Contains(a.Name+a.Bio, bad), "stored text still contains "+strconv.Quote(bad))
	}
	page := Render("agent/" + ev.String())
	uassert.False(t, strings.Contains(page, "\u202E"), "rendered page contains U+202E")
	uassert.Equal(t, "turbognp.exe", a.Name)
}

// F2: esc() does not neutralise '&', '@' or '$': named HTML entities (&rlm; bidi
// mark), @user mention links and KaTeX math are rendered by gnoweb from user text.
func TestAudit_F2_MarkdownExtensionsEscaped(cur realm, t *testing.T) {
	ev := testutils.TestAddress("f2evil")
	testing.SetRealm(testing.NewUserRealm(ev))
	Register(cross(cur), "f2-bot", "", "see @admin and $\\frac{1}{0}$ &rlm;x")
	page := Render("agent/" + ev.String())
	uassert.True(t, strings.Contains(page, "\\@admin"), page)
	uassert.True(t, strings.Contains(page, "\\$"), page)
	uassert.True(t, strings.Contains(page, "\\&rlm;"), page)
}

// F3: when the creator is also the judge (the default), the creator can take the
// pot back after valid entries exist by disqualifying all of them. This stays
// possible by design (the judge is trusted), so the fix is disclosure: the page
// and JSON must flag a self-judged bounty.
func TestAudit_F3_SelfJudgedBountyIsFlagged(cur realm, t *testing.T) {
	ag := testutils.TestAddress("f3agent")
	register(cur, ag, "f3-agent")
	id := newBounty(cur, 3_000_000, "100", false, "") // judge = creator
	testing.SetRealm(testing.NewUserRealm(ag))
	Submit(cross(cur), id, "https://github.com/f3/x", "abcd1234", "", 5)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(creator))
	before := bal(cur, creator)
	Disqualify(cross(cur), id, ag.String(), "no reason really")
	Finalize(cross(cur), id)
	// the documented, accepted behaviour: pot back to creator, reason public
	uassert.Equal(t, before+3_000_000, bal(cur, creator))
	uassert.True(t, strings.Contains(Render("bounty/"+itoa(id)), "Self-judged"), "self-judged bounty not flagged")
	uassert.True(t, strings.Contains(Render("json/bounty/"+itoa(id)), `"self_judged":true`))
}

// F4: Sybil entries fill a bounty (200 cap) and lock real agents out; the judge
// cannot remove them before the deadline, and if the judge does not clear them
// one tx each, Fallback splits the pot among the sybils.
func TestAudit_F4_SybilFillCanBeCleared(cur realm, t *testing.T) {
	id := newBounty(cur, 10_000_000, "50,30,20", false, judge.String())
	var syb []string
	for i := 0; i < maxEntriesPer; i++ {
		a := testutils.TestAddress("f4s" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(a))
		Register(cross(cur), "s"+strconv.Itoa(i), "", "")
		Submit(cross(cur), id, "https://github.com/s/s", "abcd1234", "", 0)
		syb = append(syb, a.String())
	}
	honest := testutils.TestAddress("f4honest")
	register(cur, honest, "honest")
	testing.SetRealm(testing.NewUserRealm(honest))
	uassert.AbortsWithMessage(t, cur, "bounty is full", func() {
		Submit(cross(cur), id, "https://github.com/h/h", "abcd1234", "", 50)
	})
	// the judge must be able to remove spam while the bounty is still open
	testing.SetRealm(testing.NewUserRealm(judge))
	Disqualify(cross(cur), id, syb[0], "spam entry, empty repo")
	testing.SetRealm(testing.NewUserRealm(honest))
	Submit(cross(cur), id, "https://github.com/h/h", "abcd1234", "", 50)
	uassert.Equal(t, maxEntriesPer+1, bountyEntries(id))
}

func bountyEntries(id int) int { return mustBounty(id).entries.Size() }

// F6: the link label is cut at 39 bytes, so a long look-alike host hides its
// real registrable domain ("github.com.<long>…" while the href goes to evil.io).
func TestAudit_F6_LinkLabelShowsFullHost(cur realm, t *testing.T) {
	host := "github.com.release-assets-download-mirror-cdn.evil.io"
	l := link("https://" + host + "/owner/repo")
	label := l[:strings.Index(l, "](")] // visible text only, not the href
	uassert.True(t, strings.Contains(label, "evil.io"), l)
}

// F8: the gap column overflows int64 with extreme claimed scores and shows a
// misleading sign (a worse entry looks better than the leader).
func TestAudit_F8_GapDoesNotOverflow(cur realm, t *testing.T) {
	x := testutils.TestAddress("f8x")
	y := testutils.TestAddress("f8y")
	register(cur, x, "f8-low")
	register(cur, y, "f8-one")
	id := newBounty(cur, 1_000_000, "100", false, judge.String())
	testing.SetRealm(testing.NewUserRealm(x))
	Submit(cross(cur), id, "https://github.com/x/x", "abcd1234", "", -9223372036854775808)
	testing.SetRealm(testing.NewUserRealm(y))
	Submit(cross(cur), id, "https://github.com/y/y", "abcd1234", "", 1)
	page := Render("bounty/" + itoa(id))
	uassert.False(t, strings.Contains(page, "| -9223372036854775807 |"), page)
}

var _ = chain.Coins{}
