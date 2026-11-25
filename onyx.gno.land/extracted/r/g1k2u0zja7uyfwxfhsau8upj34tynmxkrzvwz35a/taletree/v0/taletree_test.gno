package taletree

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	carol   = testutils.TestAddress("carol")
	dave    = testutils.TestAddress("dave")
	keeperA = testutils.TestAddress("keeper")

	opening = "The tavern fire is low and a stranger in a grey hood sits down at your table."
	body    = "Something happens next, and it is long enough to be a passage."
)

func resetState() {
	taleSeq = 0
	passageSeq = 0
	tales = avl.Tree{}
	passages = avl.Tree{}
	cheers = avl.Tree{}
	bards = avl.Tree{}
	bardPassages = avl.Tree{}
	fame = avl.Tree{}
	totalTips = 0
	paused = false
	keeper = ownable.NewWithAddress(keeperA)
}

func TestStartTale(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))

	tid := StartTale(cross(cur), "  The Grey   Stranger ", opening)
	uassert.Equal(t, 1, tid)
	uassert.Equal(t, 1, TaleCount())
	uassert.Equal(t, 1, PassageCount())
	uassert.Equal(t, 1, BardCount())

	tv, ok := GetTale(tid)
	urequire.True(t, ok)
	uassert.Equal(t, "The Grey Stranger", tv.Title, "title is trimmed and spaces folded")
	uassert.Equal(t, alice, tv.Narrator)
	uassert.Equal(t, 1, tv.Root)
	uassert.Equal(t, 1, tv.Passages)

	pv, ok := GetPassage(tv.Root)
	urequire.True(t, ok)
	uassert.Equal(t, opening, pv.Body)
	uassert.Equal(t, 0, pv.Depth)
	uassert.Equal(t, 0, pv.Parent)
	uassert.Equal(t, alice, pv.Author)

	b, _ := getBard(alice)
	uassert.Equal(t, 1, b.Tales)
	uassert.Equal(t, 1, b.Passages)

	// A second tale gets the next ids.
	tid2 := StartTale(cross(cur), "Second tale", opening)
	uassert.Equal(t, 2, tid2)
	tv2, _ := GetTale(tid2)
	uassert.Equal(t, 2, tv2.Root)
}

func TestStartTaleValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))

	uassert.AbortsWithMessage(t, cur, ErrTitleLength.Error(), func() { StartTale(cross(cur), "ab", opening) })
	uassert.AbortsWithMessage(t, cur, ErrTitleLength.Error(), func() { StartTale(cross(cur), strings.Repeat("x", MaxTitleLen+1), opening) })
	uassert.AbortsWithMessage(t, cur, ErrBodyLength.Error(), func() { StartTale(cross(cur), "Title", "too short") })
	uassert.AbortsWithMessage(t, cur, ErrBodyLength.Error(), func() { StartTale(cross(cur), "Title", strings.Repeat("x", MaxBodyLen+1)) })
	uassert.Equal(t, 0, TaleCount(), "failed calls leave no state")
}

func TestBranchAndEnding(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	tid := StartTale(cross(cur), "The Grey Stranger", opening)
	root := 1

	testing.SetRealm(testing.NewUserRealm(bob))
	a := Branch(cross(cur), root, "Ask the stranger's name", body)
	uassert.Equal(t, 2, a)
	e := WriteEnding(cross(cur), root, "Leave the tavern", body)
	uassert.Equal(t, 3, e)

	pa, _ := GetPassage(a)
	uassert.Equal(t, 1, pa.Depth)
	uassert.Equal(t, root, pa.Parent)
	uassert.Equal(t, "Ask the stranger's name", pa.Choice)
	uassert.False(t, pa.Ending)
	pe, _ := GetPassage(e)
	uassert.True(t, pe.Ending)

	pr, _ := GetPassage(root)
	uassert.Equal(t, 2, len(pr.Children))
	tv, _ := GetTale(tid)
	uassert.Equal(t, 3, tv.Passages)
	uassert.Equal(t, 1, tv.Endings)

	// Endings have no choices.
	uassert.AbortsWithMessage(t, cur, ErrIsEnding.Error(), func() { Branch(cross(cur), e, "Come back", body) })
	// Sibling choices must differ, ignoring case.
	uassert.AbortsWithMessage(t, cur, ErrDuplicateChoice.Error(), func() { Branch(cross(cur), root, "ask the STRANGER'S name", body) })
	// Unknown parent.
	uassert.AbortsWithMessage(t, cur, ErrPassageNotFound.Error(), func() { Branch(cross(cur), 99, "Nowhere", body) })
	uassert.AbortsWithMessage(t, cur, ErrPassageNotFound.Error(), func() { Branch(cross(cur), 0, "Nowhere", body) })
	// Length checks.
	uassert.AbortsWithMessage(t, cur, ErrChoiceLength.Error(), func() { Branch(cross(cur), root, "go", body) })
	uassert.AbortsWithMessage(t, cur, ErrBodyLength.Error(), func() { Branch(cross(cur), root, "Go on", "short") })

	// Gnokey sends newlines as the two characters `\n`.
	nl := Branch(cross(cur), a, "Listen", `First line.\nSecond line of the passage.`)
	pn, _ := GetPassage(nl)
	uassert.Equal(t, "First line.\nSecond line of the passage.", pn.Body)
}

func TestMaxChoices(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	StartTale(cross(cur), "Crowded room", opening)
	for i := 0; i < MaxChoices; i++ {
		Branch(cross(cur), 1, "Door number "+string(rune('A'+i)), body)
	}
	uassert.AbortsWithMessage(t, cur, ErrTooManyChoices.Error(), func() { Branch(cross(cur), 1, "One door too many", body) })
}

func TestMaxDepth(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	StartTale(cross(cur), "A long road", opening)
	parent := 1
	for d := 1; d < MaxDepth; d++ {
		parent = Branch(cross(cur), parent, "Keep walking", body)
	}
	p, _ := GetPassage(parent)
	uassert.Equal(t, MaxDepth-1, p.Depth)

	// The last level only takes endings.
	uassert.AbortsWithMessage(t, cur, ErrTooDeep.Error(), func() { Branch(cross(cur), parent, "Walk further", body) })
	end := WriteEnding(cross(cur), parent, "Arrive at last", body)
	pe, _ := GetPassage(end)
	uassert.Equal(t, MaxDepth, pe.Depth)

	// The canon walks the whole road.
	uassert.Equal(t, MaxDepth+1, len(CanonPath(1)))
}

func TestCheerAndCanon(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	StartTale(cross(cur), "Two doors", opening)
	testing.SetRealm(testing.NewUserRealm(bob))
	left := Branch(cross(cur), 1, "Take the left door", body)
	testing.SetRealm(testing.NewUserRealm(carol))
	right := Branch(cross(cur), 1, "Take the right door", body)

	// Tie: the earliest passage wins.
	uassert.Equal(t, "[1 2]", ufmtInts(CanonPath(1)))

	testing.SetRealm(testing.NewUserRealm(alice))
	Cheer(cross(cur), right)
	uassert.Equal(t, "[1 3]", ufmtInts(CanonPath(1)))
	uassert.True(t, HasCheered(right, alice))
	uassert.False(t, HasCheered(left, alice))

	// Once per address, never your own.
	uassert.AbortsWithMessage(t, cur, ErrAlreadyCheered.Error(), func() { Cheer(cross(cur), right) })
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, ErrSelfCheer.Error(), func() { Cheer(cross(cur), right) })

	testing.SetRealm(testing.NewUserRealm(dave))
	Cheer(cross(cur), left)
	testing.SetRealm(testing.NewUserRealm(carol))
	Cheer(cross(cur), left)
	uassert.Equal(t, "[1 2]", ufmtInts(CanonPath(1)), "left now has 2 cheers against 1")

	tv, _ := GetTale(1)
	uassert.Equal(t, 3, tv.Cheers)

	// Hall of fame: bob (2 cheers) before carol (1).
	var order []address
	fame.Iterate("", "", func(_ string, v any) bool {
		order = append(order, v.(address))
		return false
	})
	urequire.True(t, len(order) >= 2)
	uassert.Equal(t, bob, order[0])
	uassert.Equal(t, carol, order[1])
	bb, _ := getBard(bob)
	uassert.Equal(t, 2, bb.Cheers)
	uassert.Equal(t, bards.Size(), fame.Size(), "one fame entry per bard")
}

func TestTip(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	StartTale(cross(cur), "Paid in coin", opening)
	testing.SetRealm(testing.NewUserRealm(bob))
	pid := Branch(cross(cur), 1, "Pay the bard", body)

	realmAddr := chain.PackageAddress("gno.land" + base)
	bnk := banker.NewReadonlyBanker()
	before := bnk.GetCoin(bob, "ugnot")

	// The coins of a maketx call land on the realm before the call runs.
	tip := chain.Coins{{Denom: "ugnot", Amount: 1_500_000}}
	testing.IssueCoins(realmAddr, tip)
	testing.SetOriginSend(tip)
	testing.SetRealm(testing.NewUserRealm(carol))
	Tip(cross(cur), pid)

	uassert.Equal(t, before+1_500_000, bnk.GetCoin(bob, "ugnot"), "author got the whole tip")
	uassert.Equal(t, int64(0), bnk.GetCoin(realmAddr, "ugnot"), "the realm keeps nothing")
	pv, _ := GetPassage(pid)
	uassert.Equal(t, int64(1_500_000), pv.Tips)
	uassert.Equal(t, int64(1_500_000), TotalTips())
	bb, _ := getBard(bob)
	uassert.Equal(t, int64(1_500_000), bb.Tips)

	// Self tips, empty tips and other denoms are refused.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, ErrSelfTip.Error(), func() { Tip(cross(cur), pid) })
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, ErrTipAmount.Error(), func() { Tip(cross(cur), pid) })
	testing.SetOriginSend(chain.Coins{{Denom: "ufoo", Amount: 5}})
	uassert.AbortsWithMessage(t, cur, ErrTipAmount.Error(), func() { Tip(cross(cur), pid) })
	testing.SetOriginSend(chain.Coins{{Denom: "ufoo", Amount: 5}, {Denom: "ugnot", Amount: 5}})
	uassert.AbortsWithMessage(t, cur, ErrTipAmount.Error(), func() { Tip(cross(cur), pid) })

	// A code realm in between could have spent the coins: refused.
	testing.SetOriginSend(tip)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/someone/middleman"))
	uassert.AbortsWithMessage(t, cur, ErrTipCaller.Error(), func() { Tip(cross(cur), pid) })
}

func TestHideAndUnhide(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	StartTale(cross(cur), "Moderated", opening)
	testing.SetRealm(testing.NewUserRealm(bob))
	p2 := Branch(cross(cur), 1, "A rude choice", body)
	p3 := Branch(cross(cur), p2, "Even ruder", body)

	// Strangers cannot hide.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, ErrUnauthorized.Error(), func() { Hide(cross(cur), p2, "spam") })

	// The narrator can; the subtree goes with it.
	testing.SetRealm(testing.NewUserRealm(alice))
	Hide(cross(cur), p2, "off topic")
	v2, _ := GetPassage(p2)
	v3, _ := GetPassage(p3)
	uassert.True(t, v2.Hidden)
	uassert.True(t, v3.Hidden, "children of a hidden passage are hidden")
	uassert.Equal(t, "", v3.Body, "hidden bodies are not served")
	uassert.Equal(t, "[1]", ufmtInts(CanonPath(1)))
	uassert.AbortsWithMessage(t, cur, ErrAlreadyHidden.Error(), func() { Hide(cross(cur), p2, "") })

	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, ErrPassageHidden.Error(), func() { Cheer(cross(cur), p3) })
	uassert.AbortsWithMessage(t, cur, ErrPassageHidden.Error(), func() { Branch(cross(cur), p3, "Continue", body) })
	// A hidden choice no longer blocks its text for siblings.
	Branch(cross(cur), 1, "A rude choice", body)

	// The keeper can moderate any tale.
	testing.SetRealm(testing.NewUserRealm(keeperA))
	Unhide(cross(cur), p2)
	v3, _ = GetPassage(p3)
	uassert.False(t, v3.Hidden)
	uassert.AbortsWithMessage(t, cur, ErrNotHidden.Error(), func() { Unhide(cross(cur), p2) })
	uassert.AbortsWithMessage(t, cur, ErrReasonLength.Error(), func() { Hide(cross(cur), p2, strings.Repeat("x", MaxReasonLen+1)) })
}

func TestLockTale(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	StartTale(cross(cur), "Finished story", opening)
	testing.SetRealm(testing.NewUserRealm(bob))
	p2 := Branch(cross(cur), 1, "The last choice", body)
	uassert.AbortsWithMessage(t, cur, ErrUnauthorized.Error(), func() { LockTale(cross(cur), 1) })

	testing.SetRealm(testing.NewUserRealm(alice))
	LockTale(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, ErrTaleLocked.Error(), func() { Branch(cross(cur), 1, "Too late", body) })
	testing.SetRealm(testing.NewUserRealm(carol))
	Cheer(cross(cur), p2) // reading and cheering still work

	testing.SetRealm(testing.NewUserRealm(alice))
	UnlockTale(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	Branch(cross(cur), 1, "Not too late", body)
	uassert.AbortsWithMessage(t, cur, ErrTaleNotFound.Error(), func() { LockTale(cross(cur), 42) })
}

func TestPauseAndKeeper(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, ownable.ErrUnauthorized.Error(), func() { SetPaused(cross(cur), true) })

	testing.SetRealm(testing.NewUserRealm(keeperA))
	SetPaused(cross(cur), true)
	uassert.True(t, IsPaused())
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, ErrPaused.Error(), func() { StartTale(cross(cur), "Title", opening) })

	testing.SetRealm(testing.NewUserRealm(keeperA))
	SetPaused(cross(cur), false)
	TransferKeeper(cross(cur), dave)
	uassert.Equal(t, dave, Keeper())
	uassert.AbortsWithMessage(t, cur, ownable.ErrUnauthorized.Error(), func() { SetPaused(cross(cur), true) })
}

func TestRenderPages(cur realm, t *testing.T) {
	resetState()
	home := Render("")
	uassert.True(t, strings.Contains(home, "# 🌳 Taletree"))
	uassert.True(t, strings.Contains(home, "No tale yet"))

	testing.SetRealm(testing.NewUserRealm(alice))
	StartTale(cross(cur), "The Grey Stranger", opening)
	testing.SetRealm(testing.NewUserRealm(bob))
	p2 := Branch(cross(cur), 1, "Ask the stranger's name", body)
	WriteEnding(cross(cur), 1, "Leave the tavern", body)
	testing.SetRealm(testing.NewUserRealm(carol))
	Cheer(cross(cur), p2)

	home = Render("")
	uassert.True(t, strings.Contains(home, "- **[The Grey Stranger]("+base+":tale/1)** by "), home)
	uassert.True(t, strings.Contains(home, "**1** tale · **3** passages · **2** bards · **0 GNOT** tipped to authors"), home)
	uassert.True(t, strings.Contains(home, "$help&func=StartTale"))

	tale := Render("tale/1")
	uassert.True(t, strings.Contains(tale, opening))
	uassert.True(t, strings.Contains(tale, "- [Ask the stranger's name]("+base+":p/2) · 🍻 1 ✨"), tale)
	uassert.True(t, strings.Contains(tale, "Leave the tavern]("+base+":p/3) · 🍻 0 🏁"), tale)

	page := Render("p/1")
	uassert.True(t, strings.Contains(page, "## What happens next?"))
	uassert.True(t, strings.Contains(page, "1. **[Ask the stranger's name]"), page)
	realmURL := base
	uassert.True(t, strings.Contains(page, realmURL+"$help&func=Branch&parentID=1"), page)
	uassert.True(t, strings.Contains(page, realmURL+"$help&func=Tip&.send=1000000ugnot&passageID=1"), page)

	end := Render("p/3")
	uassert.True(t, strings.Contains(end, "## 🏁 The End"))
	uassert.False(t, strings.Contains(end, "func=Branch"), "no writing under an ending")

	canon := Render("tale/1/canon")
	uassert.True(t, strings.Contains(canon, "### → [Ask the stranger's name]"), canon)

	bard := Render("bard/" + bob.String())
	uassert.True(t, strings.Contains(bard, "**2** passages · **0** tales started"), bard)
	uassert.True(t, strings.Contains(bard, "🍻 **1** cheer received"), bard)

	fameP := Render("bards")
	uassert.True(t, strings.Contains(fameP, "| 1 | [g1vfhkyh…"), fameP)

	uassert.True(t, strings.Contains(Render("p/99"), "There is no such passage"))
	uassert.True(t, strings.Contains(Render("tale/x"), "There is no such tale"))
	uassert.True(t, strings.Contains(Render("bard/nope"), "There is no such bard"))
	uassert.True(t, strings.Contains(Render("nowhere"), "# Page not found"))
}

func TestRenderSanitizesUserText(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	evilTitle := `# Pwned <gno-button href="/r/evil$help&func=Drain" label="Claim" />`
	evilBody := "## Fake heading\n<gno-button href=\"/r/evil\" label=\"x\" />\n[a normal link](https://gno.land) stays."
	StartTale(cross(cur), evilTitle, evilBody)

	// Every copy of the injected tag must be backslash-escaped, so it
	// renders as literal text: drop the escaped copies, none may remain.
	home := Render("")
	page := Render("p/1")
	uassert.True(t, strings.Contains(page, `\<gno\-button href="/r/evil`), "title copy is escaped text")
	uassert.True(t, strings.Contains(page, `\<gno-button href="/r/evil`), "body copy is escaped text")
	for _, out := range []string{home, page} {
		stripped := strings.ReplaceAll(out, `\<`, "")
		uassert.False(t, strings.Contains(stripped, `<gno-button href="/r/evil`), "no live injected button")
		uassert.False(t, strings.Contains(stripped, `<gno\-button`), "no live injected button")
	}
	uassert.False(t, strings.Contains(page, "\n## Fake heading"), "no heading injection")
	uassert.True(t, strings.Contains(page, "[a normal link](https://gno.land)"), "inline links survive")
}

func TestRenderHiddenAndPaging(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	for i := 0; i < talesPerPage+2; i++ {
		StartTale(cross(cur), "Tale number "+string(rune('A'+i)), opening)
	}
	home := Render("")
	uassert.True(t, strings.Contains(home, "Tale number L"), "newest first")
	uassert.False(t, strings.Contains(home, "Tale number A"), "oldest on page 2")
	uassert.True(t, strings.Contains(home, "?page=2"), home)
	uassert.True(t, strings.Contains(Render("?page=2"), "Tale number A"))

	testing.SetRealm(testing.NewUserRealm(bob))
	p := Branch(cross(cur), 1, "A choice to hide", body)
	testing.SetRealm(testing.NewUserRealm(alice))
	Hide(cross(cur), p, "spam")
	hidden := Render("p/" + itoa(p))
	uassert.True(t, strings.Contains(hidden, "was hidden by a moderator. Reason: spam"), hidden)
	uassert.False(t, strings.Contains(hidden, body))
	uassert.False(t, strings.Contains(Render("tale/1"), "A choice to hide"))

	// Hiding an opening hides the tale's title from the home list too.
	Hide(cross(cur), 1, "abuse")
	uassert.False(t, strings.Contains(Render("?page=2"), "Tale number A"))
	uassert.True(t, strings.Contains(Render("?page=2"), "Hidden tale"))
	uassert.True(t, strings.Contains(Render("tale/1"), "This tale was hidden by a moderator"))
}

func TestGnotFormat(t *testing.T) {
	uassert.Equal(t, "0 GNOT", gnot(0))
	uassert.Equal(t, "1 GNOT", gnot(1_000_000))
	uassert.Equal(t, "1.5 GNOT", gnot(1_500_000))
	uassert.Equal(t, "2.05 GNOT", gnot(2_050_000))
	uassert.Equal(t, "0.01 GNOT", gnot(10_000))
	uassert.Equal(t, "0 GNOT", gnot(9_999))
}

func ufmtInts(ids []int) string {
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = itoa(id)
	}
	return "[" + strings.Join(parts, " ") + "]"
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	return s
}
