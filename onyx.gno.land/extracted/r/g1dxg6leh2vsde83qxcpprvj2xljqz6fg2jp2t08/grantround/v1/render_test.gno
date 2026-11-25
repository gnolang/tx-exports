package grantround

import (
	"chain/runtime"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
	"gno.land/p/nt/uassert/v0"
)

func TestRenderRound(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	sheets(cur, id, e1.String(), "5,5;6,0", e2.String(), "4,0;6,2", e3.String(), "1,0;9,0")
	finalizeAs(cur, outsider, id)

	out := Render("round/" + strconv.Itoa(id))
	for _, want := range []string{
		"# Round " + strconv.Itoa(id),
		"Fund one useful Gno package",
		"Phase: done",
		"Method: weighted sum",
		"a (weight 3)",
		"| 1 | Beta |",
		"| 65 |", // app 1 total: 18+20+27
		"Winner: application 1 (Beta)",
		"Paid 1000000ugnot to " + p1.String(),
	} {
		uassert.True(t, strings.Contains(out, want), "missing: "+want+"\n---\n"+out)
	}

	home := Render("")
	uassert.True(t, strings.Contains(home, "round/"+strconv.Itoa(id)), "home lists round")
	uassert.True(t, strings.Contains(Render("round/9999"), "not found"), "unknown round")
	uassert.True(t, strings.Contains(Render("nope"), "not found"), "unknown path")
}

func TestRenderBeforeReveal(cur realm, t *testing.T) {
	id := ruleRound(cur)
	testing.SetRealm(user(e1))
	ProposeRule(cross(cur), id, "majority", "security:2", 1, "refund", "keep it simple")
	out := Render("round/" + strconv.Itoa(id))
	for _, want := range []string{"Phase: rule", "Proposal #1", "Method: majority of first places", "keep it simple", "not revealed"} {
		uassert.True(t, strings.Contains(out, want), "missing: "+want+"\n---\n"+out)
	}
}

func TestRenderCommitThenReveal(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	page := func() string { return Render("round/" + strconv.Itoa(id)) }
	row := func(ev address, status string) string {
		return "| " + ev.String() + " | " + mustGet(id).Sponsors[mustGet(id).evaluatorIndex(ev)].String() + " | yes | " + status + " |"
	}
	commit(cur, id, e1, "5,7;6,3")
	out := page()
	uassert.True(t, strings.Contains(out, row(e1, "committed")), "e1 committed\n"+out)
	uassert.True(t, strings.Contains(out, row(e2, "")), "e2 nothing yet")
	uassert.True(t, strings.Contains(out, ", scores "+i64(mustGet(id).HScore)+", sheet reveal "+i64(mustGet(id).HSheetReveal)), "deadlines")
	uassert.False(t, strings.Contains(out, "Score sheets"), "no sheets before reveal")
	uassert.False(t, strings.Contains(out, mustGet(id).Commits[0]), "only the fact of the commitment")

	testing.SkipHeights(30)
	out = page()
	uassert.True(t, strings.Contains(out, "Phase: sheet reveal"), "phase\n"+out)
	uassert.False(t, strings.Contains(out, "Score sheets"), "still closed")
	openSheet(cur, id, e1, "5,7;6,3")
	out = page()
	uassert.True(t, strings.Contains(out, row(e1, "revealed")), "e1 revealed\n"+out)
	uassert.True(t, strings.Contains(out, "- "+e1.String()+": app 0 [5,7] app 1 [6,3]"), "sheet shown")
}

// A commitment never opened stays visible as such after settlement.
func TestRenderUnopenedCommitment(cur realm, t *testing.T) {
	id := revealedRound(cur, 1, "lowest")
	commit(cur, id, e1, "5,5;6,0")
	commit(cur, id, e2, "4,0;6,2")
	testing.SkipHeights(30)
	openSheet(cur, id, e1, "5,5;6,0")
	testing.SkipHeights(10)
	finalizeAs(cur, outsider, id)
	out := Render("round/" + strconv.Itoa(id))
	uassert.True(t, strings.Contains(out, "| yes | committed, not revealed |"), "e2 unopened\n"+out)
}

// Newest first, ids compared as numbers: ..., round/10, round/9, ..., round/1.
func TestRenderHomeNumericOrder(cur realm, t *testing.T) {
	for i := 0; i < 12; i++ {
		newRound(cur, e1, s1)
	}
	home := Render("")
	prev := -1
	for id := counter; id >= 1; id-- {
		at := strings.Index(home, ":round/"+strconv.Itoa(id)+")")
		uassert.True(t, at > prev, "round/"+strconv.Itoa(id)+" out of order\n"+home)
		prev = at
	}
	for _, id := range []string{"9", "10", strconv.Itoa(counter)} {
		uassert.True(t, strings.Contains(Render("round/"+id), "# Round "+id+"\n"), "page of round "+id)
	}
	uassert.True(t, strings.Contains(Render("round/-1"), "not found"), "negative id")
}

// Text typed by participants must stay text: no heading, link, HTML or table
// cell of its own. tEvil* are the inputs, tSafe* what the page must contain.
const (
	tEvil    = "x\n\n# Fake [click](https://evil.example) <b> `c` **d** | e"
	tSafe    = `x  \# Fake \[click\]\(https://evil\.example\) \<b\> \` + "`" + `c\` + "`" + ` \*\*d\*\* | e`
	tEvilApp = "x\r\r# Fake [click](https://evil.example) <b>"
	tSafeApp = `x  \# Fake \[click\]\(https://evil\.example\) \<b\>`
)

func mustBeSafe(t *testing.T, page string, want ...string) {
	for _, w := range want {
		uassert.True(t, strings.Contains(page, w), "missing: "+w+"\n---\n"+page)
	}
	for _, bad := range []string{"\n# Fake", "\r", "[click]", "<b>", "**d**"} {
		uassert.False(t, strings.Contains(page, bad), "raw markup: "+bad+"\n---\n"+page)
	}
}

func TestRenderEscapesParticipantText(cur realm, t *testing.T) {
	apps := []rulecalc.App{
		{Title: "T" + tEvilApp, PkgPath: "P" + tEvilApp, Payout: p0},
		{Title: "Beta", PkgPath: "gno.land/r/x/beta", Payout: p1},
	}
	h0 := runtime.ChainHeight()
	testing.SetRealm(user(customer))
	pay(tGrant)
	id := CreateRound(cross(cur), "G"+tEvil, rulecalc.AppsDigest(apps, tSalt),
		evList(e1, s1), tBond, tSlash, h0+10, h0+20, h0+30, h0+40, h0+50)
	page := func() string { return Render("round/" + strconv.Itoa(id)) }

	// the list on the home page: goal
	mustBeSafe(t, Render(""), " — G"+tSafe+" — ")
	mustBeSafe(t, page(), "Goal: G"+tSafe+"\n")

	joinAll(cur, id, e1, s1)
	testing.SkipHeights(11)
	testing.SetRealm(user(e1))
	noPay()
	// a criterion name cannot hold ":" or ","
	ProposeRule(cross(cur), id, "weighted", "C\n\n# Fake [click](x) <b>:2", 1, "lowest", "R"+tEvil)
	mustBeSafe(t, page(), `Criteria: C  \# Fake \[click\]\(x\) \<b\> (weight 2)`, "Rationale: R"+tSafe+"\n")

	testing.SetRealm(user(customer))
	Reveal(cross(cur), id, "T"+tEvilApp+"|P"+tEvilApp+"|"+p0.String()+"\nBeta|gno.land/r/x/beta|"+p1.String(), tSalt)
	mustBeSafe(t, page(), "| 0 | T"+tSafeApp+" | P"+tSafeApp+" | "+p0.String()+" |")

	commit(cur, id, e1, "9;1")
	testing.SkipHeights(30)
	openSheet(cur, id, e1, "9;1")
	testing.SkipHeights(10)
	finalizeAs(cur, outsider, id)
	mustBeSafe(t, page(), "Winner: application 0 (T"+tSafeApp+")")
}

func TestRenderEscapesUnknownPath(t *testing.T) {
	mustBeSafe(t, Render(tEvil), "Page not found: "+tSafe+"\n")
}

// A pipe inside a table cell would open a new column. Titles cannot hold one
// today (it separates the fields), the cell escapes it anyway.
func TestRenderEscapesPipeInCell(cur realm, t *testing.T) {
	id := revealedRound(cur, 1, "lowest")
	mustGet(id).Apps[0].Title = "a|b"
	mustGet(id).Apps[0].PkgPath = "c|d"
	out := Render("round/" + strconv.Itoa(id))
	uassert.True(t, strings.Contains(out, `| 0 | a\|b | c\|d | `), out)
}
