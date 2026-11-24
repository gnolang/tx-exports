package agentmarketplace

import (
	"strconv"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const halfLifeHeights = int64(halfLifeDays * 24 * 3600 / 5) // 45 days at 5s / height

func TestRateAccessControl(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 2000000)

	urequire.AbortsWithMessage(t, cur, "only a settled, completed task can be rated", func() {
		rate(cur, alice, id, 5, "too early")
	})

	bidID := bid(cur, carol, id, 2000000, "ready")
	accept(cur, alice, id, bidID)
	urequire.AbortsWithMessage(t, cur, "only a settled, completed task can be rated", func() {
		rate(cur, alice, id, 5, "still early")
	})

	complete(cur, carol, id)

	urequire.AbortsWithMessage(t, cur, "only the task poster can rate this job", func() {
		rate(cur, bob, id, 5, "not my job")
	})
	urequire.AbortsWithMessage(t, cur, "only the task poster can rate this job", func() {
		rate(cur, carol, id, 5, "self?")
	})
	urequire.AbortsWithMessage(t, cur, "score must be an integer from 1 to 5", func() {
		rate(cur, alice, id, 0, "")
	})
	urequire.AbortsWithMessage(t, cur, "score must be an integer from 1 to 5", func() {
		rate(cur, alice, id, 6, "")
	})

	rid := rate(cur, alice, id, 5, "Excellent summary")
	uassert.Equal(t, 1, rid)
	uassert.Equal(t, 1, RatingCount())

	urequire.AbortsWithMessage(t, cur, "this task has already been rated", func() {
		rate(cur, alice, id, 4, "again")
	})
	uassert.Equal(t, 1, RatingCount())
}

func TestCannotRateOwnAgent(cur realm, t *testing.T) {
	reset()
	// The usual bid path already refuses a poster bidding on their own task,
	// so poke a settled self-deal into state to cover the Rate guard.
	tasks.Set(padID(1), &Task{
		ID:          1,
		Poster:      alice,
		Title:       "Self deal",
		Description: "Should not be rateable by the winner.",
		Specialty:   "research",
		BudgetUgnot: 1000000,
		Status:      StatusCompleted,
		Settled:     true,
		Winner:      alice,
	})
	nextTaskID = 2
	urequire.AbortsWithMessage(t, cur, "you cannot rate your own agent", func() {
		rate(cur, alice, 1, 5, "nice")
	})
	uassert.Equal(t, 0, RatingCount())
}

func TestCannotRateCancelled(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 2000000)
	cancel(cur, alice, id)
	urequire.AbortsWithMessage(t, cur, "only a settled, completed task can be rated", func() {
		rate(cur, alice, id, 5, "cancelled")
	})
}

func TestScoreOfUnratedAndProvisional(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	count, trust, raw, prov := ScoreOf(carol)
	uassert.Equal(t, 0, count)
	uassert.Equal(t, int64(0), trust)
	uassert.Equal(t, int64(0), raw)
	uassert.True(t, prov)
	uassert.Equal(t, "", ReputationSummary(carol))

	// Three 4-star jobs from the same poster: still 4.00, flips to trusted at 3.
	for i := 0; i < 3; i++ {
		title := "Research job " + strconv.Itoa(i+1)
		id := settleJob(cur, alice, carol, title, "A short research brief for this job.", "research", 2000000)
		rate(cur, alice, id, 4, "Solid work")
		count, trust, raw, prov = ScoreOf(carol)
		uassert.Equal(t, i+1, count)
		uassert.Equal(t, int64(4000), trust)
		uassert.Equal(t, int64(4000), raw)
		if i < 2 {
			uassert.True(t, prov, "still provisional before 3 jobs")
			uassert.True(t, strings.Contains(ReputationSummary(carol), "provisional"))
		} else {
			uassert.False(t, prov)
			uassert.True(t, strings.Contains(ReputationSummary(carol), "trusted"))
		}
	}
}

func TestBudgetWeighting(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	// Two posters, same first-job reviewer shape, but 5 GNOT at 5 stars vs 1 GNOT at 1 star.
	// Without the 20% cap this would sit near 4.33; the cap is tested separately.
	idBig := settleJob(cur, alice, carol, "Large research brief", "Write a long research brief for a 5 GNOT budget.", "research", 5000000)
	rate(cur, alice, idBig, 5, "Worth it")
	idSmall := settleJob(cur, dave, carol, "Tiny research note", "Write a one-line research note for a 1 GNOT budget.", "research", 1000000)
	rate(cur, dave, idSmall, 1, "Thin")

	count, trust, raw, prov := ScoreOf(carol)
	uassert.Equal(t, 2, count)
	uassert.True(t, prov)
	uassert.Equal(t, int64(3000), raw, "unweighted average of 5 and 1")
	// 5 GNOT at 5 stars vs 1 GNOT at 1 star should sit between the raw
	// average (3.00) and the uncapped budget mix (~4.33), because the
	// large poster is clipped to 20% of the pre-cap weight mass.
	uassert.True(t, trust != raw)
	uassert.True(t, trust > 3000, "the larger 5-star still counts more")
	uassert.True(t, trust < 4300, "the 20% cap should pull this below the uncapped mix")
}

func TestPosterCapTwentyPercent(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	// Five posters: one 10 GNOT 5-star and four 1 GNOT 1-stars. The cap is
	// 20% (N>=5), so the large poster is clipped to 20% of the pre-cap
	// mass and cannot bury the rest. Uncapped would be ~3.86; capped ~2.65.
	idBig := settleJob(cur, alice, carol, "Large research brief", "Write a long research brief for a 10 GNOT budget.", "research", 10000000)
	rate(cur, alice, idBig, 5, "Loved it")
	smallPosters := []address{dave, eve, frank, bob}
	for i, p := range smallPosters {
		id := settleJob(cur, p, carol, "Tiny research note "+strconv.Itoa(i+1), "Write a one-line research note for 1 GNOT.", "research", 1000000)
		rate(cur, p, id, 1, "Nope")
	}

	count, trust, raw, _ := ScoreOf(carol)
	uassert.Equal(t, 5, count)
	uassert.Equal(t, int64(1800), raw, "unweighted average of 5,1,1,1,1")
	uassert.True(t, trust >= 2550 && trust <= 2800, "capped trust should be near 2.65, got "+fmtScore(trust))
	uassert.True(t, trust > raw, "budget still gives the 5-star more weight than the raw average")
}

func TestSolePosterUncapped(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	id := settleJob(cur, alice, carol, "Solo research brief", "Only one poster rates this agent.", "research", 10000000)
	rate(cur, alice, id, 5, "Only review")
	_, trust, raw, prov := ScoreOf(carol)
	uassert.Equal(t, int64(5000), trust)
	uassert.Equal(t, int64(5000), raw)
	uassert.True(t, prov)
}

func TestHalfLifeDecay(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	// Same poster, same budget: a 5-star ages one half-life, then a fresh
	// 1-star arrives. One poster is uncapped, so decay alone should give
	// (0.5*5 + 1*1) / 1.5 = 2.333.
	idOld := settleJob(cur, alice, carol, "Older research brief", "This 5-star should lose half its weight.", "research", 2000000)
	rate(cur, alice, idOld, 5, "Strong start")
	_, trust, _, _ := ScoreOf(carol)
	uassert.Equal(t, int64(5000), trust)

	testing.SkipHeights(halfLifeHeights)
	idNew := settleJob(cur, alice, carol, "Newer research brief", "This 1-star is fresh and should weigh twice the old 5.", "research", 2000000)
	rate(cur, alice, idNew, 1, "Weak follow-up")

	count, trust, raw, _ := ScoreOf(carol)
	uassert.Equal(t, 2, count)
	uassert.Equal(t, int64(3000), raw)
	// (0.5*5 + 1*1) / 1.5 = 2.333...; allow a little slack if reviewer
	// weights differ by a few GNOT of settled volume.
	uassert.True(t, trust >= 2300 && trust <= 2400, "decayed mix should be near 2.33, got "+fmtScore(trust))
}

func TestDecayDoesNotChangeSingleRatingAverage(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	id := settleJob(cur, alice, carol, "Solo research brief", "A single rating should stay 5.00 as it decays.", "research", 2000000)
	rate(cur, alice, id, 5, "Still five")
	testing.SkipHeights(halfLifeHeights)
	_, trust, raw, _ := ScoreOf(carol)
	uassert.Equal(t, int64(5000), trust, "weight cancels in a single-rating average")
	uassert.Equal(t, int64(5000), raw)
}

func TestRefreshScore(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	idOld := settleJob(cur, alice, carol, "Older research brief", "This 5-star will age one half-life.", "research", 2000000)
	rate(cur, alice, idOld, 5, "Strong start")
	testing.SkipHeights(halfLifeHeights)
	idNew := settleJob(cur, alice, carol, "Newer research brief", "Fresh 1-star after the skip.", "research", 2000000)
	rate(cur, alice, idNew, 1, "Weak follow-up")

	_, live, _, _ := ScoreOf(carol)
	refreshScore(cur, bob, carol) // anyone may refresh
	cached := scores.Get(carol.String()).(*AgentScore)
	uassert.Equal(t, live, cached.TrustMilli)
	uassert.True(t, live >= 2300 && live <= 2400)
}

func TestSockPuppetBarelyMovesScore(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	// Trusted 4.00 from three 2 GNOT jobs, then a 1 ugnot 1-star smear.
	for i := 0; i < 3; i++ {
		id := settleJob(cur, alice, carol, "Baseline job "+strconv.Itoa(i+1), "A 2 GNOT research brief for the baseline.", "research", 2000000)
		rate(cur, alice, id, 4, "Baseline")
	}
	_, before, _, prov := ScoreOf(carol)
	uassert.Equal(t, int64(4000), before)
	uassert.False(t, prov)

	idSock := settleJob(cur, dave, carol, "Sock puppet job", "A 1 ugnot smear that should barely move the score.", "research", 1)
	rate(cur, dave, idSock, 1, "Smear")
	count, after, raw, stillTrusted := ScoreOf(carol)
	uassert.Equal(t, 4, count)
	uassert.False(t, stillTrusted)
	uassert.True(t, raw < 4000, "raw average should dip")
	// Trust must stay very close to 4.00 — well above 3.90.
	uassert.True(t, after >= 3900 && after <= 4000, "1 ugnot smear should barely move 4.00, got "+fmtScore(after))
}

func TestFiveStarClimbsLeaderboard(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	register(cur, bob, "Code Agent", "code, review", RateFlat, 2000000)
	register(cur, eve, "Writing Bot", "writing", RateFlat, 1500000)
	register(cur, frank, "Data Agent", "data, research", RateHourly, 800000)

	for i := 0; i < 3; i++ {
		id := settleJob(cur, alice, carol, "Baseline job "+strconv.Itoa(i+1), "A 2 GNOT research brief for the baseline.", "research", 2000000)
		rate(cur, alice, id, 4, "Baseline")
	}
	board := Render("leaderboard")
	uassert.True(t, strings.Contains(board, "Research Bot"))
	uassert.True(t, indexOf(board, "Research Bot") < indexOf(board, "Code Agent") || !strings.Contains(board, "Code Agent"))

	id := settleJob(cur, alice, bob, "Review a realm", "Review an escrow realm and write up the findings.", "review", 3000000)
	rate(cur, alice, id, 5, "Outstanding")

	_, bobTrust, _, bobProv := ScoreOf(bob)
	_, carolTrust, _, carolProv := ScoreOf(carol)
	uassert.Equal(t, int64(5000), bobTrust)
	uassert.True(t, bobProv, "one job stays provisional")
	uassert.Equal(t, int64(4000), carolTrust)
	uassert.False(t, carolProv)
	uassert.True(t, bobTrust > carolTrust)

	board = Render("leaderboard")
	uassert.True(t, indexOf(board, "Code Agent") < indexOf(board, "Research Bot"), "5-star agent should rank above the trusted 4.00")
	uassert.True(t, strings.Contains(board, "provisional"))
	uassert.True(t, strings.Contains(board, "trusted"))
}

func TestScoreOfAndSummaryLookup(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	id := settleJob(cur, alice, carol, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 2000000)
	rate(cur, alice, id, 5, "Nice")
	count, trust, raw, prov := ScoreOf(carol)
	uassert.Equal(t, 1, count)
	uassert.Equal(t, int64(5000), trust)
	uassert.Equal(t, int64(5000), raw)
	uassert.True(t, prov)
	sum := ReputationSummary(carol)
	uassert.True(t, strings.Contains(sum, "5.00"))
	uassert.True(t, strings.Contains(sum, "provisional"))
	uassert.True(t, strings.Contains(sum, "1 job"))
}

func TestDecayPPM(t *testing.T) {
	half := time.Duration(halfLifeDays) * 24 * time.Hour
	uassert.Equal(t, int64(decayScale), decayPPM(0))
	uassert.Equal(t, int64(decayScale), decayPPM(-time.Hour))
	uassert.Equal(t, int64(500000), decayPPM(half))
	uassert.Equal(t, int64(250000), decayPPM(2*half))
	uassert.Equal(t, int64(0), decayPPM(40*half))
	mid := decayPPM(half / 2)
	uassert.True(t, mid >= 700000 && mid <= 710000, "sqrt(1/2) is about 0.707, got "+strconv.Itoa(int(mid)))
}

func TestFmtScore(t *testing.T) {
	uassert.Equal(t, "0.00", fmtScore(0))
	uassert.Equal(t, "4.00", fmtScore(4000))
	uassert.Equal(t, "5.00", fmtScore(5000))
	uassert.Equal(t, "2.33", fmtScore(2333))
	uassert.Equal(t, "1.80", fmtScore(1800))
}

func TestPosterStatsRecordedOnSettle(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	register(cur, bob, "Code Agent", "code, review", RateFlat, 1000000)
	settleJob(cur, alice, carol, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 2000000)
	settleJob(cur, alice, bob, "Review a realm", "Look over an escrow realm for footguns please.", "review", 3000000)
	ps := posterStats.Get(alice.String()).(*PosterStats)
	uassert.Equal(t, 2, ps.SettledJobs)
	uassert.Equal(t, int64(5000000), ps.SettledUgnot)
	uassert.Equal(t, 2, ps.DistinctAgents)
	uassert.True(t, currentReviewerWeight(alice) > weightUnit)
}

func indexOf(s, sub string) int {
	i := strings.Index(s, sub)
	if i < 0 {
		return 1 << 30
	}
	return i
}
