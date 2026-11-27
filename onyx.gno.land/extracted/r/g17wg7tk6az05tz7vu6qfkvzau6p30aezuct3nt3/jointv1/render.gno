package jointv1

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
	villagers "gno.land/r/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/villagersv1"
)

// Town-needs bands. Wide on purpose: a small price move must not flip the
// board. Grain and hops only. Render never stores a smoothed value.
const (
	bandSteady = 0
	bandScarce = 1
	bandPlenty = 2

	scarceBps = 13000
	plentyBps = 8000
	pageSize  = 10
)

// renderRoot is this realm's gnoweb path. Render builds links from it so a
// click stays inside the package. scripts/setns.sh rewrites the prefix.
const renderRoot = "/r/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/jointv1"

// Render is the gnoweb view of the town. It is not a crossing function and
// it only reads: no settle, no coins, no stored write. A path it does not
// know returns a short help page, never a panic and never an empty string.
func Render(path string) string {
	if strings.HasPrefix(path, "api/") {
		return renderAPI(path[len("api/"):])
	}
	base, page := parsePage(path)
	switch {
	case path == "" || path == "/":
		return renderHome()
	case path == "needs":
		return renderNeedsPage()
	case base == "market":
		return renderMarket(path, page)
	case strings.HasPrefix(path, "tavern/"):
		return renderBusiness(path[len("tavern/"):])
	case strings.HasPrefix(path, "business/"):
		return renderBusiness(path[len("business/"):])
	case strings.HasPrefix(path, "villager/"):
		return renderVillager(path[len("villager/"):])
	default:
		return renderHelp()
	}
}

func renderHelp() string {
	return "# The Joint\n\n" +
		"Pages: home, needs, market, market?page=N, tavern/<address>, business/<address>, villager/<id>.\n" +
		"JSON: api/town, api/tavern/<address>, api/villager/<id>, api/villagers/<offset>/<count>, api/crew/<address>, api/listings/<offset>/<count>, api/top, api/topfarms, api/season.\n"
}

func renderHome() string {
	h := CurrentGameHour()
	s := "# The Joint\n\n"
	s += ufmt.Sprintf("Day %d, hour %d. Today: %s.\n\n", h/24, h%24, eventKindName(EventOnDay(h/24).Kind))
	s += "## Market\n\n"
	for g := GoodAle; g <= GoodMead; g++ {
		s += ufmt.Sprintf("- %s: %d cg, supply %d\n", goodLabel(g), GoodPriceCg(g), MarketSupply(g))
	}
	s += "\n" + renderNeedsBody()
	s += "\n" + renderBoard("Top joints", Top())
	s += "\n" + renderBoard("Top farms", TopFarms())
	season := GetSeason()
	state := "open"
	if season.Frozen {
		state = "frozen"
	}
	s += ufmt.Sprintf("\n## Season\n\nSeason %d, %s, ends %d, pot %d ugnot, joint share %d bps.\n\n",
		season.Number, state, season.EndsAt, PotNow(), PubPotBps())
	s += "[Market](" + renderRoot + ":market)\n\n[Town needs](" + renderRoot + ":needs)\n\nIncome is not promised.\n"
	return s
}

func renderBoard(title string, rows []townmath.Entry) string {
	s := "## " + title + "\n\n"
	if len(rows) == 0 {
		s += "None yet.\n"
		return s
	}
	s += "| rank | owner | score |\n| --- | --- | --- |\n"
	n := len(rows)
	if n > TopN {
		n = TopN
	}
	for i := 0; i < n; i++ {
		s += ufmt.Sprintf("| %d | %s | %d |\n", i+1, rows[i].Owner, rows[i].Score)
	}
	return s
}

func renderNeedsPage() string {
	return "# Town needs\n\n" + renderNeedsBody()
}

func renderNeedsBody() string {
	pubs, farms, _, _ := TownStats()
	s := "## Town needs\n\n"
	s += ufmt.Sprintf("Joints: %d. Farms: %d.\n", pubs, farms)
	for _, g := range []int{GoodGrain, GoodHops} {
		s += ufmt.Sprintf("%s price %d cg, supply %d.\n", titleGood(g), GoodPriceCg(g), MarketSupply(g))
	}
	return s + needsMessage()
}

// needsMessage is the headline and one supporting sentence. The strongest
// scarce good (grain or hops) wins; otherwise plenty says farms can ease;
// otherwise the town looks steady.
func needsMessage() string {
	gb, gr := needBand(GoodGrain)
	hb, hr := needBand(GoodHops)
	if gb == bandScarce || hb == bandScarce {
		pick := GoodGrain
		if hb == bandScarce && (gb != bandScarce || hr > gr) {
			pick = GoodHops
		}
		return titleGood(pick) + " is scarce.\nFarms are needed.\n"
	}
	if gb == bandPlenty || hb == bandPlenty {
		return "Farms can ease.\nSupply is ahead of the town.\n"
	}
	return "Town supply looks steady.\nPrices sit in a wide band.\n"
}

// needBand classifies good. rank is higher when the price is further above
// its base, then when supply is lower, so two scarce goods can be ordered.
func needBand(good int) (band int, rank int64) {
	price := GoodPriceCg(good)
	base := GoodBaseCg(good)
	supply := MarketSupply(good)
	pubs, _, _, _ := TownStats()
	if base > 0 {
		rank = price * 10000 / base
	} else {
		rank = price
	}
	rank = rank*100000 - supply
	switch {
	case price >= townmath.MulBps(base, scarceBps) || (pubs > 0 && supply < pubs*24):
		band = bandScarce
	case price <= townmath.MulBps(base, plentyBps) && (pubs == 0 || supply > pubs*96):
		band = bandPlenty
	default:
		band = bandSteady
	}
	return band, rank
}

func renderMarket(path string, page int) string {
	s := "# Market\n\n"
	if note := pageNote(path); note != "" {
		s += note + "\n\n"
	}
	total := ListingCount()
	if total == 0 {
		if page <= 1 {
			s += "No listings yet.\n"
		} else {
			s += "No more listings.\n"
		}
		return s
	}
	offset := (page - 1) * pageSize
	if offset < 0 || offset >= total {
		s += "No more listings.\n"
		if page > 1 {
			s += ufmt.Sprintf("[Prev](%s:market?page=%d)\n", renderRoot, page-1)
		}
		return s
	}
	rows := Listings(offset, pageSize)
	s += "| id | seller | good | qty | priceCg |\n| --- | --- | --- | --- | --- |\n"
	for i := 0; i < len(rows); i++ {
		l := rows[i]
		s += ufmt.Sprintf("| %d | %s | %s | %d | %d |\n",
			l.ID, l.Seller.String(), goodLabel(l.Good), l.Qty, l.PriceCg)
	}
	if page > 1 {
		s += ufmt.Sprintf("[Prev](%s:market?page=%d)\n", renderRoot, page-1)
	}
	if offset+len(rows) < total {
		s += ufmt.Sprintf("[Next](%s:market?page=%d)\n", renderRoot, page+1)
	}
	return s
}

func renderBusiness(addr string) string {
	if addr == "" {
		return "No joint at this address.\n"
	}
	t := GetTavern(addr)
	if t == nil {
		return "No joint at this address.\n"
	}
	role := "joint"
	if t.Role == RoleFarm {
		role = "farm"
	}
	s := "# " + escapeMD(t.Name) + "\n\n"
	s += ufmt.Sprintf("Owner: %s\nRole: %s\nGold: %d cg\nStock: %d\n", t.Owner.String(), role, t.GoldCg, t.Stock)
	s += ufmt.Sprintf("Inventory: ale %d, grain %d, hops %d, mead %d\n",
		t.Inv[GoodAle], t.Inv[GoodGrain], t.Inv[GoodHops], t.Inv[GoodMead])
	s += ufmt.Sprintf("Price: %d cg\nReputation: %d\n", t.PriceCg, t.Rep)
	if t.Role == RolePub {
		s += ufmt.Sprintf("seats: %d\n", t.Seats)
		s += "Crew:"
		found := false
		crew := CrewOf(addr)
		for i := 0; i < MaxCrew; i++ {
			if crew[i] != "" {
				s += " " + crew[i]
				found = true
			}
		}
		if !found {
			s += " none"
		}
		s += "\n"
	} else {
		s += ufmt.Sprintf("plots: %d\ncrop: %s\n", t.Plots, cropLabel(t.Crop))
	}
	dorm := "no"
	if t.Dormant != 0 {
		dorm = "yes"
	}
	s += ufmt.Sprintf("dormant: %s\nSeason score: %d\nSeason production: %d\n", dorm, t.SeasonScore, t.SeasonProd)
	return s
}

func renderVillager(id string) string {
	if !knownVillager(id) {
		return "No such villager.\n"
	}
	v := villagers.GetVillager(id)
	hour := CurrentGameHour()
	needs := villagers.NeedsNow(id, hour)
	s := "# Villager " + id + "\n\n"
	s += ufmt.Sprintf("Owner: %s\nJob: %s\nloyalty: %d\n", villagers.OwnerOf(id).String(), jobName(v.Job), v.Loyalty)
	s += ufmt.Sprintf("Traits: %s, %s\n", villagers.TraitName(v.Traits[0]), villagers.TraitName(v.Traits[1]))
	s += ufmt.Sprintf("Needs: thirst %d, fun %d, energy %d\nmood: %s\n",
		needs.Thirst, needs.Fun, needs.Energy, moodName(villagers.MoodNow(id, hour)))
	return s
}

// knownVillager reports whether id is a minted villager without calling
// GetVillager, which aborts for an unknown id.
func knownVillager(id string) bool {
	if len(id) == 0 || len(id) > 12 || id[0] == '0' {
		return false
	}
	n := int64(0)
	for i := 0; i < len(id); i++ {
		if id[i] < '0' || id[i] > '9' {
			return false
		}
		n = n*10 + int64(id[i]-'0')
	}
	return n >= 1 && n <= int64(villagers.Count())
}

// parsePage splits an optional ?page= query. A missing page, page=0, a
// negative page or a non-numeric page is page 1. The base is the path
// before '?'.
func parsePage(path string) (base string, page int) {
	page = 1
	q := strings.IndexByte(path, '?')
	if q < 0 {
		return path, 1
	}
	base = path[:q]
	n, ok := pageNumber(path[q+1:])
	if !ok || n < 1 {
		return base, 1
	}
	if n > 1000000 {
		n = 1000000
	}
	return base, n
}

// pageNote is the one-line warning for a negative or non-numeric page.
// page=0 and a missing page are silent (they are page 1).
func pageNote(path string) string {
	q := strings.IndexByte(path, '?')
	if q < 0 {
		return ""
	}
	raw, present := pageRaw(path[q+1:])
	if !present || raw == "0" {
		return ""
	}
	if raw == "" || raw[0] == '-' {
		return "Invalid page; showing page 1."
	}
	for i := 0; i < len(raw); i++ {
		if raw[i] < '0' || raw[i] > '9' {
			return "Invalid page; showing page 1."
		}
	}
	return ""
}

func pageNumber(q string) (int, bool) {
	raw, ok := pageRaw(q)
	if !ok || raw == "" || raw[0] == '-' {
		return 0, false
	}
	n := 0
	for i := 0; i < len(raw); i++ {
		if raw[i] < '0' || raw[i] > '9' {
			return 0, false
		}
		// A longer number than the cap is past the last page, not invalid.
		if n > 100000 {
			return 1000000, true
		}
		n = n*10 + int(raw[i]-'0')
	}
	if n > 1000000 {
		return 1000000, true
	}
	return n, true
}

func pageRaw(q string) (string, bool) {
	i := strings.Index(q, "page=")
	if i < 0 {
		return "", false
	}
	v := q[i+len("page="):]
	if a := strings.IndexByte(v, '&'); a >= 0 {
		v = v[:a]
	}
	return v, true
}

// escapeMD strips Markdown control characters from player text so a name
// cannot inject a link, emphasis, or an angle-bracket autolink.
func escapeMD(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '`', '*', '_', '[', ']', '(', ')', '#', '!', '<', '>':
		default:
			out = append(out, s[i])
		}
	}
	return string(out)
}

func goodLabel(g int) string {
	switch g {
	case GoodAle:
		return "ale"
	case GoodGrain:
		return "grain"
	case GoodHops:
		return "hops"
	case GoodMead:
		return "mead"
	default:
		return "?"
	}
}

func titleGood(g int) string {
	switch g {
	case GoodGrain:
		return "Grain"
	case GoodHops:
		return "Hops"
	default:
		return goodLabel(g)
	}
}

func cropLabel(crop int64) string {
	if crop == int64(townmath.CropHops) {
		return "hops"
	}
	return "grain"
}

func eventKindName(k int) string {
	switch k {
	case townmath.EventFestival:
		return "festival"
	case townmath.EventShortage:
		return "shortage"
	case townmath.EventRival:
		return "rival"
	case townmath.EventTaxDay:
		return "tax day"
	default:
		return "none"
	}
}

func jobName(job int64) string {
	switch job {
	case villagers.JobBard:
		return "bard"
	case villagers.JobCook:
		return "cook"
	case villagers.JobBarkeep:
		return "barkeep"
	default:
		return "regular"
	}
}

func moodName(m int) string {
	switch m {
	case townmath.MoodHappy:
		return "happy"
	case townmath.MoodOkay:
		return "okay"
	default:
		return "miserable"
	}
}
