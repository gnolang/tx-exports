package radio

import (
	"chain"
	"chain/runtime"
	"crypto/ed25519"
	"encoding/hex"
	"strconv"

	"gno.land/p/nym-alexiscolin000/gnoradio/safe/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v2"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// ---- Programming ----

// Queue programs a track on a station and adds it to Listeners' choice. It
// starts after the last track a listener programmed, or when the song on air
// ends: nothing is cut. On Main it starts at once over the hour's relay (the
// app crossfades), which resumes after it.
// Limits per station: one waiting slot per listener, two per artist, a track
// at most once, 30 upcoming.
func Queue(cur realm, stationID, trackID int) {
	queue(cur, userCaller(cur), stationID, trackID, false, false, "", 0)
}

// QueueAt is Queue for a chosen time: at (unix, UTC) between 15 minutes and
// 24 hours from now; 0 is Queue. The pick starts at the first track boundary
// at or after at (on Main, at at: the relay's track fades out as for any
// pick), unless listener picks fill that moment, then right after them. It
// keeps its time: later picks go before it only if they end by then, else
// after it. Every Queue rule applies, the 3-hour replay gap around at; the
// 2-hour airtime cap does not, but at most 4 picks are booked per station and
// clock hour and at most 15 booked picks wait per station.
func QueueAt(cur realm, stationID, trackID int, at int64) {
	queue(cur, userCaller(cur), stationID, trackID, false, false, "", at)
}

// QueueWithNote is Queue with a dedication shown on air ("for Marie!"). The
// moderation robot judges it before the transaction (word filter and a
// moderation model, app/netlify/functions/dedication.mts) and signs
// NoteMessage(note, expires): the listener sends that certificate and pays
// their own gas, so a dedication shows at once and costs GnoRadio nothing. It
// must also pass p/gnoradio/safe (plain text, no link, no blocked word).
// Listeners can report it: three reports hide it and give its author a strike;
// a second hidden dedication within a week pauses their dedications for a
// week (ReportNote). The pause is per wallet: an author can dedicate again
// from a fresh one, which reports hide and pause the same way (accepted
// residual; the robot and the word filter still judge every note).
func QueueWithNote(cur realm, stationID, trackID int, note string, expires int64, sigHex string) {
	queueWithNote(cur, stationID, trackID, 0, note, expires, sigHex)
}

// QueueWithNoteAt is QueueWithNote for a chosen time (see QueueAt; 0: now).
func QueueWithNoteAt(cur realm, stationID, trackID int, at int64, note string, expires int64, sigHex string) {
	queueWithNote(cur, stationID, trackID, at, note, expires, sigHex)
}

func queueWithNote(cur realm, stationID, trackID int, at int64, note string, expires int64, sigHex string) {
	caller := userCaller(cur)
	if until, ok := data.Get(cMuted, caller.String()); ok && now() < text.MustAtoi64(until) {
		panic("radio: your dedications are paused after reports, pick without one")
	}
	if why := safe.Note(note, maxNote); why != "" {
		panic("radio: dedication: " + why)
	}
	checkNote(caller, stationID, note, expires, sigHex)
	queue(cur, caller, stationID, trackID, false, false, note, at)
}

// NoteMessage is what the moderation robot signs to approve a dedication by
// author on stationID until expires (unix seconds), on this chain and this
// GnoRadio deployment (its data realm) only:
// "gnoradio-note|<chain id>|<data realm>|<author>|<station>|<note>|<expires>".
// A certificate seen in a public transaction serves no other wallet,
// station or deployment.
func NoteMessage(author address, stationID int, note string, expires int64) string {
	return "gnoradio-note|" + runtime.ChainID() + "|" + dataPath + "|" + author.String() + "|" + text.Itoa(stationID) + "|" + note + "|" + text.Itoa64(expires)
}

func checkNote(author address, stationID int, note string, expires int64, sigHex string) {
	v, _ := data.Get(cConfig, "modbot")
	key, _ := hex.DecodeString(v)
	if len(key) == 0 {
		panic("radio: dedications are paused, pick without one")
	}
	if ts := now(); expires <= ts || expires > ts+noteCertLife {
		panic("radio: the dedication check expired, send it again")
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil || len(sig) != 64 || !ed25519.Verify(key, []byte(NoteMessage(author, stationID, note, expires)), sig) {
		panic("radio: this dedication was not approved, send it again")
	}
}

// CuratorQueue programs a track like Queue but without the per-listener and
// per-artist quotas (the duplicate, genre and queue-size rules still apply).
// Radio admin only.
func CuratorQueue(cur realm, stationID, trackID int) {
	onlyAdmin(cur)
	queue(cur, cur.Previous().Address(), stationID, trackID, true, false, "", 0)
}

func queue(cur realm, caller address, stationID, trackID int, curator, sponsored bool, note string, at int64) {
	noPayment()
	t := rd()
	st := t.station(stationID)
	who := caller // own picks earn nothing: only a listener's needs the check
	if curator || sponsored {
		who = ""
	}
	artistID, genre, dur, playable, own := catalog.TrackBriefFor(trackID, who)
	if !playable {
		panic("radio: unknown track")
	}
	if st.genre != 0 && genre != st.genre {
		panic("radio: this track does not belong to this station")
	}
	if t.dropped(st.id, trackID) { // a pick must not undo the admin's DropSlot
		panic("radio: this track was removed from this station")
	}
	if st.id == NewStation && trackID <= t.synced()-newCap {
		panic("radio: only new tracks can be picked on New this week")
	}
	ts := now()
	airs := ts // when the pick is meant to air
	if at != 0 {
		if at < ts+bookMin || at > ts+bookMax {
			panic("radio: book a time between 15 minutes and 24 hours from now")
		}
		airs = at
	}
	st.fold(ts)
	start := st.place(ts, dur, at)
	// Main's simulcast is not a slot: picking the track it plays would
	// restart it over itself.
	if st.id == MainStation && at == 0 {
		if _, prog := st.playing(ts); !prog {
			if tr, _, _, _ := st.between(ts); tr == trackID {
				panic("radio: this track is already programmed")
			}
		}
	}
	// The replay gap counts from when the pick really airs: a pick for now
	// may wait up to 2 hours behind others, a booked one keeps its time.
	gapAt := airs
	if at == 0 {
		gapAt = start
	}
	// realign may still move a booked pick by up to a track: around one,
	// the replay gap takes that much more.
	gap := int64(replayGap)
	if at != 0 {
		gap += maxTrack
	}
	upcoming, kept, perArtist, booked, bookedUp := 0, 0, 0, 0, 0
	var ahead int64 // listener airtime for now still to play
	for _, s := range st.slots() {
		// A slot of the track blocks it within the replay gap.
		if s.Track == trackID && s.Start+s.Dur > ts {
			g := gap
			if s.At > 0 {
				g = replayGap + maxTrack
			}
			if abs64(s.Start-gapAt) < g {
				panic("radio: this track is already programmed")
			}
		}
		// A booked pick enters lastpick when folded, an hour after it ends:
		// until then its slot keeps the replay gap.
		if s.Track == trackID && s.At > 0 && s.Start+s.Dur <= ts && !curator && gapAt-s.Start < replayGap {
			panic("radio: this track was picked here less than 3 hours ago, pick another one")
		}
		kept++ // aired or not: a listener slot stays in the record until it folds
		if at != 0 && s.At/3600 == at/3600 {
			booked++ // aired ones too: at most maxBookedHour per clock hour
		}
		if s.Start+s.Dur <= ts {
			continue
		}
		upcoming++
		if s.At > 0 {
			bookedUp++
		}
		if !curator && s.Start > ts && s.By == caller {
			panic("radio: you already have a track waiting on this station")
		}
		if s.artist == artistID {
			perArtist++
		}
		if s.At == 0 {
			ahead += s.Start + s.Dur - max64(s.Start, ts)
		}
	}
	if upcoming >= maxQueue || kept >= maxKept {
		panic("radio: the queue is full, try again later")
	}
	// Bookings may cover the next 24 hours: they take at most half the
	// queue, so they never leave picks for now without room.
	if at != 0 && bookedUp >= maxBooked {
		panic("radio: booked picks are full on this station, pick for now or later")
	}
	if booked >= maxBookedHour {
		panic("radio: 4 picks are already booked for that hour here, choose another time")
	}
	// No track on a loop: many wallets cannot replay one song for hours.
	if last, ok := st.lastPicked(trackID); ok && !curator && gapAt-last < gap {
		panic("radio: this track was picked here less than 3 hours ago, pick another one")
	}
	if !curator {
		if last := lastPickAt(t, caller, st.id); last > 0 && ts-last < queueCooldown {
			panic("radio: you can queue one track per station every 30 minutes")
		}
		if at == 0 && ahead+dur > maxAheadAir {
			panic("radio: this station is programmed two hours ahead, try again later")
		}
	}
	if !curator && perArtist >= maxPerArtistQ {
		panic("radio: this artist already has 2 tracks in the queue")
	}
	if sponsored {
		sponsorQuota(st, artistID, dur, airs, gapAt)
	}
	if at == 0 {
		st.setPicked(trackID, start) // a booked pick is in the schedule; fold records it once aired
	}
	var pay int64
	if sponsored {
		pay = reserve(cur, t, caller, st.id, trackID, start, dur, Slot{Start: start, Dur: dur, At: at}.held())
	}
	st.put(Slot{Track: trackID, Start: start, Dur: dur, By: caller, Note: note, Pay: pay, At: at, artist: artistID})
	if st.full() {
		panic("radio: this station is full for now, try again later")
	}
	// Dedications use only the room the station's other listener slots, their
	// replay entries and a full curator top cannot need: plain picks always
	// fit (TestChoiceRecordWorstCase).
	if note != "" && st.size()+noteReserve(st, kept) > maxRecord-recordHeadroom {
		panic("radio: dedications are full on this station for now, pick without one")
	}
	kind := "queue"
	if curator {
		kind = "curator"
	} else if sponsored {
		kind = "sponsored"
	}
	recordActivity(t, kind, caller, trackID, st.id, start)
	// A sponsored pick is paid for by its artist: it feeds neither Listeners'
	// choice nor the curator ranking, and only keeps the cooldown. Nor does
	// an artist's (or a collaborator's) pick of their own track (an alt
	// wallet remains a residual, as for any sybil pick).
	switch {
	case sponsored || own:
		markPick(t, caller, st.id)
	case !curator:
		choose(t, trackID, dur, ts)
		credit(t, caller, st.id, 1, 0, 0)
	}
	save(cur, t)
	chain.Emit("Queued", "curator", strconv.FormatBool(curator), "station", text.Itoa(st.id), "track", text.Itoa(trackID), "by", caller.String(), "start", text.Itoa64(start), "sponsored", text.Itoa64(pay), "at", text.Itoa64(at))
}

// place says when a new pick of d seconds starts. A pick for now starts when
// the song on air ends (at once on Main, over the relay), after the picks
// for now already waiting; one booked for at starts at the first track
// boundary at or after at. Both go around booked picks: before one only if
// they end by its time, else after it.
func (st *station) place(ts, d, at int64) int64 {
	t := at
	if at == 0 {
		t = ts
		if st.id != MainStation {
			if _, _, off, slotDur, ok := st.rotationAt(ts); ok {
				t = ts + slotDur - off
			}
		}
		for _, s := range st.slots() {
			// after the picks for now, and after a booked pick on air (the
			// rotation is paused under it: its track would only play a
			// fragment before the pick)
			if end := s.Start + s.Dur; end > ts && (s.At == 0 || s.Start <= ts) {
				t = end
			}
		}
	} else {
		t = st.boundary(at)
	}
	for _, s := range st.slots() {
		if s.Start+s.Dur <= t {
			continue
		}
		if s.Start <= t {
			t = s.Start + s.Dur // playing then: wait for its end
			continue
		}
		limit := s.Start
		if s.At > 0 {
			limit = s.At // a booked pick may come back to its own time
		}
		if t+d <= limit {
			break
		}
		t = s.Start + s.Dur
	}
	return t
}

// boundary is the first track boundary at or after t outside listener
// picks: t itself on Main (the relay fades out) or inside a programmed
// slot (place waits for its end), else the end of the rotation track on air.
func (st *station) boundary(t int64) int64 {
	if st.id == MainStation {
		return t
	}
	for _, s := range st.slots() {
		if s.Start <= t && t < s.Start+s.Dur {
			return t
		}
	}
	if _, _, off, d, ok := st.rotationAt(t); ok && off > 0 {
		return t + d - off
	}
	return t
}

// put puts a new listener slot in the schedule. Elsewhere than on Main the
// slots after it are realigned: they moved with the rotation.
func (st *station) put(n Slot) {
	sl, i := insert(st.slots(), n)
	st.setSlots(sl)
	if st.id != MainStation {
		st.realign(i)
	}
}

// insert puts s in a schedule, sorted by start, and returns its index.
func insert(sl []Slot, s Slot) ([]Slot, int) {
	i := len(sl)
	for i > 0 && sl[i-1].Start > s.Start {
		i--
	}
	sl = append(sl, Slot{})
	copy(sl[i+1:], sl[i:])
	sl[i] = s
	return sl, i
}

// realign re-times the listener slots after index i once the rotation moved
// under them: a booked one to the first boundary at or after its time (or
// right after the slot before it), a pick that followed the slot before it
// still follows it, a pick for now that waited for a rotation track after a
// gap waits for the new end of that track. Sponsored records, note reports and
// the replay record move along.
// ponytail: only queue realigns; Unqueue, DropSlot and rotation edits leave
// booked slots in place (the rotation track then pauses around them, as
// around any pick after a removed one); realign there too if it matters.
func (st *station) realign(i int) {
	sl := st.slots()
	var paused int64 // airtime of the slots before k: they all ended by its time (paused, inline)
	for _, s := range sl[:i+1] {
		paused += s.Dur
	}
	total := st.total()
	oldEnd := sl[i].Start + sl[i].Dur
	var notes []int64 // the dedicated slots moved: old start, new start
	for k := i + 1; k < len(sl); k++ {
		prev, s := sl[k-1], sl[k]
		end := prev.Start + prev.Dur
		start := max64(s.Start, end)
		t := s.At
		if t == 0 && s.Start != oldEnd {
			t = s.Start // a pick for now that started on a rotation boundary after a gap
		}
		if t > end && total > 0 { // the rotation plays until then: wait for the end of that track
			start = t
			p := (t - st.epoch - paused) % total
			if p < 0 {
				p += total
			}
			if slot, _, off, ok := st.find(p); ok && off > 0 {
				_, d := st.rotSlot(slot)
				start += d - off
			}
		} else if s.At > 0 || s.Start == oldEnd {
			start = max64(s.At, end)
		}
		oldEnd = s.Start + s.Dur
		paused += s.Dur
		if start != s.Start {
			if s.Note != "" {
				notes = append(notes, s.Start, start)
			}
			st.move(k, start)
		}
	}
	st.moveNotes(notes)
}

// moveNotes re-keys the reports of moved dedications: all read, then all
// removed, then all written, so that a slot moved to where another one
// started never takes or loses its reports.
func (st *station) moveNotes(moves []int64) {
	t := st.t
	recs := make([]string, len(moves)/2)
	for j := 0; j < len(moves); j += 2 {
		recs[j/2] = t.val(cNotes, noteKey(st.id, moves[j]))
	}
	for j := 0; j < len(moves); j += 2 {
		t.del(cNotes, noteKey(st.id, moves[j]))
	}
	for j := 0; j < len(moves); j += 2 {
		if recs[j/2] != "" {
			t.set(cNotes, noteKey(st.id, moves[j+1]), recs[j/2])
		}
	}
}

// move re-times slot k, with its sponsored record and its replay record
// (its dedication's reports move with moveNotes).
func (st *station) move(k int, start int64) {
	t := st.t
	s := &st.sched[k]
	if s.Pay > 0 {
		k := sponsorKey(st.id, s.By)
		if rec, ok := t.get(cSponsor, k); ok && text.Atoi64(store.Field(rec, 0)) == s.Start {
			f := store.Fields(rec)
			t.set(cSponsor, k, store.Rec(text.Itoa64(start), f[1], text.Itoa64(start+s.Dur), f[3], f[4], f[5], f[6]))
		}
	}
	if s.At == 0 {
		st.setPicked(s.Track, start) // a pick for now: the replay gap counts from its airing
	}
	s.Start = start
	st.dirty, st.pzOK = true, false
}

// noteReserve is the record room the other plain picks a station may still
// take need: a slot and a replay entry each, plus its curator top at full.
func noteReserve(st *station, kept int) int {
	return (maxKept-kept-1)*(plainSlot+pickW) + topMax - len(st.top)
}
