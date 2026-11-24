package agentmarketplace

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRenderHomeAndPages(cur realm, t *testing.T) {
	reset()
	realmURL = "/r/g1pzn6rn8q0pfmq4xje4j8086ncnldavyz8skgp3/agentmarketplace"

	empty := Render("")
	uassert.True(t, strings.Contains(empty, "Agent Marketplace"))
	uassert.True(t, strings.Contains(empty, "No agents yet"))
	uassert.True(t, strings.Contains(empty, "No open tasks"))
	uassert.True(t, strings.Contains(Render("missing"), "Not found"))

	register(cur, carol, "Research Bot", "research, writing", RateHourly, 500000)
	register(cur, bob, "Code Agent", "code, review", RateFlat, 2000000)
	openID := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 3000000)
	workID := post(cur, alice, "Review a realm", "Look over an escrow realm for footguns please.", "review", 4000000)
	bid(cur, carol, openID, 2500000, "I can summarize this")
	bid2 := bid(cur, bob, workID, 3500000, "I can review this")
	accept(cur, alice, workID, bid2)
	complete(cur, bob, workID)

	home := Render("")
	uassert.True(t, strings.Contains(home, "Research Bot"))
	uassert.True(t, strings.Contains(home, "Code Agent"))
	uassert.True(t, strings.Contains(home, "Summarize a paper"))
	uassert.True(t, strings.Contains(home, "In escrow"))
	uassert.False(t, strings.Contains(home, "Review a realm"), "completed tasks should not appear in the open list")

	agentPage := Render("agent/" + carol.String())
	uassert.True(t, strings.Contains(agentPage, "Research Bot"))
	uassert.True(t, strings.Contains(agentPage, "research, writing"))
	uassert.True(t, strings.Contains(agentPage, "Summarize a paper"))

	taskPage := Render("task/" + strconv.Itoa(openID))
	uassert.True(t, strings.Contains(taskPage, "Summarize a paper"))
	uassert.True(t, strings.Contains(taskPage, "I can summarize this"))
	uassert.True(t, strings.Contains(taskPage, "Place a bid"))
	uassert.True(t, strings.Contains(taskPage, "Cancel and refund"))

	donePage := Render("task/" + strconv.Itoa(workID))
	uassert.True(t, strings.Contains(donePage, "Completed"))
	uassert.True(t, strings.Contains(donePage, "Code Agent"))
	uassert.True(t, strings.Contains(donePage, "Escrow has been released"))
	uassert.True(t, strings.Contains(donePage, "Rate 5 stars"))

	rate(cur, alice, workID, 5, "Great review")

	home = Render("")
	uassert.True(t, strings.Contains(home, "Leaderboard"))
	uassert.True(t, strings.Contains(home, "5.00"))
	uassert.True(t, strings.Contains(home, "provisional"))

	agentPage = Render("agent/" + bob.String())
	uassert.True(t, strings.Contains(agentPage, "5.00"))
	uassert.True(t, strings.Contains(agentPage, "Great review"))
	uassert.True(t, strings.Contains(agentPage, "Rating history"))

	ratedPage := Render("task/" + strconv.Itoa(workID))
	uassert.True(t, strings.Contains(ratedPage, "5 / 5"))
	uassert.True(t, strings.Contains(ratedPage, "Great review"))

	board := Render("leaderboard")
	uassert.True(t, strings.Contains(board, "Code Agent"))
	uassert.True(t, strings.Contains(board, "5.00"))
	uassert.True(t, strings.Contains(board, "provisional"))

	about := Render("about")
	uassert.True(t, strings.Contains(about, "20%"))
	uassert.True(t, strings.Contains(about, "45-day"))
	uassert.True(t, strings.Contains(about, "no identity layer"))
	uassert.True(t, strings.Contains(about, "Hash-commit"))
	uassert.True(t, strings.Contains(Render("agents"), "Research Bot"))
	uassert.True(t, strings.Contains(Render("tasks"), "Review a realm"))
}

func TestFmtUgnot(t *testing.T) {
	uassert.Equal(t, "0 GNOT", fmtUgnot(0))
	uassert.Equal(t, "1 GNOT", fmtUgnot(1000000))
	uassert.Equal(t, "1.5 GNOT", fmtUgnot(1500000))
	uassert.Equal(t, "0.5 GNOT", fmtUgnot(500000))
	uassert.Equal(t, "1,000 GNOT", fmtUgnot(1000000000))
	uassert.Equal(t, "-2 GNOT", fmtUgnot(-2000000))
}
