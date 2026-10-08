package catalog

import (
	"chain"
	"chain/banker"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// Like records a public like. The first listeners to like a track earn its
// early-listener badge. (Saving a track privately is done in the app, free.)
func Like(cur realm, trackID int) {
	caller := userCaller(cur)
	noPayment()
	// Likes and the early badges are updated in place: the most frequent write
	// never decodes the whole track.
	t := rd()
	rec, arec := playableRec(t, trackID)
	if rec == "" {
		panic("catalog: unknown track")
	}
	if address(store.Field(arec, aOwner)) == caller {
		panic("catalog: you cannot like your own track")
	}
	if !t.addID(cLikes, caller.String(), trackID) {
		panic("catalog: already liked")
	}
	n := text.Atoi(store.Field(rec, fLikes)) + 1
	rec = store.With(rec, fLikes, text.Itoa(n))
	if early := store.Field(rec, fEarly); !hasEarly(early, caller) && (len(early)+1)/(len(caller)+1) < earlyBadges {
		if early != "" {
			early += ","
		}
		rec = store.With(rec, fEarly, early+caller.String())
	}
	t.setRec(cTracks, trackID, rec)
	id := text.Itoa(trackID)
	t.rank(topLiked, id, int64(n), true)
	t.activityOnce("like", caller, id, store.Field(rec, fArtist))
	save(cur, t)
	emitEvent("Liked", "track", id, "by", caller.String())
}

// hasEarly reports whether a comma-joined address list holds a (addresses
// share one length, so this compares slices instead of scanning bytes).
func hasEarly(list string, a address) bool {
	w := len(a) + 1
	for p := 0; p+len(a) <= len(list); p += w {
		if list[p:p+len(a)] == a.String() {
			return true
		}
	}
	return false
}

// dropEarly takes a out of a comma-joined address list.
func dropEarly(list string, a address) string {
	var kept []string
	for _, x := range strings.Split(list, ",") {
		if x != a.String() {
			kept = append(kept, x)
		}
	}
	return strings.Join(kept, ",")
}

// Unlike takes a like back, and its early-listener badge with it.
func Unlike(cur realm, trackID int) {
	caller := userCaller(cur)
	noPayment()
	t := rd()
	if !t.removeID(cLikes, caller.String(), trackID) {
		panic("catalog: not liked")
	}
	if rec := t.rec(cTracks, trackID); rec != "" {
		if n := text.Atoi(store.Field(rec, fLikes)); n > 0 {
			rec = store.With(rec, fLikes, text.Itoa(n-1))
			t.rank(topLiked, text.Itoa(trackID), int64(n-1), false)
		}
		// The early-listener badge goes with the like: like and unlike
		// cycles keep no badge, and free the slot for a real listener.
		if early := store.Field(rec, fEarly); hasEarly(early, caller) {
			rec = store.With(rec, fEarly, dropEarly(early, caller))
		}
		t.setRec(cTracks, trackID, rec)
	}
	save(cur, t)
	emitEvent("Unliked", "track", text.Itoa(trackID), "by", caller.String())
}

// Tip forwards the attached ugnot to the track's artist and collaborators,
// split as declared at publish time, in this same transaction. Only verified
// artists receive tips (verify.gno). Verification proves control of a web
// host or an Audius account, not who the artist is: the proof host is public
// next to every ✓ (ProofHost), and the 72 h claim window (PendingClaims) is
// there to catch an impersonator before tips open.
func Tip(cur realm, trackID int) {
	tip(cur, userCaller(cur), paid(), trackID, 0, "", "")
}

// TipWithSupport is Tip plus an optional contribution to GnoRadio: of the
// attached total T, the artist side receives T*100/(100+supportPct) (split as
// in Tip) and the rest goes to the GnoRadio treasury. supportPct is 0..50.
func TipWithSupport(cur realm, trackID int, supportPct int) {
	tip(cur, userCaller(cur), paid(), trackID, supportPct, "", "")
}

// tip pays total from this realm's balance for caller. The artist's promo
// share (promo.gno) of the artist side goes to picker and ref, when given and
// neither the tipper nor the artist, and only when the tipper did not pick
// the track themselves; collaborators split what is left.
func tip(cur realm, caller address, total int64, trackID, supportPct int, picker, ref address) (toPicker, toRef int64) {
	if supportPct < 0 || supportPct > maxSupportPct {
		panic("catalog: supportPct must be between 0 and 50")
	}
	// The track and artist records are changed in place, as Like does.
	t := rd()
	if supportPct > 0 && treasury(t) == "" {
		panic("catalog: no treasury is set, a tip carries no support share")
	}
	rec, arec := playableRec(t, trackID)
	if rec == "" {
		panic("catalog: unknown track")
	}
	owner := address(store.Field(arec, aOwner))
	if owner == "" || store.Field(arec, aVerified) == "" {
		panic("catalog: this artist has not verified their profile yet")
	}
	if owner == caller {
		panic("catalog: you cannot tip your own track")
	}
	if total > maxTip+maxTip/2 {
		panic("catalog: a tip is between 0.1 and 1000000 GNOT")
	}
	amt := total * 100 / int64(100+supportPct)
	platform := total - amt
	if amt < minTip || amt > maxTip {
		panic("catalog: a tip is between 0.1 and 1000000 GNOT")
	}
	// A tipper who picked the track themselves brings no listener: no promo
	// share goes out, neither to the pick nor to a link they name.
	selfPicked := picker == caller
	if selfPicked || picker == owner || !role.Canonical(picker) || data.IsGnoRadio(picker) {
		picker = ""
	}
	self := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	// This realm holds nothing between transactions: the tip is all it has.
	if bk.GetCoins(self).AmountOf(denom) < total {
		panic("catalog: the tip did not arrive")
	}
	if selfPicked || ref == caller || ref == owner || ref == picker || !role.Canonical(ref) || data.IsGnoRadio(ref) {
		ref = ""
	}
	artistID := text.Atoi(store.Field(rec, fArtist))
	toPicker, toRef = promoShares(amt, promoShare(t, artistID), picker, ref)
	artistSide := amt - toPicker - toRef

	rest := artistSide
	var paidTo strings.Builder
	if splits := store.Field(rec, fSplits); splits != "" {
		for _, p := range strings.Split(splits, ",") {
			to, pct, _ := strings.Cut(p, ":")
			share := artistSide * text.Atoi64(pct) / 100
			if share > 0 && !data.IsGnoRadio(address(to)) { // a realm of a later release: the owner keeps it
				bk.SendCoins(self, address(to), chain.Coins{{Denom: denom, Amount: share}})
				rest -= share
				paidTo.WriteString(to + ":" + text.Itoa64(share) + ",")
			}
		}
	}
	bk.SendCoins(self, owner, chain.Coins{{Denom: denom, Amount: rest}})
	paidTo.WriteString(owner.String() + ":" + text.Itoa64(rest))
	if toPicker > 0 {
		bk.SendCoins(self, picker, chain.Coins{{Denom: denom, Amount: toPicker}})
	}
	if toRef > 0 {
		bk.SendCoins(self, ref, chain.Coins{{Denom: denom, Amount: toRef}})
	}
	if platform > 0 {
		bk.SendCoins(self, treasury(t), chain.Coins{{Denom: denom, Amount: platform}})
		recordSupport(t, caller, platform)
	}

	rec = store.With(rec, fTips, text.Itoa64(text.Atoi64(store.Field(rec, fTips))+artistSide))
	if t.addID(cTipped, caller.String(), trackID) {
		rec = store.With(rec, fSupporters, text.Itoa(text.Atoi(store.Field(rec, fSupporters))+1))
	}
	t.setRec(cTracks, trackID, rec)
	artistTips := text.Atoi64(store.Field(arec, aTips)) + artistSide
	t.setRec(cArtists, artistID, store.With(arec, aTips, text.Itoa64(artistTips)))
	// The tipper's rank and feed line count what reached the artist side: a
	// promo share may go back to a second wallet of the tipper's.
	u := user(t, caller)
	u.Tipped += artistSide
	putUser(t, caller, u)
	aid, id := store.Field(rec, fArtist), text.Itoa(trackID)
	t.rank(topArtists, aid, artistTips, true)
	t.rank(topFans, caller.String(), u.Tipped, true)
	t.activity("tip", caller, id, aid, text.Itoa64(artistSide))
	save(cur, t)
	emitEvent("Tipped", "track", id, "by", caller.String(), "amount", text.Itoa64(amt), "paid", paidTo.String(), "support", text.Itoa64(platform),
		"picker", picker.String(), "toPicker", text.Itoa64(toPicker), "ref", ref.String(), "toRef", text.Itoa64(toRef))
	return toPicker, toRef
}

// ---- Albums ----

// CreateAlbum groups tracks of one artist. The artist (or the admin for an
// unclaimed artist) creates it; trackIDs is "12,13,14" in play order.
func CreateAlbum(cur realm, artistID int, title, cover, coverSHA string, year int, trackIDs string) int {
	caller := userCaller(cur)
	noPayment()
	t := rd()
	a := mustArtist(t, artistID)
	if !mayEdit(caller, a) {
		panic("catalog: only the artist can create its albums")
	}
	title, cover, coverSHA = strings.TrimSpace(title), strings.TrimSpace(cover), strings.ToLower(strings.TrimSpace(coverSHA))
	mustText("title", title, 1, maxTitle)
	if cover != "" {
		mustMedia("cover", cover, coverSHA, false)
	}
	if year < 1900 || year > 2100 {
		panic("catalog: year must be between 1900 and 2100")
	}
	ids := parseIDs(trackIDs, maxAlbumTracks)
	artistTracks, albumIDs := lists(t, a.ID)
	if store.Count(albumIDs) >= maxPerArtist {
		panic("catalog: albums per artist limit reached")
	}
	albumID := int(t.bump(mAlbums, 1))
	for _, id := range ids {
		tr := mustTrack(t, id)
		if tr.Artist != a.ID || tr.Album != 0 {
			panic("catalog: track " + text.Itoa(id) + " is not this artist's or already in an album")
		}
		tr.Album = albumID
		putTrack(t, tr)
	}
	al := &Album{ID: albumID, Artist: a.ID, Title: title, Cover: cover, CoverSHA: coverSHA, Year: year, Tracks: ids, Created: now()}
	t.addRec(cAlbums, al.ID, fits(albumRecord(al)))
	setLists(t, a.ID, artistTracks, albumIDs+store.Enc(al.ID))
	t.activity("album", caller, text.Itoa(al.ID), text.Itoa(a.ID), "0")
	save(cur, t)
	emitEvent("AlbumCreated", "id", text.Itoa(al.ID), "artist", text.Itoa(a.ID), "title", title)
	return al.ID
}

// ---- Playlists ----

// PublishPlaylist makes a public playlist in one signature; trackIDs is
// "12,40,7". Private playlists live in the app and cost nothing.
func PublishPlaylist(cur realm, title, trackIDs string) int {
	caller := userCaller(cur)
	noPayment()
	title = strings.TrimSpace(title)
	mustText("title", title, 1, maxTitle)
	t := rd()
	ids := checkedIDs(t, trackIDs)
	u := user(t, caller)
	if len(u.Playlists) >= maxUserLists {
		panic("catalog: playlists per listener limit reached")
	}
	p := &Playlist{ID: int(t.bump(mPlaylists, 1)), Owner: caller, Title: title, Tracks: ids, Updated: now()}
	u.Playlists = append(u.Playlists, p.ID)
	putUser(t, caller, u)
	putPlaylist(t, p)
	t.activity("playlist", caller, text.Itoa(p.ID), "0", "0")
	save(cur, t)
	emitEvent("PlaylistPublished", "id", text.Itoa(p.ID), "owner", caller.String(), "tracks", text.Itoa(len(ids)))
	return p.ID
}

// UpdatePlaylist replaces a playlist's title and tracks. Owner only.
func UpdatePlaylist(cur realm, playlistID int, title, trackIDs string) {
	caller := userCaller(cur)
	noPayment()
	t := rd()
	p := getPlaylist(t, playlistID)
	if p == nil || p.Hidden || p.Owner != caller {
		panic("catalog: not your playlist")
	}
	title = strings.TrimSpace(title)
	mustText("title", title, 1, maxTitle)
	p.Title, p.Tracks, p.Updated = title, checkedIDs(t, trackIDs), now()
	putPlaylist(t, p)
	save(cur, t)
	emitEvent("PlaylistUpdated", "id", text.Itoa(p.ID), "tracks", text.Itoa(len(p.Tracks)))
}

// checkedIDs parses a playlist's track ids. Only the id range and duplicates
// are checked: loading every track would cost a read per id, and hidden or
// removed tracks are skipped when the playlist is read.
func checkedIDs(t *tx, s string) []int {
	ids := parseIDs(s, maxListTracks)
	for _, id := range ids {
		if int64(id) > t.count(mTracks) {
			panic("catalog: unknown track " + text.Itoa(id))
		}
	}
	return ids
}
