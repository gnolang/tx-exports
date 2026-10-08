package radio

import (
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v1"
)

// ---- Station internals: the rotation loop and the schedule over it ----

// paused is the airtime taken by programmed slots before ts. It reads an
// undecoded schedule as it is, and keeps its result until the schedule
// moves (setSlots, move).
func (st *station) paused(ts int64) int64 {
	if st.pzOK && st.pzAt == ts {
		return st.pz
	}
	var p int64
	if st.decoded {
		for _, s := range st.sched {
			if ts <= s.Start {
				break
			}
			if ts >= s.Start+s.Dur {
				p += s.Dur
			} else {
				p += ts - s.Start
			}
		}
	} else {
		for c := (cursor{s: st.raw}); c.next() && ts > c.start; {
			if ts >= c.end {
				p += c.end - c.start
			} else {
				p += ts - c.start
			}
		}
	}
	st.pz, st.pzAt, st.pzOK = p, ts, true
	return p
}

// pos is the position in the rotation loop at ts.
func (st *station) pos(ts int64) int64 {
	total := st.total()
	if total == 0 {
		return 0
	}
	p := (ts - st.epoch - st.paused(ts)) % total
	if p < 0 {
		p += total
	}
	return p
}

// anchor sets the epoch so that the rotation is at position p at ts.
func (st *station) anchor(ts, p int64) {
	st.epoch, st.dirty = ts-st.paused(ts)-p, true
}

func (st *station) rotationAt(ts int64) (slot, track int, offset, dur int64, ok bool) {
	if st.total() == 0 {
		return 0, 0, 0, 0, false
	}
	slot, track, offset, ok = st.find(st.pos(ts))
	if !ok {
		return 0, 0, 0, 0, false
	}
	_, dur = st.rotSlot(slot)
	return slot, track, offset, dur, true
}

// rotating is how many tracks play on the station and its loop length: on
// Main, which simulcasts the genre stations, theirs added up.
func (st *station) rotating() (live int, loop int64) {
	if st.id != MainStation {
		return st.live, st.total()
	}
	for g := 1; g <= NumGenres; g++ {
		gs := st.t.station(g)
		live, loop = live+gs.live, loop+gs.total()
	}
	return
}

// playing is the programmed slot on air at ts.
func (st *station) playing(ts int64) (Slot, bool) {
	for _, s := range st.slots() {
		if ts >= s.Start && ts < s.Start+s.Dur {
			return s, true
		}
	}
	return Slot{}, false
}

// between is what a station plays at ts outside programmed slots: its
// rotation, or on Main a simulcast of the hour's genre station (flow.gno):
// what that station plays at ts, its own picks included, cut where it pauses
// for a pick and at the hour (the app's top-of-hour jingle covers the cut).
// The genre station never jumps (its edits re-anchor it), so neither does Main.
func (st *station) between(ts int64) (track int, off, dur int64, ok bool) {
	if st.id != MainStation {
		_, track, off, dur, ok = st.rotationAt(ts)
		return
	}
	g := hourGenre(st.t, ts)
	if g == 0 {
		return
	}
	gs := st.t.station(g)
	if s, prog := gs.playing(ts); prog {
		track, off, dur, ok = s.Track, ts-s.Start, s.Dur, true
	} else if _, track, off, dur, ok = gs.rotationAt(ts); !ok {
		return
	} else {
		for _, s := range gs.slots() { // the genre rotation pauses for its next pick
			if s.Start > ts && s.Start < ts-off+dur {
				dur = s.Start - (ts - off)
			}
		}
	}
	if end := ts - ts%3600 + 3600; ts-off+dur > end {
		dur = end - (ts - off)
	}
	if st.t.dropped(MainStation, track) {
		track = 0 // dropped from Main: silence (onAir and ScheduleJSON skip it)
	}
	return
}

// relay is the station Main simulcasts at ts (the hour's genre station), or st.
func (st *station) relay(ts int64) *station {
	if st.id == MainStation {
		if g := hourGenre(st.t, ts); g != 0 {
			return st.t.station(g)
		}
	}
	return st
}

// pickAt is the listener pick on air at ts: the station's own or, on Main
// between its own picks, the genre station's pick it simulcasts, so Main
// shows, tips and reports it as that pick.
func (st *station) pickAt(ts int64) (Slot, bool) {
	if s, ok := st.playing(ts); ok || st.id != MainStation {
		return s, ok
	}
	if r := st.relay(ts); r != st {
		if s, ok := r.playing(ts); ok && !st.t.dropped(MainStation, s.Track) {
			return s, true
		}
	}
	return Slot{}, false
}

func (st *station) onAir(ts int64) (int, int64, bool) {
	if s, ok := st.pickAt(ts); ok {
		if _, _, _, ok := catalog.TrackBrief(s.Track); ok {
			return s.Track, ts - s.Start, true
		}
		return 0, 0, false // a removed programmed slot plays silence until its end
	}
	track, off, _, ok := st.between(ts)
	if !ok {
		return 0, 0, false
	}
	if _, _, _, playable := catalog.TrackBrief(track); !playable {
		return 0, 0, false // hidden but not refreshed yet: silence, never its title
	}
	return track, off, false
}

// queued counts the listener slots not ended yet.
func (st *station) queued(ts int64) int {
	n := 0
	for _, s := range st.slots() {
		if s.Start+s.Dur > ts {
			n++
		}
	}
	return n
}

// add appends a track at the end of the loop and returns its slot; listeners do not move.
func (st *station) add(trackID int, dur int64, ts int64) int {
	p := st.pos(ts)
	i := st.appendRot(trackID, dur)
	if dur > 0 {
		st.addLive(1)
	}
	st.anchor(ts, p)
	return i
}

// join puts a synced track in New or Choice, a ring of keep slots: once
// full, the oldest slot is reused in place, so the rotation never outgrows
// keep whatever the catalog size or the number of picks. The track it held
// leaves the ring's index, so Refresh leaves it out. Listeners do not jump:
// replace re-anchors around the change.
func (st *station) join(trackID int, dur int64, ts int64, keep int) {
	p, found := st.ringFind(trackID)
	st.joinAt(p, found, trackID, dur, ts, keep)
}

// joinAt is join for a track at position p of the ring's index (ringFind).
func (st *station) joinAt(p int, found bool, trackID int, dur int64, ts int64, keep int) {
	if st.full() {
		return // no room in the record now: the track misses this ring (Choice takes it again with a later pick or Sync)
	}
	i := st.ring % keep
	st.ring++
	st.dirty = true
	if st.count() < keep {
		st.ringIndex(p, found, trackID, st.add(trackID, dur, ts))
		return
	}
	old, _ := st.rotSlot(i)
	st.replace(i, trackID, dur, ts)
	if q := st.ringUnindex(old, i); q >= 0 && q < p {
		p--
	} else if q == p && old == trackID {
		found = false
	}
	st.ringIndex(p, found, trackID, i)
}

// choose adds a synced track to Listeners' choice unless it is already there.
func choose(t *tx, trackID int, dur int64, ts int64) {
	if trackID < 1 || trackID > t.synced() {
		return // not ingested yet
	}
	cs := t.station(ChoiceStation)
	p, in := cs.ringFind(trackID)
	if in {
		return
	}
	if t.dropped(ChoiceStation, trackID) {
		dur = 0
	}
	cs.joinAt(p, false, trackID, dur, ts, choiceCap)
}

// slot returns a track's index in this station's rotation. Main has no
// rotation (it simulcasts the genre stations); New and Choice keep an index;
// genre stations look the slot up in homes.
func (st *station) slot(trackID int) (int, bool) {
	switch {
	case st.id == MainStation:
		return 0, false
	case st.ringed():
		return st.ringSlot(trackID)
	}
	return homeSlot(st.t.homes(trackID), st.id)
}

// setDuration changes slot i and re-anchors so the song on air keeps playing
// (or, if it is the one removed, the next one starts now). O(n/Size + Size).
func (st *station) setDuration(i int, d int64, ts int64) {
	id, old := st.rotSlot(i)
	if old == d {
		return
	}
	p := st.pos(ts)
	prefix := st.prefixBefore(i)
	np := p
	switch {
	case st.total() == 0 || p < prefix:
		// the change is ahead of the listeners
	case p >= prefix+old:
		np = p - old + d // the change is behind them
	default:
		// the slot on air changes
		if p-prefix >= d {
			np = prefix + d // cut short: the next track starts now
		}
	}
	st.setRot(i, id, d)
	if old == 0 && d > 0 {
		st.addLive(1)
	} else if old > 0 && d == 0 {
		st.addLive(-1)
	}
	if total := st.total(); total > 0 {
		st.anchor(ts, np%total)
	}
}

// replace puts another track in slot i, as setDuration(i, 0), a new id,
// then setDuration(i, d) would, in one rotation write: the old track stops
// if on air (the next starts now), listeners do not jump.
func (st *station) replace(i, id int, d int64, ts int64) {
	_, old := st.rotSlot(i)
	if old == 0 && d == 0 {
		st.setRot(i, id, 0) // the old sequence left the epoch alone
		return
	}
	p, prefix := st.pos(ts), st.prefixBefore(i)
	np := p
	switch {
	case st.total() == 0 || p < prefix:
	case p >= prefix+old:
		np = p - old + d
	default:
		np = prefix + d // the slot on air ends now
	}
	st.setRot(i, id, d)
	if old == 0 && d > 0 {
		st.addLive(1)
	} else if old > 0 && d == 0 {
		st.addLive(-1)
	}
	if total := st.total(); total > 0 {
		st.anchor(ts, np%total)
	}
}

// fold moves programmed slots that ended long ago into the epoch.
func (st *station) fold(ts int64) {
	sl := st.slots()
	i := 0
	for i < len(sl) && sl[i].Start+sl[i].Dur <= ts-foldAfter {
		s := sl[i]
		st.epoch += s.Dur
		if s.Note != "" { // only a dedication has reports
			st.t.del(cNotes, noteKey(st.id, s.Start))
		}
		if s.At > 0 { // the replay gap counts from when a booked pick aired
			st.setPicked(s.Track, s.Start)
		}
		i++
	}
	if i > 0 {
		st.setSlots(sl[i:])
	}
}

// dropSlots removes a track's programmed slots; one on air ends now. It
// returns the sponsored ones, which no longer air in full: their payout goes
// back to the artist (release).
func (st *station) dropSlots(trackID int, ts int64) (cut []hold) {
	var out []Slot
	changed := false
	for _, s := range st.slots() {
		if s.Track == trackID && s.Pay > 0 && s.Start+s.Dur > ts {
			if h, ok := unsponsor(st.t, st.id, s, ts); ok {
				cut = append(cut, h)
			}
		}
		if s.Track == trackID {
			if s.Start >= ts {
				// a later pick may reuse this start: its reports go too
				if s.Note != "" {
					st.t.del(cNotes, noteKey(st.id, s.Start))
				}
				changed = true
				continue
			}
			if s.Start+s.Dur > ts {
				s.Dur = ts - s.Start
				changed = true
			}
		}
		out = append(out, s)
	}
	if changed {
		st.setSlots(out)
	}
	return cut
}

// The replay record of a station (in its record: a pick changes both) is
// fixed-width entries, the track (4 digits) then the pick time (6), read by
// slicing.
const pickW = 10

// lastPicked is when a track was last picked on the station, within replayGap.
func (st *station) lastPicked(trackID int) (int64, bool) {
	rec := st.picks
	key := store.Fixed(int64(trackID), 4)
	for i := 0; i+pickW <= len(rec); i += pickW {
		if rec[i:i+4] == key {
			return store.Num(rec, i+4, 6), true
		}
	}
	return 0, false
}

// setPicked records a pick time (the later one wins) and drops the picks
// older than replayGap, which no check reads: the record stays as short as
// the picks of the last three hours.
func (st *station) setPicked(trackID int, at int64) {
	rec := st.picks
	key := store.Fixed(int64(trackID), 4)
	cut := now() - replayGap
	out := ""
	for i := 0; i+pickW <= len(rec); i += pickW {
		when := store.Num(rec, i+4, 6)
		if rec[i:i+4] == key {
			if when > at {
				at = when
			}
		} else if when > cut {
			out += rec[i : i+pickW]
		}
	}
	if at > cut {
		out += key + store.Fixed(at, 6)
	}
	if out != rec {
		st.picks, st.dirty = out, true
	}
}

// shownNote is the dedication listeners see ("" once hidden).
func (s Slot) shownNote() string {
	if s.NoteHidden {
		return ""
	}
	return s.Note
}

// picker is the listener whose pick of trackID plays at ts on the station,
// or ended less than tipGrace ago, read from the stored schedule: "" when
// none, a sponsored pick (its artist already refunds it) or the admin's (a
// curator pick: GnoRadio takes no share), and the station the pick lives on
// (on Main, the genre station whose pick it simulcast).
func (st *station) picker(trackID int, ts int64, adm address) (address, int) {
	var by address
	for c := (cursor{s: st.raw}); c.next(); {
		b := st.raw[c.b:c.i]
		if c.start > ts || ts >= c.end+tipGrace || int(dec[b[3]]<<18|dec[b[4]]<<12|dec[b[5]]<<6|dec[b[6]]) != trackID || store.Num(b, 17, 4) != 0 {
			continue
		}
		if p := address(b[23 : 23+int(dec[b[22]])]); p != adm {
			by = p
		}
	}
	if by == "" && st.id == MainStation && !st.t.dropped(MainStation, trackID) {
		for _, at := range []int64{ts, ts - tipGrace} { // the pick may have ended in the hour before
			if r := st.relay(at); r != st {
				if by, _ = r.picker(trackID, ts, adm); by != "" {
					return by, r.id
				}
			}
		}
	}
	return by, st.id
}
