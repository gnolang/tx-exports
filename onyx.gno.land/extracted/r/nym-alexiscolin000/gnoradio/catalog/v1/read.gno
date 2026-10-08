package catalog

import (
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// ---- Read API for the other GnoRadio realms (values only) ----

func GenreName(g int) string {
	if g < 1 || g > NumGenres {
		return ""
	}
	return genres[g]
}

func TrackCount() int    { return int(rd().count(mTracks)) }
func ArtistCount() int   { return int(rd().count(mArtists)) }
func AlbumCount() int    { return int(rd().count(mAlbums)) }
func PlaylistCount() int { return int(rd().count(mPlaylists)) }

// TrackBrief is what the radio needs; playable is false for an unknown or
// hidden track, or one whose artist is hidden.
func TrackBrief(id int) (artistID, genre int, duration int64, playable_ bool) {
	rec := point(cTracks, id)
	if rec == "" {
		return 0, 0, 0, false
	}
	a := text.Atoi(store.Field(rec, fArtist))
	arec := point(cArtists, a)
	return a, text.Atoi(store.Field(rec, fGenre)), text.Atoi64(store.Field(rec, fDuration)),
		store.Field(rec, fHidden) == "" && arec != "" && store.Field(arec, aHidden) == ""
}

// TrackBriefFor is TrackBrief and whether addr ("" for nobody) is the
// track's artist or one of its collaborators, from the same reads.
func TrackBriefFor(id int, addr address) (artistID, genre int, duration int64, playable_, own bool) {
	rec := point(cTracks, id)
	if rec == "" {
		return 0, 0, 0, false, false
	}
	a := text.Atoi(store.Field(rec, fArtist))
	arec := point(cArtists, a)
	playable_ = store.Field(rec, fHidden) == "" && arec != "" && store.Field(arec, aHidden) == ""
	if addr != "" && arec != "" {
		// splits are "addr:pct,…" and an address holds no ',' or ':'
		sp := store.Field(rec, fSplits)
		own = store.Field(arec, aOwner) == addr.String() || sp != "" && strings.Contains(","+sp, ","+addr.String()+":")
	}
	return a, text.Atoi(store.Field(rec, fGenre)), text.Atoi64(store.Field(rec, fDuration)), playable_, own
}

// PlayableTitle is a track's title, "" unless it is playable (TrackBrief).
func PlayableTitle(id int) string {
	rec := point(cTracks, id)
	if rec == "" || store.Field(rec, fHidden) != "" {
		return ""
	}
	if arec := point(cArtists, text.Atoi(store.Field(rec, fArtist))); arec == "" || store.Field(arec, aHidden) != "" {
		return ""
	}
	return store.Field(rec, fTitle)
}

func TrackTitle(id int) string {
	if rec := point(cTracks, id); rec != "" {
		return refLabel(store.Field(rec, fOrigin), store.Field(rec, fTitle), "track")
	}
	return ""
}

func ArtistName(artistID int) string {
	if rec := point(cArtists, artistID); rec != "" {
		return refLabel(store.Field(rec, aKind), store.Field(rec, aName), "artist")
	}
	return ""
}

func ArtistOwner(artistID int) address { return address(artistAt(artistID, aOwner)) }
func ArtistOf(owner address) int       { return artistOf(rd(), owner) }

// ArtistPayee is what a payment to an artist checks, from one read: who
// is paid, whether verified, and whether the profile is visible.
func ArtistPayee(id int) (owner address, verified, visible bool) {
	rec := point(cArtists, id)
	if rec == "" {
		return "", false, false
	}
	return address(store.Field(rec, aOwner)), store.Field(rec, aVerified) == "1", store.Field(rec, aHidden) == ""
}
func ArtistVisible(artistID int) bool {
	rec := point(cArtists, artistID)
	return rec != "" && store.Field(rec, aHidden) == ""
}

// ---- Value getters for the home realm and tools ----

// GetTrack returns a copy of a track; ok is false if unknown. A pointer's
// empty title reads as its platform ("Audius track").
func GetTrack(id int) (Track, bool) {
	if tr := getTrack(rd(), id); tr != nil {
		tr.Title = refLabel(tr.Origin, tr.Title, "track")
		return *tr, true
	}
	return Track{}, false
}

func GetArtist(id int) (Artist, bool) {
	t := rd()
	if a := getArtist(t, id); a != nil {
		a.Name = refLabel(a.Kind, a.Name, "artist")
		return *withLists(t, a), true
	}
	return Artist{}, false
}

// ArtistByRef looks a pointer artist up by its platform id ("audius-user:12").
func ArtistByRef(ref string) int {
	v, _ := data.Get(cNames, strings.TrimSpace(ref))
	return text.Atoi(v)
}

// ArtistByName looks a profile up by its (case-insensitive) name.
func ArtistByName(name string) int {
	v, _ := data.Get(cNames, skeleton(strings.TrimSpace(name)))
	return text.Atoi(v)
}

func GetAlbum(id int) (Album, bool) {
	if a := getAlbum(rd(), id); a != nil {
		return *a, true
	}
	return Album{}, false
}

func GetPlaylist(id int) (Playlist, bool) {
	if p := getPlaylist(rd(), id); p != nil {
		return *p, true
	}
	return Playlist{}, false
}

// ReportCount is the number of open (unresolved) reports.
func ReportCount() int { return int(rd().count(mOpen)) }

func GetReport(id int) (ReportInfo, bool) { return getReport(rd(), id) }

// UserStats returns a listener's public counters and playlists. The like
// count reads the listener's own like ranges, one page.
func UserStats(addr address) (likes, follows int, tipped int64, lists []int) {
	_, likes = rangePage(cLikes, addr.String(), 0, 0)
	u := user(rd(), addr)
	return likes, store.Count(u.Follows), u.Tipped, u.Playlists
}

// LikedPage lists a listener's liked track ids, newest tracks first,
// paginated. Likes are keyed by track id, so this is the newest music the
// listener liked, not the order of their likes (that needs an index per like,
// which would add to every like's storage deposit).
func LikedPage(addr address, offset, limit int) []int {
	ids, _ := rangePage(cLikes, addr.String(), max0(offset), store.Limit(limit, 100))
	return ids
}

// ---- Narrow getters: one field without copying a whole struct ----

// ArtistTrackCount is the number of tracks an artist published.
func ArtistTrackCount(artistID int) int {
	tl, _ := lists(rd(), artistID)
	return store.Count(tl)
}

// ArtistTrackPage lists an artist's track ids in publishing order, paginated.
func ArtistTrackPage(artistID, offset, limit int) []int {
	if offset < 0 {
		return nil
	}
	tl, _ := lists(rd(), artistID)
	return store.Page(tl, offset, store.Limit(limit, 100), false)
}

// ArtistBrief returns what a link to an artist needs, without the bio or the
// id lists; ok is false for an unknown artist.
func ArtistBrief(artistID int) (name string, verified, hidden, ok bool) {
	rec := point(cArtists, artistID)
	if rec == "" {
		return "", false, false, false
	}
	return refLabel(store.Field(rec, aKind), store.Field(rec, aName), "artist"), store.Field(rec, aVerified) != "", store.Field(rec, aHidden) != "", true
}

// PlaylistBrief returns a playlist's header without its track ids.
func PlaylistBrief(id int) (owner address, title string, tracks int, hidden, ok bool) {
	rec := rd().val(cPlaylists, store.Pad(id)) // counts the ids without decoding them
	if id < 1 || rec == "" {
		return "", "", 0, false, false
	}
	f := store.Fields(rec)
	return address(f[0]), f[1], store.Count(f[4]), f[3] != "", true
}

// FollowsPage lists the artist ids a listener follows, paginated.
func FollowsPage(addr address, offset, limit int) []int {
	return store.Page(user(rd(), addr).Follows, max0(offset), store.Limit(limit, 100), false)
}

// GenrePage lists the track ids of a genre (hidden ones included), newest first.
func GenrePage(genre, offset, limit int) []int {
	if genre < 1 || genre > NumGenres {
		return nil
	}
	ids, _ := rangePage(cGenres, store.Pad(genre), max0(offset), store.Limit(limit, 100))
	return ids
}

// GenreCount is the number of tracks filed under a genre.
func GenreCount(genre int) int {
	if genre < 1 || genre > NumGenres {
		return 0
	}
	return int(rd().count(mGenre + genre))
}

// TrackPage lists track ids, newest first when newest is true.
// Ids are dense (1..count), so these pages are arithmetic.
func TrackPage(offset, limit int, newest bool) []int {
	return seqPage(TrackCount(), offset, limit, newest)
}
func ArtistPage(offset, limit int) []int   { return seqPage(ArtistCount(), offset, limit, false) }
func AlbumPage(offset, limit int) []int    { return seqPage(AlbumCount(), offset, limit, true) }
func PlaylistPage(offset, limit int) []int { return seqPage(PlaylistCount(), offset, limit, true) }

// ReportPage lists open report ids, newest first.
func ReportPage(offset, limit int) []int {
	keys, _ := store.Rows(data.PageAt(cReports, max0(offset), store.Limit(limit, 100), true))
	out := make([]int, 0, len(keys))
	for _, k := range keys {
		out = append(out, text.Atoi(k))
	}
	return out
}

func seqPage(n, offset, limit int, newest bool) []int {
	var out []int
	for k := max0(offset); k < n && len(out) < store.Limit(limit, 100); k++ {
		if newest {
			out = append(out, n-k)
		} else {
			out = append(out, k+1)
		}
	}
	return out
}

func max0(n int) int {
	if n < 0 {
		return 0
	}
	return n
}

func TopLiked() []Rank   { return rd().top(topLiked) }
func TopArtists() []Rank { return rd().top(topArtists) }
func TopFans() []Rank    { return rd().top(topFans) }

func Admin() address            { return adminAddr() }
func PendingAdmin() address     { return admin.Pending() } // the address the admin role is offered to, "" if none
func Version() string           { return version }
func RightsTerms() string       { return rightsTerms }
func HostAllowed(h string) bool { return data.Has(cHosts, strings.ToLower(h)) }
