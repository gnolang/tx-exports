package radio

import (
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v2"
)

// Tracks enter and change through this realm: the catalog accepts
// PublishFor, ImportFor and EditFor from the radio writer only, so a track
// is in the station rotations from the transaction that publishes it, paid
// by its publisher. Nothing waits for Sync, and no robot pays for it.

// PublishTrack publishes a track by the caller's own artist profile (the
// arguments are catalog.PublishFor's) and puts it on the air in the same
// transaction: the main station, its genre station and New this week.
func PublishTrack(cur realm, title string, genre int, duration, license, cmo, credits, audio, audioSHA, cover, coverSHA, splits, rights string) int {
	caller := userCaller(cur)
	noPayment()
	id := catalog.PublishFor(cross(cur), caller, title, genre, duration, license, cmo, credits, audio, audioSHA, cover, coverSHA, splits, rights)
	onAir(cur, id, true)
	return id
}

// ImportTrack adds a curated or Audius track to an unclaimed artist (the
// arguments are catalog.ImportFor's) and puts it on the air, New this week
// left out: an import is not a new release. The catalog admin only, from its
// wallet or a realm that holds the role (a launch import).
func ImportTrack(cur realm, artistID int, title string, genre int, duration, license, credits, audio, audioSHA, cover, coverSHA, sourceURL, attribution string) int {
	noPayment()
	id := catalog.ImportFor(cross(cur), cur.Previous().Address(), artistID, title, genre, duration, license, credits, audio, audioSHA, cover, coverSHA, sourceURL, attribution)
	onAir(cur, id, false)
	return id
}

// maxImportBatch bounds ImportTracks: each track costs a few M gas once the
// realms are loaded, so a full batch stays far under the block's gas.
const maxImportBatch = 25

// ImportTracks imports up to maxImportBatch tracks in one transaction, so the
// realms load once for the batch instead of once per track. batch holds one
// track per line ("\n"), ImportTrack's 12 arguments separated by tabs ("\t";
// neither can appear in a valid field). All or nothing: a bad track panics the
// whole transaction (a malformed line is named before anything is written). It returns the id of the last track. Admin only, as
// ImportTrack.
func ImportTracks(cur realm, batch string) int {
	noPayment()
	lines := strings.Split(batch, "\n")
	if batch == "" || len(lines) > maxImportBatch {
		panic("radio: a batch holds 1 to " + text.Itoa(maxImportBatch) + " tracks")
	}
	rows := make([][]string, len(lines))
	for i, line := range lines { // the whole batch is read before anything is written
		f := strings.Split(line, "\t")
		if len(f) != 12 || !text.Digits(f[0]) || !text.Digits(f[2]) {
			panic("radio: batch line " + text.Itoa(i+1) + ": 12 tab-separated fields expected, artist and genre in digits")
		}
		rows[i] = f
	}
	by, id, t := cur.Previous().Address(), 0, rd()
	for _, f := range rows {
		id = catalog.ImportFor(cross(cur), by, text.MustAtoi(f[0]), f[1], text.MustAtoi(f[2]), f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11])
		airNext(t, id, false)
	}
	save(cur, t)
	return id
}

// EditTrack fixes a track's details (the arguments are catalog.EditFor's).
// A new genre or duration is applied to the stations in the same
// transaction, as Refresh does; other details need nothing on air.
func EditTrack(cur realm, trackID int, title string, genre int, duration, credits, audio, audioSHA, cover, coverSHA string) {
	caller := userCaller(cur)
	noPayment()
	_, oldGenre, oldDur, _ := catalog.TrackBrief(trackID)
	catalog.EditFor(cross(cur), caller, trackID, title, genre, duration, credits, audio, audioSHA, cover, coverSHA)
	if _, g, d, _ := catalog.TrackBrief(trackID); g != oldGenre || d != oldDur {
		t := rd()
		refresh(cur, t, trackID)
		save(cur, t)
	}
}

// onAir ingests the track the catalog just added, with Sync's own code: it
// is the next one (Sync and every add keep the stations level with the
// catalog), so this is one track's work whatever the catalog size.
func onAir(cur realm, id int, isNew bool) {
	t := rd()
	airNext(t, id, isNew)
	save(cur, t)
}

func airNext(t *tx, id int, isNew bool) {
	if n := id - t.synced(); n != 1 {
		panic("radio: the stations are behind the catalog, call Sync first")
	}
	ingest(t, now(), 1, isNew)
}
