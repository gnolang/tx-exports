package kourt2
import (
	"strconv"
	"strings"
)
const (
	burnSeriesKey  = "burn"
	priceSeriesKey = "price"
)
func recordPrice(c *Court) {
	setIfChanged(ensureCSArch(c), &c.priceH, priceSeriesKey,
		uint32(heightNow()/epochBlocks)+1, c.crv.Price(c.minted))
}
func recordBurn(c *Court) {
	setIfChanged(ensureCSArch(c), &c.burnH, burnSeriesKey,
		uint32(heightNow()/epochBlocks)+1, c.burnedGNOT)
}
func formatSeries(width int64, now uint32, pts []histPoint, more bool) string {
	rows := make([]string, 0, len(pts))
	for _, p := range pts {
		rows = append(rows, strconv.FormatUint(uint64(p.e), 10)+":"+
			strconv.FormatInt(p.v, 10))
	}
	m := "0"
	if more {
		m = "1"
	}
	return strconv.FormatInt(width, 10) + "," +
		strconv.FormatUint(uint64(now), 10) + "," + m + ";" +
		strings.Join(rows, ",")
}
func SupplySeries(courtSlug string) string {
	c := mustCourt(courtSlug)
	pts := []histPoint{}
	more := false
	c.coin.WalkSupply(func(e uint32, v int64) bool {
		if len(pts) >= seriesRowCap {
			more = true
			return true
		}
		pts = append(pts, histPoint{e, v})
		return false
	})
	for i, j := 0, len(pts)-1; i < j; i, j = i+1, j-1 {
		pts[i], pts[j] = pts[j], pts[i]
	}
	return formatSeries(c.coin.EpochBlocks(), c.coin.Epoch(), pts, more)
}
func BurnSeries(courtSlug string) string {
	c := mustCourt(courtSlug)
	pts, more := collectSeriesKeyed(c.csArch, &c.burnH, burnSeriesKey)
	return formatSeries(epochBlocks, uint32(heightNow()/epochBlocks)+1, pts, more)
}
func PriceSeries(courtSlug string) string {
	c := mustCourt(courtSlug)
	pts, more := collectSeriesKeyed(c.csArch, &c.priceH, priceSeriesKey)
	return formatSeries(epochBlocks, uint32(heightNow()/epochBlocks)+1, pts, more)
}
