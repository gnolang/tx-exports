package idlewatt

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestFormatting(t *testing.T) {
	uassert.Equal(t, "$0.00", fmtUSD(0))
	uassert.Equal(t, "$0.05", fmtUSD(5))
	uassert.Equal(t, "$1.50", fmtUSD(150))
	uassert.Equal(t, "$1,234.56", fmtUSD(123456))
	uassert.Equal(t, "$1,000,000.00", fmtUSD(100000000))
	uassert.Equal(t, "-$2.00", fmtUSD(-200))
	uassert.Equal(t, "000000042", padID(42))
	uassert.True(t, rankKey(500, 1) < rankKey(100, 1), "higher totals sort first")
	uassert.True(t, rankKey(100, 1) < rankKey(100, 2), "ties go to the older node")
	uassert.Equal(t, 1, pageParam(""))
	uassert.Equal(t, 3, pageParam("page=3"))
	uassert.Equal(t, 1, pageParam("page=-1"))
	uassert.Equal(t, 1, pageParam("page=abc"))
}

func TestRenderEmpty(cur realm, t *testing.T) {
	reset()
	out := Render("")
	uassert.True(t, strings.Contains(out, "# <gno-icon name=\"lightning\" /> IdleWatt"))
	uassert.True(t, strings.Contains(out, "no Tesla or Akash integration"), "disclaimer is always shown")
	uassert.True(t, strings.Contains(out, "No nodes yet"))
	uassert.True(t, strings.Contains(out, "<gno-form exec=\"RegisterNode\">"))
}

func TestRenderPages(cur realm, t *testing.T) {
	reset()
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	truck := RegisterNode(cross(cur), "Tonawanda Cybertruck (simulated)", KindVehicle, "AI4 + AMD Ryzen", "US-NY Tonawanda", PowerPowershare, 30)
	gpu := registerGPU(cur, bob, "Garage RTX 4090", 45)
	bringOnline(cur, bob, gpu)
	who = bob
	testing.SetRealm(testing.NewUserRealm(who))
	RecordJob(cross(cur), gpu, "llama-3.3-70b inference", 120)
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	SetAvailability(cross(cur), truck, ModeDriving)

	home := Render("")
	for _, want := range []string{
		"Tonawanda Cybertruck (simulated)",
		"Garage RTX 4090",
		"<gno-columns>",
		"<gno-frame>",
		"Fairness pool",
		"1 out driving",
		"$0.90", // 120 min at 45c/h
		"Driving",
		"Online, available",
		"Split the pool now",
		"llama-3.3-70b inference",
	} {
		uassert.True(t, strings.Contains(home, want), "home page missing: "+want)
	}
	// Leaderboard puts the earner first.
	uassert.True(t, strings.Index(home, "🥇 | [Garage RTX 4090]") > 0, "gpu should rank first")

	page := Render("node/" + itoa(truck))
	uassert.True(t, strings.Contains(page, "# <gno-icon name=\"battery-charging\" /> Tonawanda Cybertruck (simulated)"))
	uassert.True(t, strings.Contains(page, "label=\"Driving\""), "vehicles get a driving button")
	uassert.True(t, strings.Contains(page, "$help&func=Heartbeat"), "action links open prefilled tx forms")
	uassert.True(t, strings.Contains(page, "No jobs yet"))

	gpage := Render("node/" + itoa(gpu))
	uassert.False(t, strings.Contains(gpage, "label=\"Driving\""), "no driving button for a GPU box")
	uassert.True(t, strings.Contains(gpage, "Rank: #1 of 2"))

	uassert.True(t, strings.Contains(Render("nodes"), "| 2 | [Garage RTX 4090]"))
	uassert.True(t, strings.Contains(Render("leaderboard"), "Garage RTX 4090"))
	uassert.True(t, strings.Contains(Render("jobs"), "Simulated"))
	uassert.True(t, strings.Contains(Render("about"), "Nakamoto Bonus"))
	uassert.True(t, strings.Contains(Render("operator/"+alice.String()), "Tonawanda Cybertruck"))
	uassert.True(t, strings.Contains(Render("operator/[evil](x)"), "(invalid address)"))
	uassert.True(t, strings.HasPrefix(Render("node/999"), "# Not found"))
	uassert.True(t, strings.HasPrefix(Render("node/abc"), "# Not found"))
	uassert.True(t, strings.HasPrefix(Render("nope"), "# Not found"))
}

func TestRenderPagination(cur realm, t *testing.T) {
	reset()
	ops := []address{alice, bob, carol}
	for i := 0; i < 25; i++ {
		registerGPU(cur, ops[i%3], "Node "+itoa(i+1), int64(10+i))
	}
	p1 := Render("nodes")
	uassert.True(t, strings.Contains(p1, "Page 1 of 3"))
	uassert.True(t, strings.Contains(p1, "[Next]"))
	p3 := Render("nodes?page=3")
	uassert.True(t, strings.Contains(p3, "| 25 | [Node 25]"))
	uassert.False(t, strings.Contains(p3, "| 1 | [Node 1]"))
	uassert.True(t, strings.Contains(Render(""), "See all 25 nodes"))
}

func itoa(i int) string {
	s := ""
	if i == 0 {
		return "0"
	}
	for i > 0 {
		s = string(rune('0'+i%10)) + s
		i /= 10
	}
	return s
}
