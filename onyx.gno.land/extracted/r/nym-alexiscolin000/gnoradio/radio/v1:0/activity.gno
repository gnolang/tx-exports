package radio

import (
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
)

const activitySize = 64

// Activity is one programming action on a station.
type Activity struct {
	Kind    string // queue | curator | sponsored
	By      address
	Track   int
	Station int
	Start   int64
	At      int64
}

// recordActivity writes the next slot of the fixed-size ring (storage
// never grows): Rec(kind, by, numbers), the numbers the track (4 digits),
// the station (1), the start (6) and the time (6). The head is in the flow
// record.
func recordActivity(t *tx, kind string, by address, track, station int, start int64) {
	h := t.flowAt(fHead, 1)
	n := store.AppendFixed(store.AppendFixed(store.AppendFixed(store.AppendFixed(make([]byte, 0, 17), int64(track), 4), int64(station), 1), start, 6), now(), 6)
	t.put(cActivity, store.Pad(h), store.Rec(kind, by.String(), string(n)))
	t.setFlowAt(fHead, 1, (h+1)%activitySize)
}

func activityOf(rec string) Activity {
	f := store.Fields(rec)
	n := f[2]
	return Activity{Kind: f[0], By: address(f[1]), Track: int(store.Num(n, 0, 4)), Station: int(store.Num(n, 4, 1)), Start: store.Num(n, 5, 6), At: store.Num(n, 11, 6)}
}

// activities returns up to limit records, newest first: the ring's slots
// before its head, read one by one (the ring fills from slot 0 and no slot
// is ever deleted, so the first empty one ends it).
func activities(limit int) []string {
	limit = store.Limit(limit, activitySize)
	t := rd()
	head := t.flowAt(fHead, 1)
	out := make([]string, 0, limit)
	for i := 1; i <= limit; i++ {
		rec := t.val(cActivity, store.Pad((head-i+activitySize)%activitySize))
		if rec == "" {
			break // the ring is not full yet
		}
		out = append(out, rec)
	}
	return out
}

// Activities returns up to limit entries, newest first.
func Activities(limit int) []Activity {
	var out []Activity
	for _, rec := range activities(limit) {
		out = append(out, activityOf(rec))
	}
	return out
}

// ActivityJSON returns the programming feed, newest first (limit <= 64).
func ActivityJSON(limit int) string {
	var b strings.Builder
	b.WriteString("[")
	for i, rec := range activities(limit) {
		a := activityOf(rec)
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"kind":` + text.Str(a.Kind) + `,"by":` + text.Str(a.By.String()) + `,"track":` + text.Itoa(a.Track) +
			`,"station":` + text.Itoa(a.Station) + `,"start":` + text.Itoa64(a.Start) + `,"at":` + text.Itoa64(a.At) + `}`)
	}
	b.WriteString("]")
	return b.String()
}
