package catalog

import (
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
)

// Records are store.Rec values: fields behind a length header, so reading a
// field never scans the record. Hot fields come first. Id lists use store's
// JSON-ready width and go straight into the JSON exports. The fields are
// catalog v0's, ordered so the frequent writes touch the first ones.

type Split struct {
	To  address
	Pct int64 // percent of each tip
}

type Artist struct {
	ID        int
	Owner     address // "" while unclaimed (curated / Audius / Jamendo)
	Kind      string  // artist | curated | audius | jamendo
	Name      string
	Bio       string
	Source    string // curated: source page; audius / jamendo: platform id (audius-user:<id>, jamendo-artist:<id>)
	Joined    int64
	Tips      int64
	Followers int
	Tracks    []int
	Albums    []int
	Verified  bool
	Hidden    bool
}

type Track struct {
	ID          int
	Artist      int
	Origin      string
	Title       string
	Genre       int
	Duration    int64 // seconds
	License     string
	CMO         string // none | sacem-nc
	Credits     string
	Audio       string // ipfs://… ar://… audius:… jamendo:… https://…
	AudioSHA    string // sha256 hex, required for https
	Cover       string
	CoverSHA    string
	SourceURL   string
	Attribution string
	Splits      []Split
	Album       int
	Created     int64
	Likes       int
	Tips        int64
	Supporters  int
	Hidden      bool
	Early       []address // first listeners to like it
}

type Album struct {
	ID       int
	Artist   int
	Title    string
	Cover    string
	CoverSHA string
	Year     int
	Tracks   []int
	Created  int64
	Hidden   bool
}

type Playlist struct {
	ID      int
	Owner   address
	Title   string
	Tracks  []int
	Updated int64
	Hidden  bool
}

// User is what a listener writes, so a follow only touches that listener's
// own record. Follows are a sorted packed list (9 bytes each); likes and the
// tipped tracks live apart, per range of 512 track ids.
type User struct {
	Follows   string // sorted packed artist ids
	Tipped    int64
	Playlists []int
	Reports   int // open reports filed by this user
}

type ReportInfo struct {
	ID     int
	Kind   string // track | album | artist | playlist
	Target string
	Reason string
	By     address
	At     int64
}

// ---- tracks: what the radio reads first, then what likes and tips change ----

// Track record fields. Reading or replacing field i walks the i fields
// before it, so the fields the frequent actions read and change come first.
const (
	fArtist = iota
	fGenre
	fDuration
	fHidden
	fLikes
	fEarly // first listeners to like it, comma-joined
	fTips
	fSupporters
	fAlbum
	fCreated
	fOrigin
	fTitle
	fLicense
	fCMO
	fCredits
	fAudio
	fAudioSHA
	fCover
	fCoverSHA
	fSource
	fAttribution
	fSplits // "addr:pct,…"
)

func getTrack(t *tx, id int) *Track {
	rec := t.rec(cTracks, id)
	if rec == "" {
		return nil
	}
	f := store.Fields(rec)
	tr := &Track{
		ID: id, Artist: text.Atoi(f[fArtist]), Genre: text.Atoi(f[fGenre]), Duration: text.Atoi64(f[fDuration]), Hidden: f[fHidden] != "",
		Likes: text.Atoi(f[fLikes]), Tips: text.Atoi64(f[fTips]), Supporters: text.Atoi(f[fSupporters]), Album: text.Atoi(f[fAlbum]),
		Created: text.Atoi64(f[fCreated]), Origin: f[fOrigin], Title: f[fTitle], License: f[fLicense], CMO: f[fCMO],
		Credits: f[fCredits], Audio: f[fAudio], AudioSHA: f[fAudioSHA], Cover: f[fCover], CoverSHA: f[fCoverSHA],
		SourceURL: f[fSource], Attribution: f[fAttribution],
	}
	if f[fSplits] != "" {
		for _, p := range strings.Split(f[fSplits], ",") {
			to, pct, _ := strings.Cut(p, ":")
			tr.Splits = append(tr.Splits, Split{To: address(to), Pct: text.Atoi64(pct)})
		}
	}
	if f[fEarly] != "" {
		for _, a := range strings.Split(f[fEarly], ",") {
			tr.Early = append(tr.Early, address(a))
		}
	}
	return tr
}

func trackRecord(tr *Track) string {
	var splits, early []string
	for _, s := range tr.Splits {
		splits = append(splits, s.To.String()+":"+text.Itoa64(s.Pct))
	}
	for _, a := range tr.Early {
		early = append(early, a.String())
	}
	return store.Rec(text.Itoa(tr.Artist), text.Itoa(tr.Genre), text.Itoa64(tr.Duration), text.Flag(tr.Hidden), text.Itoa(tr.Likes),
		strings.Join(early, ","), text.Itoa64(tr.Tips), text.Itoa(tr.Supporters), text.Itoa(tr.Album), text.Itoa64(tr.Created), tr.Origin,
		tr.Title, tr.License, tr.CMO, tr.Credits, tr.Audio, tr.AudioSHA, tr.Cover, tr.CoverSHA, tr.SourceURL,
		tr.Attribution, strings.Join(splits, ","))
}

func putTrack(t *tx, tr *Track) { t.setRec(cTracks, tr.ID, trackRecord(tr)) }

// brief reads only what playback needs, without decoding the whole track.
func brief(t *tx, id int) (artist, genre int, dur int64, hidden, ok bool) {
	rec := t.rec(cTracks, id)
	if rec == "" {
		return 0, 0, 0, false, false
	}
	return text.Atoi(store.Field(rec, fArtist)), text.Atoi(store.Field(rec, fGenre)), text.Atoi64(store.Field(rec, fDuration)), store.Field(rec, fHidden) != "", true
}

// ---- artists: a small head record, the id lists apart ----

// Artist head fields, in the same spirit: what tips and follows read and
// change first. The permanent tickets/nft realm reads aHidden and aName (and
// chunkSize) straight from the data realm: no release may move them.
const (
	aHidden = iota
	aOwner
	aVerified
	aTips
	aFollowers
	aKind
	aName
	aBio
	aSource
	aJoined
)

// getArtist returns an artist's head; Tracks and Albums stay empty (see withLists).
func getArtist(t *tx, id int) *Artist {
	rec := t.rec(cArtists, id)
	if rec == "" {
		return nil
	}
	f := store.Fields(rec)
	return &Artist{
		ID: id, Hidden: f[aHidden] != "", Owner: address(f[aOwner]), Verified: f[aVerified] != "", Tips: text.Atoi64(f[aTips]),
		Followers: text.Atoi(f[aFollowers]), Kind: f[aKind], Name: f[aName], Bio: f[aBio], Source: f[aSource], Joined: text.Atoi64(f[aJoined]),
	}
}

func artistRecord(a *Artist) string {
	return store.Rec(text.Flag(a.Hidden), a.Owner.String(), text.Flag(a.Verified), text.Itoa64(a.Tips), text.Itoa(a.Followers), a.Kind,
		a.Name, a.Bio, a.Source, text.Itoa64(a.Joined))
}

func putArtist(t *tx, a *Artist) { t.setRec(cArtists, a.ID, artistRecord(a)) }

// artistField reads one field of the head ("" for an unknown artist).
func artistField(t *tx, id, i int) string {
	if rec := t.rec(cArtists, id); rec != "" {
		return store.Field(rec, i)
	}
	return ""
}

func artistVisible(t *tx, id int) bool {
	rec := t.rec(cArtists, id)
	return rec != "" && store.Field(rec, aHidden) == ""
}

// lists returns an artist's track and album id lists (made at its first publish).
func lists(t *tx, artistID int) (trackIDs, albumIDs string) {
	rec := t.val(cAlists, store.Pad(artistID))
	if rec == "" {
		return "", ""
	}
	f := store.Fields(rec)
	return f[0], f[1]
}

func setLists(t *tx, artistID int, trackIDs, albumIDs string) {
	t.set(cAlists, store.Pad(artistID), store.Rec(trackIDs, albumIDs))
}

// withLists fills an artist head's Tracks and Albums.
func withLists(t *tx, a *Artist) *Artist {
	tl, al := lists(t, a.ID)
	a.Tracks, a.Albums = store.Ints(tl), store.Ints(al)
	return a
}

func artistOf(t *tx, owner address) int { return text.Atoi(t.val(cOwners, owner.String())) }

// ---- albums and playlists ----

func getAlbum(t *tx, id int) *Album {
	rec := t.rec(cAlbums, id)
	if rec == "" {
		return nil
	}
	f := store.Fields(rec)
	return &Album{ID: id, Artist: text.Atoi(f[0]), Title: f[1], Cover: f[2], CoverSHA: f[3], Year: text.Atoi(f[4]),
		Created: text.Atoi64(f[5]), Hidden: f[6] != "", Tracks: store.Ints(f[7])}
}

func albumRecord(al *Album) string {
	return store.Rec(text.Itoa(al.Artist), al.Title, al.Cover, al.CoverSHA, text.Itoa(al.Year), text.Itoa64(al.Created),
		text.Flag(al.Hidden), store.Pack(al.Tracks))
}

func putAlbum(t *tx, al *Album) { t.setRec(cAlbums, al.ID, albumRecord(al)) }

func getPlaylist(t *tx, id int) *Playlist {
	if id < 1 {
		return nil
	}
	rec := t.val(cPlaylists, store.Pad(id))
	if rec == "" {
		return nil
	}
	f := store.Fields(rec)
	return &Playlist{ID: id, Owner: address(f[0]), Title: f[1], Updated: text.Atoi64(f[2]), Hidden: f[3] != "",
		Tracks: store.Ints(f[4])}
}

func putPlaylist(t *tx, p *Playlist) {
	t.set(cPlaylists, store.Pad(p.ID), store.Rec(p.Owner.String(), p.Title, text.Itoa64(p.Updated), text.Flag(p.Hidden), store.Pack(p.Tracks)))
}

// ---- listeners ----

// user returns a listener's record (an empty one if none); save it with putUser.
func user(t *tx, addr address) *User {
	rec := t.val(cUsers, addr.String())
	if rec == "" {
		return &User{}
	}
	f := store.Fields(rec)
	return &User{Follows: f[0], Tipped: text.Atoi64(f[1]), Playlists: store.Ints(f[2]), Reports: text.Atoi(f[3])}
}

func putUser(t *tx, addr address, u *User) {
	t.set(cUsers, addr.String(), store.Rec(u.Follows, text.Itoa64(u.Tipped), store.Pack(u.Playlists), text.Itoa(u.Reports)))
}

// ---- lookups shared by every file ----

func visibleArtist(a *Artist) bool { return a != nil && !a.Hidden }

func playable(t *tx, tr *Track) bool {
	return tr != nil && !tr.Hidden && artistVisible(t, tr.Artist)
}

func mustArtist(t *tx, id int) *Artist {
	a := getArtist(t, id)
	if !visibleArtist(a) {
		panic("catalog: unknown artist")
	}
	return a
}

func mustTrack(t *tx, id int) *Track {
	tr := getTrack(t, id)
	if !playable(t, tr) {
		panic("catalog: unknown track")
	}
	return tr
}

// ownArtist returns the caller's visible artist profile: its id and head.
func ownArtist(t *tx, caller address) (int, string) {
	id := artistOf(t, caller)
	arec := t.rec(cArtists, id)
	if arec == "" || store.Field(arec, aHidden) != "" {
		panic("catalog: create your artist profile first")
	}
	return id, arec
}

// mayEdit reports whether caller manages artist a: its owner, or the admin
// while the artist is unclaimed.
func mayEdit(caller address, a *Artist) bool {
	if a.Owner != "" {
		return caller == a.Owner
	}
	return caller != "" && caller == adminAddr()
}
