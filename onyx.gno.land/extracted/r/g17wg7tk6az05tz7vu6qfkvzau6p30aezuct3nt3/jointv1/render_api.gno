package jointv1

import (
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
	villagers "gno.land/r/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/villagersv1"
)

// uint64ToDec writes n in decimal without strconv.FormatUint (not in the
// Gno common subset we rely on).
func uint64ToDec(n uint64) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// JSON routes under Render("api/..."). Read-only, bounded, never panic.
// Contract: docs/api/render-json.md. Clients may call Settle to refresh
// settled-at fields; Render itself does not settle.

const apiMaxPage = 50

// renderAPI dispatches api/* paths. path is the part AFTER the "api/" prefix.
func renderAPI(path string) string {
	switch {
	case path == "town":
		return apiTown()
	case path == "top":
		return apiTop(false)
	case path == "topfarms":
		return apiTop(true)
	case path == "season":
		return apiSeason()
	case strings.HasPrefix(path, "tavern/"):
		return apiTavern(path[len("tavern/"):])
	case strings.HasPrefix(path, "villager/"):
		return apiVillager(path[len("villager/"):])
	case strings.HasPrefix(path, "crew/"):
		return apiCrew(path[len("crew/"):])
	case strings.HasPrefix(path, "villagers/"):
		return apiVillagers(path[len("villagers/"):])
	case strings.HasPrefix(path, "listings/"):
		return apiListings(path[len("listings/"):])
	default:
		return apiError("unknown api path")
	}
}

func apiError(msg string) string {
	return `{"error":` + jsonString(msg) + `}`
}

func apiTown() string {
	h := CurrentGameHour()
	day := h / 24
	pubs, farms, _, _ := TownStats()
	ev := EventOnDay(day)
	tfDay, tfSold, tfBought := TownFarmToday()
	p := GetParams()
	var b strings.Builder
	b.WriteString(`{"hour":`)
	b.WriteString(strconv.FormatInt(h, 10))
	b.WriteString(`,"day":`)
	b.WriteString(strconv.FormatInt(day, 10))
	b.WriteString(`,"secondsPerGameHour":`)
	b.WriteString(strconv.FormatInt(p.SecondsPerGameHour, 10))
	b.WriteString(`,"pubs":`)
	b.WriteString(strconv.FormatInt(pubs, 10))
	b.WriteString(`,"farms":`)
	b.WriteString(strconv.FormatInt(farms, 10))
	b.WriteString(`,"event":{"kind":`)
	b.WriteString(strconv.Itoa(ev.Kind))
	b.WriteString(`,"name":`)
	b.WriteString(jsonString(eventKindName(ev.Kind)))
	b.WriteString(`,"boostBps":`)
	b.WriteString(strconv.FormatInt(ev.BoostBps, 10))
	b.WriteString(`,"taxBps":`)
	b.WriteString(strconv.FormatInt(ev.TaxBps, 10))
	b.WriteString(`},"market":[`)
	for g := GoodAle; g <= GoodMead; g++ {
		if g > GoodAle {
			b.WriteByte(',')
		}
		b.WriteString(`{"id":`)
		b.WriteString(strconv.Itoa(g))
		b.WriteString(`,"name":`)
		b.WriteString(jsonString(goodLabel(g)))
		b.WriteString(`,"base":`)
		b.WriteString(strconv.FormatInt(GoodBaseCg(g), 10))
		b.WriteString(`,"price":`)
		b.WriteString(strconv.FormatInt(GoodPriceCg(g), 10))
		b.WriteString(`,"supply":`)
		b.WriteString(strconv.FormatInt(MarketSupply(g), 10))
		b.WriteByte('}')
	}
	b.WriteString(`],"townFarm":{"day":`)
	b.WriteString(strconv.FormatInt(tfDay, 10))
	b.WriteString(`,"sold":`)
	b.WriteString(strconv.FormatInt(tfSold, 10))
	b.WriteString(`,"bought":`)
	b.WriteString(strconv.FormatInt(tfBought, 10))
	b.WriteString(`},`)
	b.WriteString(apiSeasonFields())
	b.WriteString(`,"potUgnot":`)
	b.WriteString(strconv.FormatInt(PotNow(), 10))
	b.WriteString(`,"treasuryUgnot":`)
	b.WriteString(strconv.FormatInt(TreasuryNow(), 10))
	b.WriteString(`,"shop":{"neon":`)
	b.WriteString(strconv.FormatInt(PriceNeonUgnot, 10))
	b.WriteString(`,"floor":`)
	b.WriteString(strconv.FormatInt(PriceFloorUgnot, 10))
	b.WriteString(`,"pack":`)
	b.WriteString(strconv.FormatInt(PricePackUgnot, 10))
	b.WriteString(`}}`)
	return b.String()
}

func apiSeasonFields() string {
	s := GetSeason()
	state := "none"
	if s.Number > 0 {
		if s.Frozen {
			state = "frozen"
		} else {
			state = "active"
		}
	}
	return ufmt.Sprintf(
		`"season":{"number":%d,"state":%s,"endsAt":%d,"potUgnot":%d,"pubPotUgnot":%d,"farmPotUgnot":%d,"frozen":%s,"pubPotBps":%d}`,
		s.Number, jsonString(state), s.EndsAt, s.PotUgnot, s.PubPotUgnot, s.FarmPotUgnot,
		jsonBool(s.Frozen), PubPotBps(),
	)
}

func apiSeason() string {
	// apiSeasonFields is `"season":{...}`; strip the key for a bare object.
	return apiSeasonFields()[len(`"season":`):]
}

func apiTavern(addr string) string {
	if addr == "" {
		return apiError("missing address")
	}
	t := GetTavern(addr)
	if t == nil {
		return apiError("no joint at this address")
	}
	role := "joint"
	if t.Role == RoleFarm {
		role = "farm"
	}
	var b strings.Builder
	b.WriteString(`{"owner":`)
	b.WriteString(jsonString(t.Owner.String()))
	b.WriteString(`,"role":`)
	b.WriteString(jsonString(role))
	b.WriteString(`,"name":`)
	b.WriteString(jsonString(t.Name))
	b.WriteString(`,"goldCg":`)
	b.WriteString(strconv.FormatInt(t.GoldCg, 10))
	b.WriteString(`,"priceCg":`)
	b.WriteString(strconv.FormatInt(t.PriceCg, 10))
	b.WriteString(`,"seats":`)
	b.WriteString(strconv.FormatInt(t.Seats, 10))
	b.WriteString(`,"rep":`)
	b.WriteString(strconv.FormatInt(t.Rep, 10))
	b.WriteString(`,"stock":`)
	b.WriteString(strconv.FormatInt(t.Stock, 10))
	b.WriteString(`,"inv":[`)
	for i := 0; i < 4; i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatInt(t.Inv[i], 10))
	}
	b.WriteString(`],"crop":`)
	b.WriteString(strconv.FormatInt(t.Crop, 10))
	b.WriteString(`,"plots":`)
	b.WriteString(strconv.FormatInt(t.Plots, 10))
	b.WriteString(`,"storageCap":`)
	b.WriteString(strconv.FormatInt(FarmStorageCap, 10))
	b.WriteString(`,"dormant":`)
	b.WriteString(jsonBool(t.Dormant != 0))
	b.WriteString(`,"hasBarmaid":`)
	b.WriteString(jsonBool(t.HasBarmaid))
	b.WriteString(`,"hasNeon":`)
	b.WriteString(jsonBool(t.HasNeon))
	b.WriteString(`,"hasFloor":`)
	b.WriteString(jsonBool(t.HasFloor))
	b.WriteString(`,"lastHour":`)
	b.WriteString(strconv.FormatInt(t.LastHour, 10))
	b.WriteString(`,"profitTodayCg":`)
	b.WriteString(strconv.FormatInt(t.ProfitTodayCg, 10))
	b.WriteString(`,"seasonProfitCg":`)
	b.WriteString(strconv.FormatInt(t.SeasonProfitCg, 10))
	b.WriteString(`,"seasonScore":`)
	b.WriteString(strconv.FormatInt(t.SeasonScore, 10))
	b.WriteString(`,"seasonProd":`)
	b.WriteString(strconv.FormatInt(t.SeasonProd, 10))
	b.WriteString(`,"weight":`)
	b.WriteString(strconv.FormatInt(t.Weight, 10))
	b.WriteString(`,"tfBought":`)
	b.WriteString(strconv.FormatInt(t.TFBought, 10))
	b.WriteString(`,"tfSold":`)
	b.WriteString(strconv.FormatInt(t.TFSold, 10))
	b.WriteString(`,"townFarmSellBps":`)
	b.WriteString(strconv.FormatInt(TownFarmSellBpsFor(addr), 10))
	b.WriteString(`,"crew":[`)
	for i := 0; i < MaxCrew; i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsonString(t.Crew[i]))
	}
	b.WriteString(`],"crewRestUntil":[`)
	for i := 0; i < MaxCrew; i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatInt(t.CrewRestUntil[i], 10))
	}
	b.WriteString(`],"note":`)
	b.WriteString(jsonString("settled-at values; call Settle to refresh"))
	b.WriteByte('}')
	return b.String()
}

func apiVillager(id string) string {
	if id == "" || !knownVillager(id) {
		return apiError("no such villager")
	}
	v := villagers.GetVillager(id)
	hour := CurrentGameHour()
	needs := villagers.NeedsNow(id, hour)
	mood := villagers.MoodNow(id, hour)
	owner := villagers.OwnerOf(id)
	var b strings.Builder
	b.WriteString(`{"id":`)
	b.WriteString(jsonString(v.ID))
	b.WriteString(`,"owner":`)
	b.WriteString(jsonString(owner.String()))
	b.WriteString(`,"seed":`)
	b.WriteString(uint64ToDec(v.Seed))
	b.WriteString(`,"job":`)
	b.WriteString(strconv.FormatInt(v.Job, 10))
	b.WriteString(`,"jobName":`)
	b.WriteString(jsonString(jobName(v.Job)))
	b.WriteString(`,"loyalty":`)
	b.WriteString(strconv.FormatInt(v.Loyalty, 10))
	b.WriteString(`,"traits":[`)
	b.WriteString(strconv.Itoa(v.Traits[0]))
	b.WriteByte(',')
	b.WriteString(strconv.Itoa(v.Traits[1]))
	b.WriteString(`],"traitNames":[`)
	b.WriteString(jsonString(villagers.TraitName(v.Traits[0])))
	b.WriteByte(',')
	b.WriteString(jsonString(villagers.TraitName(v.Traits[1])))
	b.WriteString(`],"needs":{"thirst":`)
	b.WriteString(strconv.FormatInt(needs.Thirst, 10))
	b.WriteString(`,"fun":`)
	b.WriteString(strconv.FormatInt(needs.Fun, 10))
	b.WriteString(`,"energy":`)
	b.WriteString(strconv.FormatInt(needs.Energy, 10))
	b.WriteString(`},"needsAt":`)
	b.WriteString(strconv.FormatInt(v.NeedsAt, 10))
	b.WriteString(`,"mood":`)
	b.WriteString(strconv.Itoa(mood))
	b.WriteString(`,"moodName":`)
	b.WriteString(jsonString(moodName(mood)))
	b.WriteString(`,"hour":`)
	b.WriteString(strconv.FormatInt(hour, 10))
	b.WriteByte('}')
	return b.String()
}

func apiCrew(addr string) string {
	if addr == "" {
		return apiError("missing address")
	}
	crew := CrewOf(addr)
	var b strings.Builder
	b.WriteString(`{"owner":`)
	b.WriteString(jsonString(addr))
	b.WriteString(`,"crew":[`)
	for i := 0; i < MaxCrew; i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsonString(crew[i]))
	}
	b.WriteString(`]}`)
	return b.String()
}

func apiVillagers(rest string) string {
	off, count, ok := parseTwoInts(rest)
	if !ok {
		return apiError("bad villagers path; want api/villagers/<offset>/<count>")
	}
	if off < 0 {
		return apiError("offset must be >= 0")
	}
	if count < 1 {
		count = 1
	}
	if count > apiMaxPage {
		count = apiMaxPage
	}
	rows := villagers.Villagers(off, count)
	total := villagers.Count()
	var b strings.Builder
	b.WriteString(`{"offset":`)
	b.WriteString(strconv.Itoa(off))
	b.WriteString(`,"count":`)
	b.WriteString(strconv.Itoa(count))
	b.WriteString(`,"total":`)
	b.WriteString(strconv.Itoa(total))
	b.WriteString(`,"villagers":[`)
	hour := CurrentGameHour()
	for i := 0; i < len(rows); i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		v := rows[i]
		needs := villagers.NeedsNow(v.ID, hour)
		mood := villagers.MoodNow(v.ID, hour)
		owner := villagers.OwnerOf(v.ID).String()
		b.WriteString(`{"id":`)
		b.WriteString(jsonString(v.ID))
		b.WriteString(`,"owner":`)
		b.WriteString(jsonString(owner))
		b.WriteString(`,"job":`)
		b.WriteString(strconv.FormatInt(v.Job, 10))
		b.WriteString(`,"loyalty":`)
		b.WriteString(strconv.FormatInt(v.Loyalty, 10))
		b.WriteString(`,"mood":`)
		b.WriteString(strconv.Itoa(mood))
		b.WriteString(`,"needs":{"thirst":`)
		b.WriteString(strconv.FormatInt(needs.Thirst, 10))
		b.WriteString(`,"fun":`)
		b.WriteString(strconv.FormatInt(needs.Fun, 10))
		b.WriteString(`,"energy":`)
		b.WriteString(strconv.FormatInt(needs.Energy, 10))
		b.WriteString(`}}`)
	}
	b.WriteString(`]}`)
	return b.String()
}

func apiListings(rest string) string {
	off, count, ok := parseTwoInts(rest)
	if !ok {
		return apiError("bad listings path; want api/listings/<offset>/<count>")
	}
	if off < 0 {
		return apiError("offset must be >= 0")
	}
	if count < 1 {
		count = 1
	}
	if count > apiMaxPage {
		count = apiMaxPage
	}
	rows := Listings(off, count)
	total := ListingCount()
	var b strings.Builder
	b.WriteString(`{"offset":`)
	b.WriteString(strconv.Itoa(off))
	b.WriteString(`,"count":`)
	b.WriteString(strconv.Itoa(count))
	b.WriteString(`,"total":`)
	b.WriteString(strconv.Itoa(total))
	b.WriteString(`,"listings":[`)
	for i := 0; i < len(rows); i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		l := rows[i]
		b.WriteString(`{"id":`)
		b.WriteString(uint64ToDec(l.ID))
		b.WriteString(`,"seller":`)
		b.WriteString(jsonString(l.Seller.String()))
		b.WriteString(`,"good":`)
		b.WriteString(strconv.Itoa(l.Good))
		b.WriteString(`,"goodName":`)
		b.WriteString(jsonString(goodLabel(l.Good)))
		b.WriteString(`,"qty":`)
		b.WriteString(strconv.FormatInt(l.Qty, 10))
		b.WriteString(`,"priceCg":`)
		b.WriteString(strconv.FormatInt(l.PriceCg, 10))
		b.WriteByte('}')
	}
	b.WriteString(`]}`)
	return b.String()
}

func apiTop(farms bool) string {
	var rows []townmath.Entry
	if farms {
		rows = TopFarms()
	} else {
		rows = Top()
	}
	var b strings.Builder
	b.WriteString(`{"entries":[`)
	n := len(rows)
	if n > TopN {
		n = TopN
	}
	for i := 0; i < n; i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"rank":`)
		b.WriteString(strconv.Itoa(i + 1))
		b.WriteString(`,"owner":`)
		b.WriteString(jsonString(rows[i].Owner))
		b.WriteString(`,"score":`)
		b.WriteString(strconv.FormatInt(rows[i].Score, 10))
		b.WriteByte('}')
	}
	b.WriteString(`]}`)
	return b.String()
}

func parseTwoInts(rest string) (off, count int, ok bool) {
	parts := strings.Split(rest, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return 0, 0, false
	}
	o, err1 := strconv.Atoi(parts[0])
	c, err2 := strconv.Atoi(parts[1])
	if err1 != nil || err2 != nil {
		return 0, 0, false
	}
	return o, c, true
}

func jsonBool(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

// jsonString returns a JSON string literal with quotes, escaping \, ", and
// control characters. Names are printable ASCII but may contain " and \.
func jsonString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				const hex = "0123456789abcdef"
				b.WriteByte(hex[c>>4])
				b.WriteByte(hex[c&0xf])
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
