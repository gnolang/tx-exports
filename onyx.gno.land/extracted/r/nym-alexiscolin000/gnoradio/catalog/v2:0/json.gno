package catalog

import (
	"strconv"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
)

// JSON exports for the GnoRadio app and indexers (vm/qeval). Their shapes
// are the app's contract (app/src/lib): change them together.

func ints(xs []int) string {
	var b strings.Builder
	b.WriteString("[")
	for i, x := range xs {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(text.Itoa(x))
	}
	b.WriteString("]")
	return b.String()
}

// The JSON is written from the records' fields as stored: numbers are
// already decimal strings, and converting them costs gas.

// trackJSON writes track id from its record and its artist's head.
func trackJSON(id int, rec, arec string) string {
	f := store.Fields(rec)
	out := `{"id":` + text.Itoa(id) + `,"artist":` + f[fArtist] + `,"artistName":"` + store.Field(arec, aName) +
		`","claimed":` + strconv.FormatBool(store.Field(arec, aOwner) != "") + `,"origin":"` + f[fOrigin] + `","title":"` + f[fTitle] +
		`","genre":` + f[fGenre] + `,"duration":` + f[fDuration] + `,"license":"` + f[fLicense] +
		`","cmo":"` + f[fCMO] + `","credits":"` + f[fCredits] + `","audio":"` + f[fAudio] + `","audioSha256":"` + f[fAudioSHA] +
		`","cover":"` + f[fCover] + `","coverSha256":"` + f[fCoverSHA] + `","source":"` + f[fSource] +
		`","attribution":"` + f[fAttribution] + `","album":` + f[fAlbum] + `,"created":` + f[fCreated] +
		`,"likes":` + f[fLikes] + `,"tips":` + f[fTips] + `,"supporters":` + f[fSupporters] + `,"splits":[`
	if f[fSplits] != "" {
		for i, p := range strings.Split(f[fSplits], ",") {
			to, pct, _ := strings.Cut(p, ":")
			if i > 0 {
				out += ","
			}
			out += `{"to":"` + to + `","pct":` + pct + `}`
		}
	}
	return out + `]}`
}

// playableRec returns a track's record and its artist's head when both are
// visible ("" otherwise).
func playableRec(t *tx, id int) (rec, arec string) {
	rec = t.rec(cTracks, id)
	if rec == "" || store.Field(rec, fHidden) != "" {
		return "", ""
	}
	arec = t.rec(cArtists, text.Atoi(store.Field(rec, fArtist)))
	if arec == "" || store.Field(arec, aHidden) != "" {
		return "", ""
	}
	return rec, arec
}

// TrackJSON returns one playable track.
func TrackJSON(id int) string {
	rec, arec := playableRec(rd(), id)
	if rec == "" {
		panic("catalog: unknown track")
	}
	return trackJSON(id, rec, arec)
}

// TracksJSON pages through playable tracks (newest first), at most 100.
// Chunks and artist heads are read once per page.
func TracksJSON(offset, limit int) string {
	limit = store.Limit(limit, maxBatch)
	t := rd()
	total := int(t.count(mTracks))
	var b strings.Builder
	b.WriteString(`{"total":` + text.Itoa(total) + `,"tracks":[`)
	n := 0
	for _, id := range seqPage(total, offset, limit, true) {
		if rec, arec := playableRec(t, id); rec != "" {
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(trackJSON(id, rec, arec))
			n++
		}
	}
	b.WriteString(`]}`)
	return b.String()
}

func ArtistJSON(id int) string {
	t := rd()
	arec := t.rec(cArtists, id)
	if arec == "" || store.Field(arec, aHidden) != "" {
		panic("catalog: unknown artist")
	}
	return artistJSON(t, id, arec)
}

func artistJSON(t *tx, id int, arec string) string {
	f := store.Fields(arec)
	trackIDs, albumIDs := lists(t, id)
	promo, ok := t.get(cPromo, store.Pad(id))
	if !ok {
		promo = text.Itoa(defaultPromoPct)
	}
	a := &Artist{ID: id, Hidden: f[aHidden] != "", Owner: address(f[aOwner]), Verified: f[aVerified] != ""}
	return `{"id":` + text.Itoa(id) + `,"name":` + text.Str(f[aName]) + `,"kind":` + text.Str(f[aKind]) + `,"owner":` + text.Str(f[aOwner]) +
		`,"bio":` + text.Str(f[aBio]) + `,"source":` + text.Str(f[aSource]) + `,"joined":` + f[aJoined] + `,"tips":` + f[aTips] +
		`,"followers":` + f[aFollowers] + `,"verified":` + strconv.FormatBool(a.Verified) +
		`,"proofHost":` + text.Str(proofHost(t, id, f[aVerified])) + `,"promo":` + promo +
		`,"sponsor":` + text.Itoa64(offer(t, a)) + `,"tracks":` + store.JSON(trackIDs) + `,"albums":` + store.JSON(albumIDs) + `}`
}

// albumJSON writes a visible album ("" when it or its artist is hidden).
func albumJSON(t *tx, id int) string {
	rec := t.rec(cAlbums, id)
	if rec == "" {
		return ""
	}
	f := store.Fields(rec)
	if f[6] != "" || !artistVisible(t, text.Atoi(f[0])) {
		return ""
	}
	return `{"id":` + text.Itoa(id) + `,"artist":` + f[0] + `,"title":` + text.Str(f[1]) + `,"cover":` + text.Str(f[2]) +
		`,"coverSha256":` + text.Str(f[3]) + `,"year":` + f[4] + `,"tracks":` + store.JSON(f[7]) + `}`
}

func AlbumJSON(id int) string {
	s := albumJSON(rd(), id)
	if s == "" {
		panic("catalog: unknown album")
	}
	return s
}

// playlistJSON writes a visible playlist ("" when hidden or unknown).
func playlistJSON(t *tx, id int) string {
	rec := ""
	if id > 0 {
		rec = t.val(cPlaylists, store.Pad(id))
	}
	if rec == "" || store.Field(rec, 3) != "" {
		return ""
	}
	f := store.Fields(rec)
	return `{"id":` + text.Itoa(id) + `,"owner":` + text.Str(f[0]) + `,"title":` + text.Str(f[1]) +
		`,"updated":` + f[2] + `,"tracks":` + store.JSON(f[4]) + `}`
}

func PlaylistJSON(id int) string {
	s := playlistJSON(rd(), id)
	if s == "" {
		panic("catalog: unknown playlist")
	}
	return s
}

// UserJSON returns a listener's public counters (likes are paged with LikesJSON).
func UserJSON(addr address) string {
	likes, follows, tipped, lists := UserStats(addr)
	return `{"address":` + text.Str(addr.String()) + `,"likes":` + text.Itoa(likes) + `,"follows":` + text.Itoa(follows) +
		`,"tipped":` + text.Itoa64(tipped) + `,"playlists":` + ints(lists) + `,"artist":` + text.Itoa(ArtistOf(addr)) + `}`
}

func LikesJSON(addr address, offset, limit int) string { return ints(LikedPage(addr, offset, limit)) }

func GenresJSON() string {
	var b strings.Builder
	b.WriteString("[")
	for g := 1; g <= NumGenres; g++ {
		if g > 1 {
			b.WriteString(",")
		}
		b.WriteString(`{"id":` + text.Itoa(g) + `,"name":` + text.Str(genres[g]) + `}`)
	}
	b.WriteString("]")
	return b.String()
}

// maxBatch caps the batched readers, so one query stays far below the qeval budget.
const maxBatch = 100

// batch writes {"total":n,"<key>":[...]} for ids offset+1..offset+limit, skipping
// hidden items; one query replaces up to 100 single reads.
func batch(key string, total, offset, limit int, one func(id int) string) string {
	limit = store.Limit(limit, maxBatch)
	offset = max0(offset)
	var b strings.Builder
	b.WriteString(`{"total":` + text.Itoa(total) + `,"` + key + `":[`)
	n := 0
	for id := offset + 1; id <= total && id <= offset+limit; id++ {
		if s := one(id); s != "" {
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(s)
			n++
		}
	}
	b.WriteString(`]}`)
	return b.String()
}

// ArtistsJSON returns visible artists with ids offset+1..offset+limit (at most 100).
func ArtistsJSON(offset, limit int) string {
	t := rd()
	return batch("artists", int(t.count(mArtists)), offset, limit, func(id int) string {
		if arec := t.rec(cArtists, id); arec != "" && store.Field(arec, aHidden) == "" {
			return artistJSON(t, id, arec)
		}
		return ""
	})
}

// AlbumsJSON returns visible albums with ids offset+1..offset+limit (at most 100).
func AlbumsJSON(offset, limit int) string {
	t := rd()
	return batch("albums", int(t.count(mAlbums)), offset, limit, func(id int) string { return albumJSON(t, id) })
}

// PlaylistsJSON returns visible playlists with ids offset+1..offset+limit (at most 100).
func PlaylistsJSON(offset, limit int) string {
	t := rd()
	return batch("playlists", int(t.count(mPlaylists)), offset, limit, func(id int) string { return playlistJSON(t, id) })
}
