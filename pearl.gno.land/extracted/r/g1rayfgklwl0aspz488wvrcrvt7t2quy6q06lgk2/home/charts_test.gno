package home

import (
	"encoding/base64"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestParseActivity(t *testing.T) {
	a := parseActivity("title reviews; series gnolang/gno,Peer Dev; scale Peer Dev,10,commits; scale bad\n" +
		"2025-12 3 21; 2026-01 0 0; bad; 2026-13 1 1; 2026-02 x 1; 2026-02 5; 2026-02 5 2")
	uassert.Equal(t, "reviews", a.noun)
	uassert.Equal(t, "Peer Dev", a.scaled)
	uassert.Equal(t, 10, a.scaleDiv)
	uassert.Equal(t, "commits", a.scaleUnit)
	uassert.Equal(t, 3, len(a.months))
	uassert.Equal(t, "Dec 25", a.months[0].label)
	uassert.Equal(t, 21, a.months[0].counts[1])
	uassert.Equal(t, 3, a.drawn(1, 21)) // rounded up
	uassert.Equal(t, 3, a.drawn(0, 3))  // an unscaled series draws its count
	uassert.Equal(t, "Jan 26", a.months[1].label)
	uassert.Equal(t, "Feb", a.months[2].label)
	uassert.Equal(t, 2, a.months[2].counts[1])

	b := parseActivity("title x; series a; outline opened; updated 2026-09-24; " +
		"2026-01 1 | 8; 2026-02 2 |; 2026-03 3 | y; 2026-04 4")
	uassert.Equal(t, "opened", b.outline)
	uassert.Equal(t, "24 Sep 2026", b.updated)
	uassert.Equal(t, 2, len(b.months)) // "|" with no count and a non-number are rejected
	uassert.Equal(t, 8, b.months[0].outline)
	uassert.Equal(t, 0, b.months[1].outline)
	uassert.Equal(t, "", formatDay("2026-13-01"))
}

func TestFillKeepsRepoColour(t *testing.T) {
	// gnodaokit keeps its colour wherever it sits in a chart's series.
	a := activity{series: []string{"gnolang/gno", "gnodaokit"}}
	b := activity{series: []string{"gnodaokit"}}
	uassert.Equal(t, repoFills["gnodaokit"], a.fill(1))
	uassert.Equal(t, repoFills["gnodaokit"], b.fill(0))
	c := activity{series: []string{"unlisted-repo", "Others"}}
	uassert.Equal(t, c.fill(0), c.fill(0))
	uassert.Equal(t, othersFill, c.fill(1))
}

func decodeChart(t *testing.T, out, alt string) string {
	prefix := "![" + alt + "](data:image/svg+xml;base64,"
	uassert.True(t, strings.HasPrefix(out, prefix), "prefix of "+alt)
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSuffix(out[len(prefix):], ")\n"))
	uassert.NoError(t, err)
	return string(raw)
}

func TestCharts(t *testing.T) {
	prs := decodeChart(t, renderChart(activitySlot), "Merged pull requests per month, by repository")
	for _, want := range []string{
		">104 merged pull requests</text>", ">gnolang/gno 70</text>", ">gnodaokit 6</text>",
		">Others 17</text>", ">Peer Dev 234 commits, drawn 1 per 10</text>", ">May 25</text>",
		">Jan 26</text>", ">23</text>", // June 2026: 16 + 6 + 1
		">5</text>", // July 2025 counts its 5 pull requests and not its 48 commits
	} {
		uassert.True(t, strings.Contains(prs, want), "pull requests chart: "+want)
	}
	// One amber bar per month with Peer Dev commits, May to November 2025, plus the legend's.
	uassert.Equal(t, 8, strings.Count(prs, `fill="#fbbf24"`))
	// One striped bar per month with opened pull requests, plus the legend's.
	uassert.Equal(t, 15, strings.Count(prs, `fill="url(#o)"`))
	uassert.True(t, strings.Contains(prs, ">gnolang/gno pull requests opened 131</text>"))
	uassert.True(t, strings.Contains(prs, ">updated 24 Sep 2026</text>"))

	revs := decodeChart(t, renderChart(reviewActivitySlot), "Reviews per month, by repository")
	for _, want := range []string{">404 reviews</text>", ">gnolang/gno 357</text>", ">Others 47</text>", ">per month, on the same repositories</text>"} {
		uassert.True(t, strings.Contains(revs, want), "reviews chart: "+want)
	}
	uassert.False(t, strings.Contains(revs, "#fbbf24"))
	uassert.False(t, strings.Contains(revs, ">gnolove"))
	uassert.False(t, strings.Contains(revs, `fill="url(#o)"`))
	uassert.True(t, strings.Contains(revs, ">updated 24 Sep 2026</text>"))

	page := Render("")
	uassert.True(t, strings.Index(page, "Merged pull requests per month") < strings.Index(page, "Reviews per month"))
}

func TestChartEmpty(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	old := Get(activitySlot)
	Set(cross(cur), activitySlot, "")
	uassert.Equal(t, "", renderChart(activitySlot))
	Set(cross(cur), activitySlot, old)
	uassert.AbortsWithMessage(t, cur, "reserved section: banner", func() { Set(cross(cur), "banner", "x") })
	uassert.AbortsWithMessage(t, cur, "reserved section: reviews", func() { Set(cross(cur), "reviews", "x") })
	uassert.AbortsWithMessage(t, cur, "reserved section: hero", func() { Set(cross(cur), "hero", "x") })
	uassert.AbortsWithMessage(t, cur, "reserved section: areachart", func() { Set(cross(cur), "areachart", "x") })
}

func TestAreas(t *testing.T) {
	noun, subtitle, updated, slices := parseAreas("title x; subtitle y; updated 2026-09-24; slice 3 Docs; slice 0 Empty; slice y Bad; slice 2 Chain: tm2, consensus")
	uassert.Equal(t, "x", noun)
	uassert.Equal(t, "y", subtitle)
	uassert.Equal(t, "24 Sep 2026", updated)
	uassert.Equal(t, 2, len(slices))
	uassert.Equal(t, "Chain: tm2, consensus", slices[1].label)

	ring := decodeChart(t, renderAreas(), "Pull requests by area, merged into gnolang/gno")
	for _, want := range []string{">70</text>", ">Pull requests by area</text>", ">merged into gnolang/gno</text>", ">Docs</text>", ">26</text>", ">37%</text>", ">updated 24 Sep 2026</text>"} {
		uassert.True(t, strings.Contains(ring, want), "area ring: "+want)
	}
	// The shares add up to the whole ring, the last one taking the rounding.
	uassert.True(t, strings.Contains(ring, `stroke-dasharray="371 1000" stroke-dashoffset="0"`))
	uassert.True(t, strings.Contains(ring, `stroke-dashoffset="-941"`))
	uassert.True(t, strings.Contains(ring, `stroke-dasharray="59 1000"`))
}

func TestHeartsWall(cur realm, t *testing.T) {
	hearts = avl.NewTree()
	wall := decodeChart(t, renderHeartsWall(), "0 hearts")
	uassert.Equal(t, wallCols, strings.Count(wall, `<use href="#h"`))
	uassert.Equal(t, 0, strings.Count(wall, `fill="#e63946"`))
	for i := 0; i < 25; i++ {
		hearts.Set(testutils.TestAddress("fan"+strconv.Itoa(i)).String(), int64(i))
	}
	wall = decodeChart(t, renderHeartsWall(), "25 hearts")
	uassert.Equal(t, 2*wallCols, strings.Count(wall, `<use href="#h"`))
	uassert.Equal(t, 25, strings.Count(wall, `fill="#e63946"`))
	uassert.False(t, strings.Contains(wall, "more</text>"))
	for i := 25; i < 250; i++ {
		hearts.Set(testutils.TestAddress("fan"+strconv.Itoa(i)).String(), int64(i))
	}
	wall = decodeChart(t, renderHeartsWall(), "250 hearts")
	uassert.Equal(t, wallCols*wallMaxRows, strings.Count(wall, `fill="#e63946"`))
	uassert.True(t, strings.Contains(wall, ">and 10 more</text>"))
	uassert.True(t, strings.Contains(wall, `<text x="348" y="316" text-anchor="middle" fill="#9fc9b4" style="font:13px sans-serif">and 10 more</text>`))
	hearts = avl.NewTree()
}
