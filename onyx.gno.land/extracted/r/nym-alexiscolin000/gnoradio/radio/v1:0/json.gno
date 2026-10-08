package radio

import (
	"strconv"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v1"
)

// Read API for the GnoRadio app (vm/qeval).

// ScheduleJSON returns what a station plays from now until now+horizon seconds
// (60..7200, at most 60 entries): programmed slots and the rotation between
// them (on Main, the hour's genre station, simulcast and cut at each hour). A client plays entry i from offset+max(0, clock-start) and resyncs on
// "now". "relay" marks, on Main, an entry that is not Main's own slot but
// the hour's genre station simulcast (its picks included). "sponsored" is the refund its artist pays the picker (0: a normal
// pick), "at" the time a booked pick asked for (0: none). "booked" lists every
// booked pick still to air, whatever the horizon, and those that aired in the
// last hour (they count toward their clock hour's cap until they fold):
// {"track","start","end","at","by","note"}. Fetch it again every few minutes, not
// every second.
func ScheduleJSON(stationID, horizon int) string {
	st := rd().station(stationID)
	if horizon < 60 || horizon > 7200 {
		horizon = 3600
	}
	ts := now()
	end := ts + int64(horizon)
	var b strings.Builder
	b.WriteString(`{"station":` + text.Itoa(st.id) + `,"now":` + text.Itoa64(ts) + `,"entries":[`)
	n := 0
	emit := func(track int, title string, start, stop, offset int64, queued bool, by, note string, pay, at int64, relay bool) {
		if n > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"track":` + text.Itoa(track) + `,"title":` + text.Str(title) +
			`,"start":` + text.Itoa64(start) + `,"end":` + text.Itoa64(stop) + `,"offset":` + text.Itoa64(offset) +
			`,"queued":` + strconv.FormatBool(queued) + `,"by":` + text.Str(by) + `,"note":` + text.Str(note) + `,"sponsored":` + text.Itoa64(pay) + `,"at":` + text.Itoa64(at) + `,"relay":` + strconv.FormatBool(relay) + `}`)
		n++
	}
	cur := ts
	for cur < end && n < 60 {
		var slot *Slot
		next := int64(-1)
		sl := st.slots()
		for i := range sl {
			s := &sl[i]
			if cur >= s.Start && cur < s.Start+s.Dur {
				slot = s
				break
			}
			if s.Start > cur && (next < 0 || s.Start < next) {
				next = s.Start
			}
		}
		if slot != nil {
			stop := slot.Start + slot.Dur
			if title := catalog.PlayableTitle(slot.Track); title != "" {
				emit(slot.Track, title, slot.Start, stop, 0, true, slot.By.String(), slot.shownNote(), slot.Pay, slot.At, false)
			}
			cur = stop
			continue
		}
		track, off, dur, ok := st.between(cur)
		relay := st.id == MainStation // not Main's own slot: the hour's genre station, simulcast
		if !ok {
			if next < 0 {
				break
			}
			cur = next
			continue
		}
		stop := cur + dur - off
		if next >= 0 && next < stop {
			stop = next // the rotation (or Main's relay) pauses for the programmed slot
		}
		if title := catalog.PlayableTitle(track); title != "" {
			if s, ok := st.pickAt(cur); ok && s.Track == track { // Main simulcasting a genre station's pick
				emit(track, title, cur-off, stop, off, true, s.By.String(), s.shownNote(), s.Pay, s.At, relay)
			} else {
				emit(track, title, cur-off, stop, off, false, "", "", 0, 0, relay)
			}
		}
		cur = stop
	}
	b.WriteString(`],"booked":[`)
	n = 0
	for _, s := range st.slots() {
		if s.At > 0 && s.Start+s.Dur > ts-foldAfter {
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(`{"track":` + text.Itoa(s.Track) + `,"start":` + text.Itoa64(s.Start) + `,"end":` + text.Itoa64(s.Start+s.Dur) + `,"at":` + text.Itoa64(s.At) + `,"by":` + text.Str(s.By.String()) + `,"note":` + text.Str(s.shownNote()) + `}`)
			n++
		}
	}
	b.WriteString(`]}`)
	return b.String()
}

// StationsJSON lists every station with what it plays now.
func StationsJSON() string {
	t := rd()
	var b strings.Builder
	// newFloor: only tracks above this id may be picked on New this week.
	synced := t.synced()
	floor := synced - newCap
	if floor < 0 {
		floor = 0
	}
	ts := now()
	b.WriteString(`{"pending":` + text.Itoa(catalog.TrackCount()-synced) + `,"newFloor":` + text.Itoa(floor) + `,"stations":[`)
	for id := 0; id < numStations; id++ {
		st := t.station(id)
		if id > 0 {
			b.WriteString(",")
		}
		track, offset, isQueued := st.onAir(ts)
		live, loop := st.rotating()
		b.WriteString(`{"id":` + text.Itoa(id) + `,"name":` + text.Str(StationName(id)) + `,"genre":` + text.Itoa(st.genre) +
			`,"tracks":` + text.Itoa(live) + `,"loop":` + text.Itoa64(loop) + `,"queued":` + text.Itoa(st.queued(ts)) +
			`,"now":{"track":` + text.Itoa(track) + `,"offset":` + text.Itoa64(offset) + `,"queued":` + strconv.FormatBool(isQueued) + `}}`)
	}
	b.WriteString(`]}`)
	return b.String()
}
