package bouncer

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const goodStats = "ranked=100;active=412;scanned=98;unavailable=2;files=640;with_findings=9;with_proven=2;critical_or_high=4;" +
	"mean_score_x10=962;grade.A=91;grade.B=5;grade.C=1;grade.D=1;grade.F=0;verdict.clear=94;verdict.review=2;verdict.not-recommended=2;" +
	"rule.B01=3/4/2;rule.B03=0/0/0;rule.B04=6/9/0"

func TestPublishCensus(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	uassert.True(t, strings.Contains(Render("census"), "No census published yet."))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "attester only", func() {
		PublishCensus(cross(cur), "gnoland-1", hash("b"), 100, 200, 1, 2, goodStats)
	})
	testing.SetRealm(testing.NewUserRealm(botAddr))
	PublishCensus(cross(cur), "gnoland-1", hash("b"), 1065048, 1801844, 1761350400, 1764028800, goodStats)
	c, ok := LatestCensus()
	urequire.True(t, ok)
	uassert.Equal(t, 98, c.Scanned)
	uassert.Equal(t, 3, len(c.Rules))
	uassert.Equal(t, 2, c.Rules[0].Proven)

	page := Render("census")
	uassert.True(t, strings.Contains(page, "the 100 most active realms on `gnoland-1`"))
	uassert.True(t, strings.Contains(page, "| With a PROVEN finding | 2 |"))
	uassert.True(t, strings.Contains(page, "Mean score: **96.2** / 100 over 640 files. 2 ranked realms could not be fetched or parsed."))
	uassert.True(t, strings.Contains(page, ":wanted/B01) | 3 | 4 | 2 |"))
	uassert.True(t, strings.Contains(Render(""), "4 have a Critical or High finding. [Aggregate numbers]"))
}

func TestPublishCensusRejectsBadStats(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	bad := map[string]string{
		"unknown census key: name":                       strings.Replace(goodStats, "ranked=100", "name=1", 1),
		"census entry must be key=value: gno.land/r/x/y": goodStats + ";gno.land/r/x/y",
		"duplicate census key: files":                    goodStats + ";files=1",
		"missing census key: files":                      strings.Replace(goodStats, "files=640;", "", 1),
		"invalid census number: -1":                      strings.Replace(goodStats, "files=640", "files=-1", 1),
		"census totals do not add up: grades and verdicts must each sum to scanned": strings.Replace(goodStats, "grade.A=91", "grade.A=90", 1),
		"census totals do not add up: ranked, scanned, unavailable, active":         strings.Replace(goodStats, "unavailable=2", "unavailable=3", 1),
		"census totals do not add up: realms with findings":                         strings.Replace(goodStats, "with_proven=2", "with_proven=10", 1),
		"inconsistent rule entry: rule.B01=5/4/2":                                   strings.Replace(goodStats, "rule.B01=3/4/2", "rule.B01=5/4/2", 1),
		"invalid rule id: gno.land/r/x":                                             goodStats + ";rule.gno.land/r/x=1/1/0",
	}
	for msg, stats := range bad {
		testing.SetRealm(testing.NewUserRealm(botAddr))
		uassert.AbortsWithMessage(t, cur, msg, func() {
			PublishCensus(cross(cur), "gnoland-1", hash("b"), 1, 2, 1, 2, stats)
		})
	}
	testing.SetRealm(testing.NewUserRealm(botAddr))
	uassert.AbortsWithMessage(t, cur, "invalid window", func() {
		PublishCensus(cross(cur), "gnoland-1", hash("b"), 5, 5, 1, 2, goodStats)
	})
	_, ok := LatestCensus()
	uassert.False(t, ok)
}
