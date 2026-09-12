package kourt2
import (
	"strconv"
	"strings"
	checkpoint "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/checkpoint/v0"
)
const (
	hourlyKeep = uint32(168)
	trimBudget = 2
	dailyBlocks = int64(17_280)
	seriesRowCap = 400
)
func csKey(id uint64, suffix string) string {
	return "cs:" + strconv.FormatUint(id, 10) + ":" + suffix
}
func ensureCSArch(c *Court) *checkpoint.Archive {
	if c.csArch == nil {
		c.csArch = checkpoint.NewArchive()
	}
	return c.csArch
}
func setIfChanged(a *checkpoint.Archive, s *checkpoint.Series, key string, e uint32, v int64) {
	if v != s.Value() {
		s.SetAt(a, key, e, v)
	}
}
func recordPools(c *Court, cs *claimState) {
	h := heightNow()
	a := ensureCSArch(c)
	hE := uint32(h/epochBlocks) + 1
	dE := uint32(h/dailyBlocks) + 1
	setIfChanged(a, &cs.yesH, csKey(cs.id, "yh"), hE, cs.yesStake)
	setIfChanged(a, &cs.noH, csKey(cs.id, "nh"), hE, cs.noStake)
	setIfChanged(a, &cs.yesD, csKey(cs.id, "yd"), dE, cs.yesStake)
	setIfChanged(a, &cs.noD, csKey(cs.id, "nd"), dE, cs.noStake)
	if hE > cs.histTrimmedTo {
		cs.histTrimmedTo = hE
		trimClaimHistory(c, cs, hE)
	}
}
func trimClaimHistory(c *Court, cs *claimState, hE uint32) {
	if c.csArch == nil || hE <= hourlyKeep+1 {
		return
	}
	keep := hE - hourlyKeep
	c.csArch.Trim(csKey(cs.id, "yh"), keep, trimBudget)
	c.csArch.Trim(csKey(cs.id, "nh"), keep, trimBudget)
}
type histPoint struct {
	e uint32
	v int64
}
func collectSeriesKeyed(a *checkpoint.Archive, s *checkpoint.Series, key string) ([]histPoint, bool) {
	pts := []histPoint{}
	more := false
	if a != nil && key != "" {
		a.WalkDesc(key, func(e uint32, v int64) bool {
			if len(pts) >= seriesRowCap {
				more = true
				return true
			}
			pts = append(pts, histPoint{e, v})
			return false
		})
	}
	for i, j := 0, len(pts)-1; i < j; i, j = i+1, j-1 {
		pts[i], pts[j] = pts[j], pts[i]
	}
	if e1, pv := s.Prev(); e1 != 0 {
		pts = append(pts, histPoint{e1, pv})
	}
	if e0 := s.Since(); e0 != 0 {
		pts = append(pts, histPoint{e0, s.Value()})
	}
	return pts, more
}
func ClaimSeries(courtSlug string, claimID uint64, grain string) string {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	var width int64
	var yS, nS *checkpoint.Series
	var yKey, nKey string
	switch grain {
	case "hourly":
		width = epochBlocks
		yS, nS = &cs.yesH, &cs.noH
		yKey, nKey = csKey(claimID, "yh"), csKey(claimID, "nh")
	case "daily":
		width = dailyBlocks
		yS, nS = &cs.yesD, &cs.noD
		yKey, nKey = csKey(claimID, "yd"), csKey(claimID, "nd")
	default:
		panic(`kourtv2: grain is "hourly" or "daily"`)
	}
	now := uint32(heightNow()/width) + 1
	ys, moreY := collectSeriesKeyed(c.csArch, yS, yKey)
	ns, moreN := collectSeriesKeyed(c.csArch, nS, nKey)
	start := uint32(0)
	if moreY && len(ys) > 0 && ys[0].e > start {
		start = ys[0].e
	}
	if moreN && len(ns) > 0 && ns[0].e > start {
		start = ns[0].e
	}
	more := moreY || moreN
	curY, curN := int64(0), int64(0)
	i, j := 0, 0
	for i < len(ys) && ys[i].e < start {
		curY = ys[i].v
		i++
	}
	for j < len(ns) && ns[j].e < start {
		curN = ns[j].v
		j++
	}
	rows := []string{}
	for i < len(ys) || j < len(ns) {
		var e uint32
		switch {
		case i >= len(ys):
			e = ns[j].e
		case j >= len(ns):
			e = ys[i].e
		case ys[i].e < ns[j].e:
			e = ys[i].e
		default:
			e = ns[j].e
		}
		if i < len(ys) && ys[i].e == e {
			curY = ys[i].v
			i++
		}
		if j < len(ns) && ns[j].e == e {
			curN = ns[j].v
			j++
		}
		rows = append(rows, strconv.FormatUint(uint64(e), 10)+":"+
			strconv.FormatInt(curY, 10)+":"+strconv.FormatInt(curN, 10))
	}
	if len(rows) > seriesRowCap {
		rows = rows[len(rows)-seriesRowCap:]
		more = true
	}
	m := "0"
	if more {
		m = "1"
	}
	return grain + "," + strconv.FormatInt(width, 10) + "," +
		strconv.FormatUint(uint64(now), 10) + "," + m + ";" +
		strings.Join(rows, ",")
}
