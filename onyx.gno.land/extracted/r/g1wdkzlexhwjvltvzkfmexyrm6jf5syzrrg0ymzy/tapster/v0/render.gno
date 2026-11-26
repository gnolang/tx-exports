package tapster

import (
	"encoding/base64"
	"strings"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapmath/v0"
)

// Render serves the realm's pages on gnoweb:
//
//	(empty)            all feeds
//	feed/<PAIR>        one feed: chart, last round, parameters
//	reporters          reporter leaderboard
//	activity           joins, slashes, funding
//	integrate          how to read Tapster prices from your realm
//	json               all feeds as JSON
//	json/<PAIR>        one feed with history as JSON
func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case path == "":
		return renderHome()
	case parts[0] == "feed" && len(parts) == 2:
		return renderFeed(parts[1])
	case parts[0] == "reporters":
		return renderReporters()
	case parts[0] == "activity":
		return renderActivity()
	case parts[0] == "integrate":
		return renderIntegrate()
	case parts[0] == "json" && len(parts) == 2 && parts[1] == "reporters":
		return renderJSONReporters()
	case parts[0] == "json" && len(parts) == 1:
		return renderJSONAll()
	case parts[0] == "json" && len(parts) == 2:
		return renderJSONFeed(parts[1])
	}
	return "# 404\n\nPage not found. [Back to Tapster](" + home() + ")"
}

func home() string { return realmPath() }

func realmPath() string {
	// txlink gives "/r/<ns>/tapster/v0$help&func=X"; keep the part before "$".
	l := txlink.Call("Stake")
	if i := strings.Index(l, "$"); i >= 0 {
		return l[:i]
	}
	return l
}

func link(sub string) string { return realmPath() + ":" + sub }

func nav() string {
	return "[Feeds](" + home() + ") · [Reporters](" + link("reporters") + ") · [Activity](" + link("activity") + ") · [Integrate](" + link("integrate") + ")\n\n"
}

func age(at int64) string {
	if at == 0 {
		return "never"
	}
	d := now() - at
	switch {
	case d < 0:
		return "just now"
	case d < 120:
		return ufmt.Sprintf("%ds ago", d)
	case d < 7200:
		return ufmt.Sprintf("%dm ago", d/60)
	case d < 172800:
		return ufmt.Sprintf("%dh ago", d/3600)
	}
	return ufmt.Sprintf("%dd ago", d/86400)
}

func displayPrice(f *Feed, p int64) string {
	keep := 2
	if p < tapmath.Pow10(f.Decimals) { // below 1.00: show all decimals
		keep = f.Decimals
	}
	return "$" + commas(tapmath.FormatRounded(p, f.Decimals, keep))
}

// commas adds thousands separators to the integer part of a decimal string.
func commas(s string) string {
	intPart, frac := s, ""
	if i := strings.Index(s, "."); i >= 0 {
		intPart, frac = s[:i], s[i:]
	}
	if len(intPart) <= 3 {
		return s
	}
	var out []byte
	for i := 0; i < len(intPart); i++ {
		if i > 0 && (len(intPart)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, intPart[i])
	}
	return string(out) + frac
}

func totals() (n int, active int, staked int64) {
	reporters.Iterate("", "", func(_ string, v any) bool {
		r := v.(*Reporter)
		n++
		staked += r.Stake
		if r.ExitAt == 0 && r.Stake >= minStake {
			active++
		}
		return false
	})
	return
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 🍺 Tapster\n\n")
	b.WriteString("**Price feeds on tap for gno.land.** Reporters stake GNOT and submit prices every round. ")
	b.WriteString("The answer is the stake-weighted median; reporters near it earn rewards, and reporters far from it lose part of their stake. ")
	b.WriteString("Any realm can read these prices for free.\n\n")
	b.WriteString(nav())

	n, active, staked := totals()
	b.WriteString(ufmt.Sprintf("**%d** active reporters (%d total) · **%s** staked · **%s** slashed · **%s** paid in rewards\n\n",
		active, n, gnot(staked), gnot(totalSlashed), gnot(totalRewards)))

	b.WriteString("| Feed | Price | Updated | Reports | Spread | Reward pool | Trend |\n")
	b.WriteString("|---|---|---|---|---|---|---|\n")
	feeds.Iterate("", "", func(_ string, v any) bool {
		f := v.(*Feed)
		price, upd, reps, spread := "—", "never", "—", "—"
		if f.hasAnswer {
			price = "**" + displayPrice(f, f.latest.Price) + "**"
			upd = age(f.latest.At)
			reps = ufmt.Sprintf("%d", f.latest.Reports)
			spread = bpsPct(f.latest.Spread)
		}
		if f.Paused {
			upd += " (paused)"
		}
		b.WriteString(ufmt.Sprintf("| [%s](%s) | %s | %s | %s | %s | %s | %s |\n",
			f.Pair, link("feed/"+f.Pair), price, upd, reps, spread, gnot(f.Pool), sparkline(f)))
		return false
	})

	b.WriteString("\n## Become a reporter\n\n")
	b.WriteString(ufmt.Sprintf("Stake at least %s, then submit prices with `Submit`. ", gnot(minStake)))
	b.WriteString("Run the open-source reporter bot to do it every round.\n\n")
	b.WriteString("[Stake 1 GNOT](" + txlink.NewLink("Stake").AddArgs("name", "").SetSend("1000000ugnot").URL() + ")")
	b.WriteString(" · [Submit a price](" + txlink.Call("Submit") + ")")
	b.WriteString(" · [Claim rewards](" + txlink.Call("ClaimRewards") + ")\n\n")
	b.WriteString("## Used by\n\n")
	if consumers.Size() == 0 {
		b.WriteString("No realms registered yet. Call `RegisterConsumer` from your realm to be listed.\n\n")
	} else {
		consumers.Iterate("", "", func(k string, v any) bool {
			c := v.(*Consumer)
			b.WriteString("- [" + c.Path + "](/" + strings.TrimPrefix(c.Path, "gno.land/") + ") · " + c.Note + " · since " + age(c.Since) + "\n")
			return false
		})
		b.WriteString("\n")
	}
	b.WriteString("## Use the prices\n\n")
	b.WriteString("```go\nprice, dec, ok := tapster.PriceFresh(\"GNOT-USD\", 600)\n```\n\n")
	b.WriteString("See [Integrate](" + link("integrate") + ").\n")
	return b.String()
}

func renderFeed(pair string) string {
	v := feeds.Get(pair)
	if v == nil {
		return "# Unknown feed\n\n[Back](" + home() + ")"
	}
	f := v.(*Feed)
	var b strings.Builder
	b.WriteString("# " + f.Pair + "\n\n")
	b.WriteString(f.Description + "\n\n")
	b.WriteString(nav())
	if f.hasAnswer {
		b.WriteString(ufmt.Sprintf("## %s\n\nUpdated %s · round %d · %d reports · spread %s\n\n",
			displayPrice(f, f.latest.Price), age(f.latest.At), f.latest.Round, f.latest.Reports, bpsPct(f.latest.Spread)))
		b.WriteString(chart(f, 640, 220) + "\n\n")
	} else {
		b.WriteString("No answer yet: waiting for reporters.\n\n")
	}

	b.WriteString("### Open round\n\n")
	if f.current == nil {
		b.WriteString("No reports yet this round.\n\n")
	} else {
		closes := (f.current.ID+1)*f.RoundSecs - now()
		if closes < 0 {
			b.WriteString(ufmt.Sprintf("Round %d has ended with %d reports and will close on the next submit. [Finalize now](%s)\n\n",
				f.current.ID, len(f.current.Reports), txlink.NewLink("Finalize").AddArgs("pair", f.Pair).URL()))
		} else {
			b.WriteString(ufmt.Sprintf("Round %d: %d reports so far, closes in %ds (needs %d).\n\n",
				f.current.ID, len(f.current.Reports), closes, f.MinReports))
		}
	}

	if len(f.lastReports) > 0 {
		b.WriteString("### Last closed round\n\n| Reporter | Price | Stake weight | Off by | Outcome |\n|---|---|---|---|---|\n")
		for _, r := range f.lastReports {
			b.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s |\n",
				displayName(r.Reporter), displayPrice(f, r.Price), gnot(r.Weight), bpsPct(r.DevBps), outcomeBadge(r.Outcome)))
		}
		b.WriteString("\n")
	}

	slashes := 0
	for i := len(events) - 1; i >= 0 && slashes < 5; i-- {
		e := events[i]
		if e.Kind == "slash" && strings.Contains(e.Text, " on "+f.Pair+":") {
			if slashes == 0 {
				b.WriteString("### Recent slashes\n\n")
			}
			b.WriteString("- " + age(e.At) + " · " + e.Text + "\n")
			slashes++
		}
	}
	if slashes > 0 {
		b.WriteString("\n")
	}

	b.WriteString("### Parameters\n\n")
	b.WriteString(ufmt.Sprintf("| Setting | Value |\n|---|---|\n| Decimals | %d |\n| Round length | %ds |\n| Reports needed | %d |\n| Accurate within | %s (earns %s) |\n| Outlier beyond | %s (loses %s of stake) |\n| Reward pool | %s |\n| Rounds without quorum | %d |\n\n",
		f.Decimals, f.RoundSecs, f.MinReports, bpsPct(f.ToleranceBps), gnot(f.RewardPerReport),
		bpsPct(f.OutlierBps), bpsPct(f.SlashBps), gnot(f.Pool), f.roundsMissed))
	b.WriteString("[Fund this feed with 5 GNOT](" + txlink.NewLink("Fund").AddArgs("pair", f.Pair).SetSend("5000000ugnot").URL() + ")")
	b.WriteString(" · [Submit a price](" + txlink.NewLink("Submit").AddArgs("pair", f.Pair).URL() + ")")
	b.WriteString(" · [JSON](" + link("json/"+f.Pair) + ")\n")
	return b.String()
}

func outcomeBadge(o string) string {
	switch o {
	case OutcomeAccurate:
		return "✅ accurate"
	case OutcomeOutlier:
		return "🔪 slashed"
	case OutcomeNeutral:
		return "➖ neutral"
	case OutcomeNoQuorum:
		return "⏳ no quorum"
	}
	return o
}

func renderReporters() string {
	var b strings.Builder
	b.WriteString("# Reporters\n\n")
	b.WriteString(nav())
	// Collect and sort by stake, highest first (insertion sort, small n).
	var list []*Reporter
	reporters.Iterate("", "", func(_ string, v any) bool {
		list = append(list, v.(*Reporter))
		return false
	})
	for i := 1; i < len(list); i++ {
		r := list[i]
		j := i - 1
		for j >= 0 && list[j].Stake < r.Stake {
			list[j+1] = list[j]
			j--
		}
		list[j+1] = r
	}
	b.WriteString("| # | Reporter | Stake | Accurate | Slashed | Earned | Status |\n|---|---|---|---|---|---|---|\n")
	for i, r := range list {
		status := "🟢 active"
		switch {
		case r.ExitAt != 0 && now() >= r.ExitAt:
			status = "can withdraw"
		case r.ExitAt != 0:
			status = "unbonding"
		case r.Stake < minStake:
			status = "🔴 under-staked"
		}
		name := r.Name
		if name == "" {
			name = shortAddr(r.Addr)
		}
		slashed := "—"
		if r.Outliers > 0 {
			slashed = ufmt.Sprintf("%s (%dx)", gnot(r.Slashed), r.Outliers)
		}
		b.WriteString(ufmt.Sprintf("| %d | **%s** `%s` | %s | %d/%d | %s | %s | %s |\n",
			i+1, name, shortAddr(r.Addr), gnot(r.Stake), r.Accurate, r.Reports, slashed, gnot(r.Earned), status))
	}
	if len(list) == 0 {
		b.WriteString("| | No reporters yet | | | | | |\n")
	}
	b.WriteString("\n[Stake 1 GNOT and join](" + txlink.NewLink("Stake").AddArgs("name", "").SetSend("1000000ugnot").URL() + ")")
	b.WriteString(" · [Request exit](" + txlink.Call("RequestExit") + ") · [Withdraw](" + txlink.Call("Withdraw") + ")\n")
	return b.String()
}

func renderActivity() string {
	var b strings.Builder
	b.WriteString("# Activity\n\n")
	b.WriteString(nav())
	if len(events) == 0 {
		b.WriteString("Nothing yet.\n")
		return b.String()
	}
	for i := len(events) - 1; i >= 0 && i >= len(events)-50; i-- {
		e := events[i]
		b.WriteString(ufmt.Sprintf("- %s · %s\n", age(e.At), e.Text))
	}
	return b.String()
}

func renderIntegrate() string {
	p := strings.TrimPrefix(realmPath(), "/")
	var b strings.Builder
	b.WriteString("# Integrate Tapster\n\n")
	b.WriteString(nav())
	b.WriteString("Reads are free and need no setup. Import the realm and ask for a fresh price:\n\n")
	b.WriteString("```go\nimport (\n\t\"gno.land/" + p + "\"\n\t\"gno.land/p/" + nsFrom(p) + "/tapmath/v0\"\n)\n\n")
	b.WriteString("func Pay(cur realm, usdCents int64) {\n")
	b.WriteString("\t// Refuse to price money on data older than 10 minutes.\n")
	b.WriteString("\tprice, dec := tapster.MustPriceFresh(\"GNOT-USD\", 600)\n")
	b.WriteString("\tdue := tapmath.UsdCentsToUgnot(usdCents, price, dec) // rounds up\n")
	b.WriteString("\t// ...\n}\n```\n\n")
	b.WriteString("| Function | Returns |\n|---|---|\n")
	b.WriteString("| `Latest(pair)` | price, decimals, updatedAt, round, ok |\n")
	b.WriteString("| `PriceFresh(pair, maxAgeSecs)` | price, decimals, ok (false when stale) |\n")
	b.WriteString("| `MustPriceFresh(pair, maxAgeSecs)` | price, decimals (panics when stale) |\n")
	b.WriteString("| `History(pair, n)` | `unix:price` list |\n")
	b.WriteString("| `Pairs()` | feed names |\n\n")
	b.WriteString("Feeds: " + Pairs() + "\n\n")
	b.WriteString("Off-chain clients can read [`:json`](" + link("json") + ") or call `vm/qeval` with `Latest(\"GNOT-USD\")`.\n")
	return b.String()
}

func nsFrom(p string) string {
	// p = "r/<ns>/tapster/v0"
	segs := strings.Split(p, "/")
	if len(segs) >= 2 {
		return segs[1]
	}
	return "<ns>"
}

func renderJSONAll() string {
	var items []string
	feeds.Iterate("", "", func(_ string, v any) bool {
		items = append(items, feedJSON(v.(*Feed), false))
		return false
	})
	return "{\"feeds\":[" + strings.Join(items, ",") + "]}"
}

func renderJSONFeed(pair string) string {
	v := feeds.Get(pair)
	if v == nil {
		return "{\"error\":\"unknown feed\"}"
	}
	return feedJSON(v.(*Feed), true)
}

func feedJSON(f *Feed, withHistory bool) string {
	s := ufmt.Sprintf("{\"pair\":\"%s\",\"decimals\":%d,\"price\":%d,\"updatedAt\":%d,\"round\":%d,\"reports\":%d,\"spreadBps\":%d,\"pool\":%d,\"roundSecs\":%d,\"minReports\":%d,\"paused\":%t,\"hasAnswer\":%t",
		f.Pair, f.Decimals, f.latest.Price, f.latest.At, f.latest.Round, f.latest.Reports, f.latest.Spread, f.Pool, f.RoundSecs, f.MinReports, f.Paused, f.hasAnswer)
	if withHistory {
		h := make([]string, len(f.history))
		for i, a := range f.history {
			h[i] = ufmt.Sprintf("[%d,%d]", a.At, a.Price)
		}
		s += ",\"history\":[" + strings.Join(h, ",") + "]"
		rs := make([]string, len(f.lastReports))
		for i, r := range f.lastReports {
			rs[i] = ufmt.Sprintf("{\"reporter\":\"%s\",\"name\":\"%s\",\"price\":%d,\"weight\":%d,\"devBps\":%d,\"outcome\":\"%s\"}",
				r.Reporter.String(), jsonEscape(displayName(r.Reporter)), r.Price, r.Weight, r.DevBps, r.Outcome)
		}
		s += ",\"lastRound\":[" + strings.Join(rs, ",") + "]"
	}
	return s + "}"
}

func jsonEscape(s string) string {
	// Names are restricted to safe characters by cleanName; escape quotes
	// and backslashes anyway.
	s = strings.ReplaceAll(s, "\\", "\\\\")
	return strings.ReplaceAll(s, "\"", "\\\"")
}

// ----------------------------------------------------------------------
// SVG charts (rendered by the realm itself)

func scalePoints(h []Answer, w, ht, pad int) (string, int64, int64) {
	lo, hi := h[0].Price, h[0].Price
	for _, a := range h {
		if a.Price < lo {
			lo = a.Price
		}
		if a.Price > hi {
			hi = a.Price
		}
	}
	span := hi - lo
	if span == 0 {
		span = 1
	}
	var pts []string
	n := len(h)
	for i, a := range h {
		x := pad
		if n > 1 {
			x = pad + i*(w-2*pad)/(n-1)
		}
		y := ht - pad - int((a.Price-lo)*int64(ht-2*pad)/span)
		pts = append(pts, ufmt.Sprintf("%d,%d", x, y))
	}
	return strings.Join(pts, " "), lo, hi
}

func svgImage(alt, svg string) string {
	return "![" + alt + "](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg)) + ")"
}

func sparkline(f *Feed) string {
	h := f.history
	if len(h) > 40 {
		h = h[len(h)-40:]
	}
	if len(h) < 2 {
		return "—"
	}
	pts, _, _ := scalePoints(h, 120, 28, 3)
	color := "#16a34a"
	if h[len(h)-1].Price < h[0].Price {
		color = "#dc2626"
	}
	svg := `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="28" viewBox="0 0 120 28"><polyline points="` + pts + `" fill="none" stroke="` + color + `" stroke-width="2" stroke-linejoin="round"/></svg>`
	return svgImage(f.Pair+" trend", svg)
}

func chart(f *Feed, w, ht int) string {
	h := f.history
	if len(h) < 2 {
		return "_The chart appears after two answers._"
	}
	pad := 24
	pts, lo, hi := scalePoints(h, w, ht, pad)
	color := "#16a34a"
	if h[len(h)-1].Price < h[0].Price {
		color = "#dc2626"
	}
	area := ufmt.Sprintf("%d,%d %s %d,%d", pad, ht-pad, pts, w-pad, ht-pad)
	var s strings.Builder
	s.WriteString(ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="sans-serif" font-size="11">`, w, ht, w, ht))
	s.WriteString(ufmt.Sprintf(`<rect width="%d" height="%d" fill="#fffbeb" rx="8"/>`, w, ht))
	s.WriteString(`<polygon points="` + area + `" fill="` + color + `" opacity="0.12"/>`)
	s.WriteString(`<polyline points="` + pts + `" fill="none" stroke="` + color + `" stroke-width="2.5" stroke-linejoin="round"/>`)
	s.WriteString(ufmt.Sprintf(`<text x="%d" y="16" fill="#78350f">high %s</text>`, pad, displayPrice(f, hi)))
	s.WriteString(ufmt.Sprintf(`<text x="%d" y="%d" fill="#78350f">low %s</text>`, pad, ht-6, displayPrice(f, lo)))
	s.WriteString(ufmt.Sprintf(`<text x="%d" y="16" fill="#78350f" text-anchor="end">last %d rounds</text>`, w-pad, len(h)))
	s.WriteString(`</svg>`)
	return svgImage(f.Pair+" price chart", s.String())
}

func renderJSONReporters() string {
	var items []string
	reporters.Iterate("", "", func(_ string, v any) bool {
		r := v.(*Reporter)
		items = append(items, ufmt.Sprintf("{\"address\":\"%s\",\"name\":\"%s\",\"stake\":%d,\"rewards\":%d,\"earned\":%d,\"reports\":%d,\"accurate\":%d,\"outliers\":%d,\"slashed\":%d,\"exitAt\":%d,\"active\":%t}",
			r.Addr.String(), jsonEscape(r.Name), r.Stake, r.Rewards, r.Earned, r.Reports, r.Accurate, r.Outliers, r.Slashed, r.ExitAt, r.ExitAt == 0 && r.Stake >= minStake))
		return false
	})
	var ev []string
	for i := len(events) - 1; i >= 0 && i >= len(events)-30; i-- {
		e := events[i]
		ev = append(ev, ufmt.Sprintf("{\"at\":%d,\"kind\":\"%s\",\"text\":\"%s\"}", e.At, e.Kind, jsonEscape(e.Text)))
	}
	return ufmt.Sprintf("{\"minStake\":%d,\"totalSlashed\":%d,\"totalRewards\":%d,\"consumers\":\"%s\",\"reporters\":[%s],\"events\":[%s]}",
		minStake, totalSlashed, totalRewards, Consumers(), strings.Join(items, ","), strings.Join(ev, ","))
}
