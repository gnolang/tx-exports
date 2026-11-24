package bellica

// Regression tests for the self-audit fixes (AUDIT.md) and the gnoweb UX items.

import (
	"chain"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// F4: batch disqualification, DQ'd agents cannot resubmit, reinstating frees
// the DQ counter, and the hard total cap holds.
func TestAudit_F4_DisqualifyManyAndCaps(cur realm, t *testing.T) {
	id := newBounty(cur, 4_000_000, "60,40", false, judge.String())
	var list []string
	for i := 0; i < 5; i++ {
		a := testutils.TestAddress("r4s" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(a))
		Register(cross(cur), "r4s"+strconv.Itoa(i), "", "")
		Submit(cross(cur), id, "https://github.com/s/s", "abcd1234", "", 1)
		list = append(list, a.String())
	}
	// only the judge, reason required, batch bounded
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "only the judge can do this", func() { DisqualifyMany(cross(cur), id, list[0], "spam spam") })
	testing.SetRealm(testing.NewUserRealm(judge))
	uassert.AbortsWithMessage(t, cur, "reason must be 3-280 characters", func() { DisqualifyMany(cross(cur), id, list[0], "\u202e  ") })
	big := strings.Repeat(list[0]+",", maxDQBatch) + list[1]
	uassert.AbortsWithMessage(t, cur, "at most 50 agents per call", func() { DisqualifyMany(cross(cur), id, big, "spam spam") })
	uassert.Equal(t, 3, DisqualifyMany(cross(cur), id, strings.Join(list[:3], ", ")+",", "empty repo, spam"))
	uassert.Equal(t, 3, mustBounty(id).dqs)
	// DQ twice does not double count
	Disqualify(cross(cur), id, list[0], "still spam")
	uassert.Equal(t, 3, mustBounty(id).dqs)
	// a disqualified agent cannot resubmit while open
	testing.SetRealm(testing.NewUserRealm(address(list[0])))
	uassert.AbortsWithMessage(t, cur, "your entry was disqualified: still spam", func() {
		Submit(cross(cur), id, "https://github.com/s/s", "abcd9999", "", 0)
	})
	// reinstating during judging decrements the counter
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(judge))
	ScoreEntry(cross(cur), id, list[1], 7)
	uassert.Equal(t, 2, mustBounty(id).dqs)
	// judge window over: no more disqualifications
	minutes(61)
	uassert.AbortsWithMessage(t, cur, "judging window is over; use Fallback", func() { Disqualify(cross(cur), id, list[3], "late dq") })
}

// F4: the total cap (incl. disqualified entries) bounds Finalize/Fallback loops.
func TestAudit_F4_TotalCap(cur realm, t *testing.T) {
	id := newBounty(cur, 1_000_000, "100", false, judge.String())
	b := mustBounty(id)
	for i := 0; i < maxEntriesPer; i++ {
		a := testutils.TestAddress("r4t" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(a))
		Register(cross(cur), "t", "", "")
		Submit(cross(cur), id, "https://github.com/s/s", "abcd1234", "", 1)
	}
	uassert.Equal(t, maxEntriesPer, b.entries.Size())
	b.dqs = b.entries.Size() // as if the judge had DQ'd all 200: active slots free up, total cap remains
	for i := maxEntriesPer; i < maxEntriesTotal; i++ {
		a := testutils.TestAddress("r4t" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(a))
		Register(cross(cur), "t", "", "")
		Submit(cross(cur), id, "https://github.com/s/s", "abcd1234", "", 1)
	}
	x := testutils.TestAddress("r4tx")
	register(cur, x, "x")
	testing.SetRealm(testing.NewUserRealm(x))
	uassert.AbortsWithMessage(t, cur, "bounty is full", func() { Submit(cross(cur), id, "https://github.com/s/s", "abcd1234", "", 1) })
}

// F5: the leaderboard index stays in sync with Earned/Wins and has no stale keys.
func TestAudit_F5_LeaderboardIndex(cur realm, t *testing.T) {
	p := testutils.TestAddress("r5p")
	q := testutils.TestAddress("r5q")
	register(cur, p, "r5-p")
	register(cur, q, "r5-q")
	before := competing
	id := newBounty(cur, 10_000_000, "70,30", true, judge.String())
	submit(cur, p, id, 10)
	submit(cur, q, id, 20)
	uassert.Equal(t, before+2, competing)
	submit(cur, q, id, 21) // resubmit does not double count
	uassert.Equal(t, before+2, competing)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(judge))
	AcceptClaimed(cross(cur), id)
	Finalize(cross(cur), id)
	uassert.Equal(t, competing, board.Size()) // one key per competing agent
	// board order == earned desc, wins desc
	var prev *Agent
	board.Iterate("", "", func(_ string, v any) bool {
		a := v.(*Agent)
		if prev != nil {
			uassert.True(t, prev.Earned > a.Earned || (prev.Earned == a.Earned && prev.Wins >= a.Wins), "board out of order")
		}
		prev = a
		return false
	})
	uassert.True(t, strings.Contains(Render("agents"), "r5-q"), Render("agents"))
	js := Render("json/agents")
	uassert.True(t, strings.Index(js, `"name":"r5-q"`) < strings.Index(js, `"name":"r5-p"`), js)
}

// F5: agent history and posted/judged come from per-address indexes.
func TestAudit_F5_AgentHistoryIndex(cur realm, t *testing.T) {
	h := testutils.TestAddress("r5h")
	register(cur, h, "r5-h")
	register(cur, judge, "r5-judge")
	register(cur, creator, "r5-host")
	id := newBounty(cur, 2_000_000, "100", false, judge.String())
	submit(cur, h, id, 3)
	page := Render("agent/" + h.String())
	uassert.True(t, strings.Contains(page, "Contest history"), page)
	uassert.True(t, strings.Contains(page, pl("bounty/"+itoa(id))), page)
	jp := Render("agent/" + judge.String())
	uassert.True(t, strings.Contains(jp, "Posted / judged"), jp)
	cp := Render("agent/" + creator.String())
	uassert.True(t, strings.Contains(cp, "| creator |"), cp)
}

// F5: json/bounties = open + newest closed (bounded); json/bounties/{page} pages all.
func TestAudit_F5_BountiesJSONPaging(cur realm, t *testing.T) {
	id := newBounty(cur, 1_000_000, "100", false, "")
	testing.SetRealm(testing.NewUserRealm(creator))
	Cancel(cross(cur), id)
	id2 := newBounty(cur, 1_000_000, "100", false, "")
	all := Render("json/bounties")
	uassert.True(t, strings.Contains(all, `"id":`+itoa(id)+`,`), all)
	uassert.True(t, strings.Index(all, `"id":`+itoa(id2)+`,`) < strings.Index(all, `"id":`+itoa(id)+`,`), "newest first")
	p1 := Render("json/bounties/1")
	uassert.True(t, strings.HasPrefix(p1, `[{"id":`+itoa(id2)+`,`), p1)
	uassert.Equal(t, `{"error":"bad page"}`, Render("json/bounties/0"))
	uassert.Equal(t, "[]", Render("json/bounties/999999"))
	_, isOpen := openBounties.Get(key(id)).(*Bounty)
	uassert.False(t, isOpen, "cancelled bounty left in the open index")
}

// UX (UX_REVIEW §7): internal links are absolute (gnoweb drops ":page" links),
// titles and agent names are links, and home has an "Enter a bounty" path.
func TestAudit_UX_LinksAndEnterButton(cur realm, t *testing.T) {
	u := testutils.TestAddress("uxagent")
	register(cur, u, "ux-agent")
	id := newBounty(cur, 1_000_000, "100", false, judge.String())
	submit(cur, u, id, 9)
	pages := []string{"", "bounty/" + itoa(id), "agent/" + u.String(), "agents", "help", "stats", "nope"}
	for _, p := range pages {
		out := Render(p)
		uassert.False(t, strings.Contains(out, "](:"), "relative link on "+p)
	}
	home := Render("")
	uassert.True(t, strings.Contains(home, `label="🚀 Enter a bounty"`), home)
	uassert.True(t, strings.Contains(home, pl("bounty/"+itoa(newestEnterable()))), home)
	uassert.True(t, strings.Contains(home, "[ux-agent]("+pl("agent/"+u.String())+")"), home) // leader cell is a link
	bp := Render("bounty/" + itoa(id))
	uassert.True(t, strings.Contains(bp, "[ux-agent]("+pl("agent/"+u.String())+")"), bp)
	uassert.True(t, strings.HasPrefix(pl("help"), "/r/"), pl("help"))
}

func newestEnterable() int { return enterable().ID }

// F1: every input path is cleaned (titles, URLs, notes, reasons, judge).
func TestAudit_F1_AllInputsCleaned(cur realm, t *testing.T) {
	c := testutils.TestAddress("r1c")
	register(cur, c, "r1-c")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(nil)
	id := newBountyTitled(cur, "Spoof\u202e title\u200b", " "+judge.String()+"\u200f ")
	b := mustBounty(id)
	uassert.Equal(t, "Spoof title", b.Title)
	uassert.Equal(t, judge, b.Judge)
	testing.SetRealm(testing.NewUserRealm(c))
	Submit(cross(cur), id, "https://github.com/c/c\u202e", "abcd1234\u2066", "note\u202e\x07", 1)
	e := b.entries.Get(c.String()).(*Entry)
	uassert.Equal(t, "https://github.com/c/c", e.RepoURL)
	uassert.Equal(t, "abcd1234", e.Commit)
	uassert.Equal(t, "note", e.Note)
	// a line break smuggled as U+2028 is still rejected
	uassert.AbortsWithMessage(t, cur, "note must be a single line", func() {
		Submit(cross(cur), id, "https://github.com/c/c", "abcd1234", "a\u2028b", 1)
	})
}

func newBountyTitled(cur realm, title, judgeAddr string) int {
	testing.IssueCoins(pkgAddr, coins(1_000_000))
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(coins(1_000_000))
	id := CreateBounty(cross(cur), title, "", "ms", false, "100", 60, 60, judgeAddr, "", 0)
	testing.SetOriginSend(nil)
	return id
}

func coins(n int64) chain.Coins { return chain.Coins{{"ugnot", n}} }

// FP check (double pay): once closed, no door reopens; each close path runs once.
func TestAudit_FP_NoDoubleClose(cur realm, t *testing.T) {
	w := testutils.TestAddress("fpw")
	register(cur, w, "fp-w")
	id := newBounty(cur, 2_000_000, "100", false, judge.String())
	submit(cur, w, id, 1)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(judge))
	AcceptClaimed(cross(cur), id)
	Finalize(cross(cur), id)
	paid := mustBounty(id).Paid
	uassert.AbortsWithMessage(t, cur, "bounty is not in judging (wait for the deadline)", func() { Finalize(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, "bounty is closed", func() { Disqualify(cross(cur), id, w.String(), "late dq") })
	minutes(200)
	uassert.AbortsWithMessage(t, cur, "fallback only after the judging window, on an unfinalized bounty", func() { Fallback(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "cannot cancel: bounty has entries or is closed", func() { Cancel(cross(cur), id) })
	uassert.Equal(t, paid, mustBounty(id).Paid)
	uassert.Equal(t, int64(2_000_000), paid)
}
