// Package radio is GnoRadio's radio rules, release 1: a main station that
// plays the whole catalog through the genre stations, one station per genre,
// "New this week" (the newest tracks) and "Listeners' choice" (the tracks
// listeners picked).
// Everyone tuned to a station hears the same track at the same second,
// computed from block time; no streaming server is involved. Between picks
// the main station simulcasts one genre station an hour, by the time of day
// (flow.gno); it has no rotation of its own.
//
// Each station has a rotation (every playable track of its genre, looping)
// stored in fixed-size blocks so that every operation costs the same
// whatever the catalog size, and a short schedule of tracks programmed by
// listeners. While a programmed track plays the rotation pauses, then
// resumes where it was. Adding, removing or editing a track never makes
// listeners jump.
//
// It keeps no state but its admin role. Every record lives in the data realm
// (gno.land/r/nym-alexiscolin000/gnoradio/data), in the "radio/…" collections only the current
// radio writer may change (db.gno). It reads the catalog through its value
// getters; sponsored picks are paid from data's vault through the catalog.
package radio

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v2"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// NumGenres is the catalog's: genre stations are 1..NumGenres.
const NumGenres = catalog.NumGenres

// Station ids are stored keys in the permanent data realm (schedules, drops,
// notes, curator ranks): Main 0, genres 1..NumGenres, New, Choice. A later
// release must keep them, and add any new station after Choice.
const (
	MainStation     = 0
	NewStation      = NumGenres + 1 // the newest newCap ingested tracks
	ChoiceStation   = NumGenres + 2 // the last choiceCap distinct listener picks
	numStations     = ChoiceStation + 1
	newCap          = 300
	choiceCap       = 500
	maxQueue        = 30 // upcoming slots per station
	maxPerArtistQ   = 2  // upcoming slots per artist and station
	maxSyncBatch    = 200
	maxRefreshBatch = 50
	foldAfter       = 3600          // programmed slots ended this long ago fold into the epoch
	queueCooldown   = 1800          // a listener may queue once per station every 30 minutes
	replayGap       = 3 * 3600      // a track picked on a station cannot be picked there again for 3 hours, by anyone
	maxAheadAir     = 7200          // listener-programmed airtime ahead on a station, seconds
	maxNote         = 40            // characters of a dedication
	noteCertLife    = 900           // seconds a moderation certificate may still have to live
	hideAfter       = 3             // distinct reputable listeners (sponsorBlock) reporting a dedication hide it
	muteFor         = 7 * 24 * 3600 // a second hidden dedication within this time mutes its author this long
	bookMin         = 15 * 60       // a pick booked for a time: at least this far ahead
	bookMax         = 24 * 3600     // and at most this far
	maxBookedHour   = 4             // booked picks per station and clock hour (UTC)
	maxKept         = 3 * maxQueue  // listener slots a station keeps, aired ones included until they fold
	maxBooked       = maxQueue / 2  // booked picks waiting per station
	maxTrack        = 1200          // the catalog's longest track, seconds
	recordHeadroom  = 1024          // bytes a station record keeps free for the writes that follow a pick
	plainSlot       = 72            // record bytes of a listener slot without a dedication: 25, an address, at most 7 of gap
)

// dataPath is the data realm: certificates are bound to it.
const dataPath = "gno.land/r/nym-alexiscolin000/gnoradio/data"

// Slot is a track a listener (or a curator) programmed on a station. Dur is
// captured when queued so later catalog edits cannot move the timeline.
type Slot struct {
	Track      int
	Start      int64
	Dur        int64
	By         address
	Note       string // the picker's dedication, checked by p/gnoradio/safe and the moderation robot
	NoteHidden bool   // hidden by reports or the admin
	Pay        int64  // a sponsored pick: the ugnot its artist reserved to refund the picker (sponsor.gno)
	At         int64  // a booked pick: the time asked (unix); it starts at the first track boundary at or after it
	artist     int    // a listener slot's artist (a track never changes artist): the per-artist rules read it
	body       string // the encoded slot without its start, reused while it does not change (db.gno)
	bdur       int64  // the duration body holds
}

var (
	self  string     // this realm's path
	admin *role.Role // the radio admin; nil when a release before renounced it
)

// init takes the admin over from the previous release (radio/config
// "admin"), or names the deployer. While this realm is the radio writer
// (release 1 at deploy) it also makes the radio's collections.
func init(cur realm) {
	self = cur.PkgPath()
	holder, mirrored := data.Get(cConfig, "admin")
	if !mirrored {
		deployer := unsafe.OriginCaller()
		if deployer == "" && runtime.ChainID() == "dev" {
			deployer = chain.PackageAddress(self + "/dev") // gno test: a key nobody holds
		}
		holder = deployer.String()
	}
	if holder != "" {
		admin = role.New("admin", address(holder))
	}
	if data.Writer("radio") == self {
		setup(cur, address(holder))
	}
}

// ---- Catalog ingestion (permissionless) ----

// Sync ingests up to max catalog tracks not yet on the stations into the
// main station, the station of their genre and New; the catalog's most
// liked tracks join Listeners' choice. Main's flow needs no Sync (flow.gno).
// Anyone may call it. PublishTrack and ImportTrack put each new track on the
// air themselves (publish.gno), so this is a safety net: a track is never
// ingested twice (the flow record counts the synced ones). A track that is
// not playable yet is added silent (duration 0) and Refresh turns it on.
func Sync(cur realm, max int) int {
	noPayment()
	max = store.Limit(max, maxSyncBatch)
	t := rd()
	ts := now()
	n := ingest(t, ts, max, true)
	synced, choice := t.synced(), t.station(ChoiceStation)
	for _, r := range catalog.TopLiked() {
		if id := text.Atoi(r.Key); id <= synced {
			if _, in := choice.ringFind(id); in {
				continue // there already: no need to read the catalog
			}
			if _, _, dur, ok := catalog.TrackBrief(id); ok {
				choose(t, id, dur, ts)
			}
		}
	}
	save(cur, t)
	return n
}

// ingest adds up to max newly published tracks to the stations, and to New
// when joinNew (a launch-catalog import is not a new release).
func ingest(t *tx, ts int64, max int, joinNew bool) int {
	synced := t.synced()
	from := synced + 1
	last := catalog.TrackCount()
	if last > synced+max {
		last = synced + max
	}
	for id := from; id <= last; id++ {
		_, genre, dur, playable := catalog.TrackBrief(id)
		if !playable {
			dur = 0
		}
		home := ""
		if genre >= 1 && genre <= NumGenres {
			home = homeEntry(genre, t.station(genre).add(id, dur, ts))
		}
		if joinNew {
			t.station(NewStation).join(id, dur, ts, newCap)
		}
		t.appendHomes(id, home)
	}
	n := last - synced
	if n > 0 {
		t.setFlowAt(fSynced, 4, last)
		chain.Emit("Synced", "from", text.Itoa(from), "to", text.Itoa(last))
	}
	return n
}

// Refresh re-reads a track from the catalog and updates its rotation slots:
// a hidden track goes silent, a restored one comes back, an edited duration is
// applied. Programmed slots of a track that is no longer playable are dropped.
// Anyone may call it. A slot the admin dropped stays silent.
func Refresh(cur realm, trackID int) {
	noPayment()
	t := rd()
	refresh(cur, t, trackID)
	save(cur, t)
}

// RefreshArtist refreshes up to maxRefreshBatch synced tracks of an artist,
// from offset in the artist's track list, so hiding (or restoring) a whole
// artist takes a few calls instead of one per track. It returns the offset to
// pass next, or 0 when the list is done. Anyone may call it.
func RefreshArtist(cur realm, artistID, offset int) int {
	noPayment()
	n := catalog.ArtistTrackCount(artistID)
	if n == 0 && catalog.ArtistName(artistID) == "" {
		panic("radio: unknown artist")
	}
	if offset < 0 || offset > n {
		offset = 0
	}
	t := rd()
	synced := t.synced()
	for _, id := range catalog.ArtistTrackPage(artistID, offset, maxRefreshBatch) {
		if id >= 1 && id <= synced {
			refresh(cur, t, id)
		}
	}
	save(cur, t)
	if end := offset + maxRefreshBatch; end < n {
		return end
	}
	return 0
}

func refresh(cur realm, t *tx, trackID int) {
	if trackID < 1 || trackID > t.synced() {
		panic("radio: track not synced yet")
	}
	_, genre, dur, playable := catalog.TrackBrief(trackID)
	if !playable {
		dur = 0
	}
	ts := now()
	// Only the stations that hold the track in their rotation need a slot
	// lookup (Main, New and Choice as they say, the genre stations listed in
	// homes). Programmed slots are checked on every station: a genre edit
	// must not leave a slot nobody can silence.
	inGenre := false
	for id := 0; id < numStations; id++ {
		st := t.station(id)
		belongs := st.genre == 0 || st.id == genre
		if i, ok := st.slot(trackID); ok {
			d := dur
			if !belongs || t.dropped(st.id, trackID) {
				d = 0
			}
			st.setDuration(i, d, ts)
			if st.id == genre {
				inGenre = true
			}
		}
		if !playable || !belongs {
			release(cur, st.dropSlots(trackID, ts))
		}
	}
	if !inGenre && genre >= 1 && genre <= NumGenres && dur > 0 {
		t.setHomes(trackID, t.homes(trackID)+homeEntry(genre, t.station(genre).add(trackID, dur, ts)))
	}
	chain.Emit("Refreshed", "track", text.Itoa(trackID), "playable", strconv.FormatBool(playable))
}

// ---- Reads ----

// NowPlaying returns what a station plays at the last block: the track, the
// offset into it in seconds, and whether a listener programmed it. trackID is
// 0 when nothing plays. Clients should prefer ScheduleJSON and their clock.
func NowPlaying(stationID int) (trackID int, offset int64, queued bool) {
	return rd().station(stationID).onAir(now())
}

// OnAirNote returns the dedication of the programmed slot on air ("" when
// none, or once reports hid it).
func OnAirNote(stationID int) string {
	if s, ok := rd().station(stationID).pickAt(now()); ok {
		return s.shownNote()
	}
	return ""
}

// OnAirPay is the refund of the sponsored pick on air (0: none), for labels.
func OnAirPay(stationID int) int64 {
	if s, ok := rd().station(stationID).pickAt(now()); ok {
		return s.Pay
	}
	return 0
}

// UpNext returns the slots listeners programmed on a station that have not
// started yet.
func UpNext(stationID int) []Slot {
	st := rd().station(stationID)
	ts := now()
	var out []Slot
	for _, s := range st.slots() {
		if s.Start > ts {
			if _, _, _, ok := catalog.TrackBrief(s.Track); ok {
				s.Note = s.shownNote()
				out = append(out, s)
			}
		}
	}
	return out
}

// StationCount returns the number of stations (ids 0..StationCount()-1).
func StationCount() int { return numStations }

// StationName is "Main", the genre name, "New this week" or "Listeners' choice".
func StationName(stationID int) string {
	switch mustStation(stationID) {
	case MainStation:
		return "Main"
	case NewStation:
		return "New this week"
	case ChoiceStation:
		return "Listeners' choice"
	default:
		return catalog.GenreName(stationID)
	}
}

// StationInfo returns how many tracks rotate on a station and the loop length.
func StationInfo(stationID int) (tracks int, loop int64, queued int) {
	st := rd().station(stationID)
	tracks, loop = st.rotating()
	return tracks, loop, st.queued(now())
}

// Pending returns how many catalog tracks are not on the stations yet: 0, since
// publishing puts a track on the air (Sync is the safety net).
func Pending() int { return catalog.TrackCount() - rd().synced() }

// PickRules returns the limits on listeners' picks, for pages that explain
// them: one pick per cooldown per station, a track not again within replay,
// at most ahead seconds and queue slots waiting, perArtist waiting per artist,
// booked picks bookFrom to bookTo ahead, bookedPerHour per clock hour and
// booked of the queue slots at most.
func PickRules() (cooldown, replay, ahead int64, queue, perArtist int, bookFrom, bookTo int64, bookedPerHour, booked int) {
	return queueCooldown, replayGap, maxAheadAir, maxQueue, maxPerArtistQ, bookMin, bookMax, maxBookedHour, maxBooked
}

// ---- helpers ----

func now() int64 { return time.Now().Unix() }

func mustStation(id int) int {
	if id < 0 || id >= numStations {
		panic("radio: unknown station")
	}
	return id
}

func userCaller(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("radio: call this directly from your wallet")
	}
	return cur.Previous().Address()
}

func noPayment() {
	if len(unsafe.OriginSend()) != 0 {
		panic("radio: this action does not take coins")
	}
}

func abs64(n int64) int64 {
	if n < 0 {
		return -n
	}
	return n
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
