package radio

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v2"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// Curators are the listeners who pick tracks. While a pick is on air, a tip to
// its artist made with TipOnAir sends the artist's promo share to the picker
// (catalog/promo.gno). Every pick and every shared tip updates the picker's
// counters and the weekly top of the station and of all stations: one record
// and a 10-entry list, whatever the number of curators.

const (
	allStations = -1
	topCurators = 10
	topMax      = 5 + topCurators*46 // the longest station top: week, count, then score and key per curator
	week        = 7 * 24 * 3600
	tipGrace    = 120 // seconds after a pick ends during which a tip still credits its picker
)

// Curator is a picker's record, all time or for one week.
type Curator struct {
	Address address
	Picks   int
	Tips    int   // tips received while their picks were on air
	Earned  int64 // ugnot from those tips
	Promo   int64 // ugnot refunded by artists for sponsored picks (sponsor.gno)
}

// A curator is one record: all time, picks, tips, earned, promo, first
// pick, period, picks this period, picks the period before (sponsor.gno);
// this week across stations, week, picks, tips, earned; each a fixed-width
// number (cWidths). Then one entry per station picked on lately: the
// station (1 digit), week, picks, tips, earned and the last pick time
// (sWidths).
const (
	cWeek   = 8
	cFields = 12
	cLen    = 62 // the numbers
	sLen    = 27 // one station entry
)

var (
	cWidths = [cFields]int{4, 4, 8, 8, 6, 4, 4, 4, 4, 4, 4, 8}
	sWidths = [5]int{4, 4, 4, 8, 6}
)

// TipOnAir tips the artist of trackID: the attached ugnot go through the
// catalog, which pays the artist and collaborators exactly as
// catalog.TipWithSupport does. When trackID is a listener's pick on air on
// stationID (or ended less than two minutes ago), the artist's promo share
// goes to that listener; the radio reads the picker from its own schedule.
// ref is who shared the link the tipper came from ("" for none): picker and
// ref split the promo share, never more.
func TipOnAir(cur realm, stationID, trackID, supportPct int, ref address) {
	tipper := userCaller(cur)
	if ref != "" && !role.Canonical(ref) {
		panic("radio: ref is not an address (lower-case g1...)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("radio: attach an amount in ugnot")
	}
	t := rd()
	st := t.station(stationID)
	picker, home := st.picker(trackID, now(), adminAddr())
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), chain.PackageAddress(data.Writer("catalog")), sent)
	toPicker, _ := catalog.RadioTip(cross(cur), trackID, supportPct, tipper, picker, ref, sent[0].Amount)
	if toPicker > 0 {
		credit(t, picker, home, 0, 1, toPicker) // ranked where the pick lives
		save(cur, t)
		chain.Emit("CuratorTipped", "station", text.Itoa(st.id), "track", text.Itoa(trackID), "picker", picker.String(), "amount", text.Itoa64(toPicker))
	}
}

// credit adds picks or a shared tip to a curator, all time and this week.
// The station's entry also keeps the time of the last pick there, which the
// queue cooldown reads (lastPickAt): no extra write per pick.
func credit(t *tx, by address, stationID, picks, tips int, earned int64) {
	k := by.String()
	ts := now()
	c, sts := curRec(t, k)
	c[0], c[1], c[2] = c[0]+int64(picks), c[1]+int64(tips), c[2]+earned
	if picks > 0 {
		// The reputation sponsored picks need (sponsor.gno): the first pick,
		// and picks counted per period, this one and the one before.
		if c[4] == 0 {
			c[4] = ts
		}
		switch p := ts / repPeriod; c[5] {
		case p:
			c[6]++
		case p - 1:
			c[5], c[6], c[7] = p, 1, c[6]
		default:
			c[5], c[6], c[7] = p, 1, 0
		}
	}
	wk := weekOf(ts)
	if c[cWeek] != wk {
		c[cWeek], c[cWeek+1], c[cWeek+2], c[cWeek+3] = wk, 0, 0, 0
	}
	c[cWeek+1], c[cWeek+2], c[cWeek+3] = c[cWeek+1]+int64(picks), c[cWeek+2]+int64(tips), c[cWeek+3]+earned
	w := stationOf(sts, stationID)
	if w[0] != wk {
		w = []int64{wk, 0, 0, 0, w[4]}
	}
	w[1], w[2], w[3] = w[1]+int64(picks), w[2]+int64(tips), w[3]+earned
	if picks > 0 {
		w[4] = ts
	}
	putCur(t, k, c, withStation(sts, stationID, w, ts))
	setTop(t, 0, wk, k, c[cWeek+1]+c[cWeek+2])
	setTop(t, stationID+1, wk, k, w[1]+w[2])
}

// curRec reads a curator record (zeros when absent) and its station entries.
func curRec(t *tx, k string) ([]int64, string) {
	c := make([]int64, cFields)
	rec := t.val(cCurators, k)
	if rec == "" {
		return c, ""
	}
	at := 0
	for i, w := range cWidths {
		c[i] = store.Num(rec, at, w)
		at += w
	}
	return c, rec[at:]
}

func putCur(t *tx, k string, c []int64, sts string) {
	b := make([]byte, 0, cLen+len(sts))
	for i, w := range cWidths {
		b = store.AppendFixed(b, c[i], w)
	}
	t.set(cCurators, k, string(append(b, sts...)))
}

// stationOf returns a curator's entry for a station: week, picks, tips,
// earned, last pick time (zeros when none).
func stationOf(sts string, stationID int) []int64 {
	w := make([]int64, 5)
	for i := 0; i+sLen <= len(sts); i += sLen {
		if int(dec[sts[i]]) == stationID {
			at := i + 1
			for j, n := range sWidths {
				w[j] = store.Num(sts, at, n)
				at += n
			}
			break
		}
	}
	return w
}

// withStation sets a station's entry and drops the entries that no longer
// count: an older week whose last pick is past the cooldown.
func withStation(sts string, stationID int, w []int64, ts int64) string {
	b := store.AppendFixed(make([]byte, 0, sLen+len(sts)), int64(stationID), 1)
	for j, n := range sWidths {
		b = store.AppendFixed(b, w[j], n)
	}
	wk := weekOf(ts)
	for i := 0; i+sLen <= len(sts); i += sLen {
		e := sts[i : i+sLen]
		if int(dec[e[0]]) == stationID {
			continue
		}
		if store.Num(e, 1, 4) == wk || ts-store.Num(e, sLen-6, 6) < queueCooldown {
			b = append(b, e...)
		}
	}
	return string(b)
}

// markPick keeps the time of a pick that earns no point (a sponsored one) for
// the queue cooldown.
func markPick(t *tx, by address, stationID int) {
	k := by.String()
	ts := now()
	c, sts := curRec(t, k)
	w := stationOf(sts, stationID)
	if wk := weekOf(ts); w[0] != wk {
		w = []int64{wk, 0, 0, 0, 0}
	}
	w[4] = ts
	putCur(t, k, c, withStation(sts, stationID, w, ts))
}

// lastPickAt is when addr last picked on a station (0: never).
func lastPickAt(t *tx, addr address, stationID int) int64 {
	rec := t.val(cCurators, addr.String())
	if rec == "" {
		return 0
	}
	return stationOf(rec[cLen:], stationID)[4]
}

// weekOf numbers weeks from Monday 00:00 UTC.
func weekOf(ts int64) int64 { return (ts + 3*24*3600) / week }

// ---- weekly tops: radio/tops P(station+1), 0 all stations ----

// A top is the week (4 digits), the number of entries n (1) and their
// scores, best first (4 each), then their addresses, each after its length
// (1).

type rank struct {
	key   string // address
	score int64  // picks + tips this week
}

// topRec is ranking i: 0 across stations, else station i-1's (in its
// record, which a pick there writes anyway).
func topRec(t *tx, i int) string {
	if i == 0 {
		return t.val(cTops, "all")
	}
	return t.station(i - 1).top
}

// top reads ranking i of week wk (nil when another week's).
func top(t *tx, i int, wk int64) []rank {
	rec := topRec(t, i)
	if rec == "" || store.Num(rec, 0, 4) != wk {
		return nil
	}
	n := int(dec[rec[4]])
	out := make([]rank, 0, n)
	for j, at := 0, 5+4*n; j < n; j++ {
		l := int(dec[rec[at]])
		out = append(out, rank{rec[at+1 : at+1+l], store.Num(rec, 5+4*j, 4)})
		at += 1 + l
	}
	return out
}

// setTop raises k's score in a ranking, emptied when a new week starts.
// Scores only grow, so a score below the last of a full top leaves it
// untouched (and unsaved): k cannot be in it. That is read without
// decoding the list.
func setTop(t *tx, i int, wk int64, k string, v int64) {
	if i == 0 {
		if int64(t.flowAt(fTopWeek, 4)) == wk && int64(t.flowAt(fTopLast, 4)) > v {
			return
		}
	} else if rec := topRec(t, i); rec != "" && store.Num(rec, 0, 4) == wk && int(dec[rec[4]]) == topCurators && v < store.Num(rec, 1+4*topCurators, 4) {
		return
	}
	list := top(t, i, wk)
	out := make([]rank, 0, topCurators+1)
	for _, r := range list {
		if r.key != k {
			out = append(out, r)
		}
	}
	j := len(out)
	for j > 0 && out[j-1].score < v {
		j--
	}
	if j >= topCurators {
		return
	}
	out = append(out, rank{})
	copy(out[j+1:], out[j:])
	out[j] = rank{k, v}
	if len(out) > topCurators {
		out = out[:topCurators]
	}
	b := store.AppendFixed(store.AppendFixed(make([]byte, 0, topMax), wk, 4), int64(len(out)), 1)
	for _, r := range out {
		b = store.AppendFixed(b, r.score, 4)
	}
	for _, r := range out {
		b = append(store.AppendFixed(b, int64(len(r.key)), 1), r.key...)
	}
	if i == 0 {
		t.set(cTops, "all", string(b))
		last := int64(0)
		if len(out) == topCurators {
			last = out[topCurators-1].score
		}
		t.setFlowAt(fTopWeek, 4, int(wk))
		t.setFlowAt(fTopLast, 4, int(last))
		return
	}
	st := t.station(i - 1)
	st.top, st.dirty = string(b), true
}

// CuratorOf returns a listener's curator record, all time.
func CuratorOf(addr address) Curator {
	c, _ := curRec(rd(), addr.String())
	return Curator{Address: addr, Picks: int(c[0]), Tips: int(c[1]), Earned: c[2], Promo: c[3]}
}

// TopCurators returns this week's top curators of a station (allStations:
// every station), best first, with their counts for the week. Picks and tips
// received on air score one point each.
func TopCurators(stationID int) []Curator {
	return weekTop(rd(), stationID)
}

func weekTop(t *tx, stationID int) []Curator {
	if stationID != allStations {
		mustStation(stationID)
	}
	list := top(t, stationID+1, weekOf(now()))
	out := make([]Curator, 0, len(list))
	for _, r := range list {
		c, sts := curRec(t, r.key)
		n := c[cWeek:]
		if stationID != allStations {
			n = stationOf(sts, stationID)
		}
		out = append(out, Curator{Address: address(r.key), Picks: int(n[1]), Tips: int(n[2]), Earned: n[3]})
	}
	return out
}

// CuratorJSON returns a listener's curator record: all time, this week, and
// their place in this week's top across stations (0 when outside the top 10).
func CuratorJSON(addr address) string {
	t := rd()
	r, _ := curRec(t, addr.String())
	w := r[cWeek:]
	if w[0] != weekOf(now()) {
		w = []int64{0, 0, 0, 0}
	}
	place := 0
	for i, c := range weekTop(t, allStations) {
		if c.Address == addr {
			place = i + 1
		}
	}
	return `{"address":` + text.Str(addr.String()) + `,"picks":` + text.Itoa64(r[0]) + `,"tips":` + text.Itoa64(r[1]) + `,"earned":` + text.Itoa64(r[2]) + `,"promo":` + text.Itoa64(r[3]) +
		`,"week":{"picks":` + text.Itoa64(w[1]) + `,"tips":` + text.Itoa64(w[2]) + `,"earned":` + text.Itoa64(w[3]) + `,"rank":` + text.Itoa(place) + `}}`
}

// TopCuratorsJSON returns TopCurators as JSON with the week's start (unix).
func TopCuratorsJSON(stationID int) string {
	var b strings.Builder
	b.WriteString(`{"station":` + text.Itoa(stationID) + `,"since":` + text.Itoa64(weekOf(now())*week-3*24*3600) + `,"top":[`)
	for i, c := range TopCurators(stationID) {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"address":` + text.Str(c.Address.String()) + `,"picks":` + text.Itoa(c.Picks) + `,"tips":` + text.Itoa(c.Tips) + `,"earned":` + text.Itoa64(c.Earned) + `}`)
	}
	b.WriteString(`]}`)
	return b.String()
}
