package catalog

import (
	"strconv"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
)

// Report flags a track, album, artist or playlist for the moderators
// (e.g. "broken link", "not the real artist", "copyright").
func Report(cur realm, kind string, target int, reason string) {
	caller := userCaller(cur)
	noPayment()
	reason = strings.TrimSpace(reason)
	mustText("reason", reason, 4, maxReason)
	t := rd()
	switch kind {
	case "track":
		mustTrack(t, target)
	case "album":
		if al := getAlbum(t, target); al == nil || al.Hidden {
			panic("catalog: unknown album")
		}
	case "artist":
		mustArtist(t, target)
	case "playlist":
		if p := getPlaylist(t, target); p == nil || p.Hidden {
			panic("catalog: unknown playlist")
		}
	default:
		panic("catalog: kind must be track, album, artist or playlist")
	}
	u := user(t, caller)
	if u.Reports >= maxUserReports {
		panic("catalog: you have " + text.Itoa(maxUserReports) + " open reports, wait for the moderators")
	}
	u.Reports++
	putUser(t, caller, u)
	t.bump(mOpen, 1)
	t.put(cReports, store.Pad(int(t.bump(mReports, 1))), store.Rec(kind, text.Itoa(target), reason, caller.String(), text.Itoa64(now())))
	save(cur, t)
	emitEvent("Reported", "kind", kind, "target", text.Itoa(target), "by", caller.String())
}

func getReport(t *tx, id int) (ReportInfo, bool) {
	rec, ok := t.get(cReports, store.Pad(id))
	if !ok || id < 1 {
		return ReportInfo{}, false
	}
	f := store.Fields(rec)
	return ReportInfo{ID: id, Kind: f[0], Target: f[1], Reason: f[2], By: address(f[3]), At: text.Atoi64(f[4])}, true
}

// ResolveReport closes a report once handled. Admin only.
func ResolveReport(cur realm, id int) {
	onlyAdmin(cur)
	t := rd()
	if !resolve(t, id) {
		panic("catalog: unknown report")
	}
	save(cur, t)
}

// ResolveReports closes the open reports with ids from..from+count-1 (count
// 1-50) in one transaction, e.g. a run of spam reports; ids already closed
// are skipped. There is no global cap on open reports, so spam never blocks
// an honest reporter: each wallet keeps at most 5 open. Admin only.
func ResolveReports(cur realm, from, count int) {
	onlyAdmin(cur)
	if count < 1 || count > 50 {
		panic("catalog: resolve 1 to 50 reports at a time")
	}
	t := rd()
	for id := from; id < from+count; id++ {
		resolve(t, id)
	}
	save(cur, t)
}

// resolve closes one report, false when there is no such open report.
func resolve(t *tx, id int) bool {
	r, ok := getReport(t, id)
	if !ok {
		return false
	}
	t.del(cReports, store.Pad(id))
	if t.count(mOpen) > 0 {
		t.bump(mOpen, -1)
	}
	if u := user(t, r.By); u.Reports > 0 {
		u.Reports--
		putUser(t, r.By, u)
	}
	emitEvent("ReportResolved", "id", text.Itoa(id))
	return true
}

// Hide or restore content. Admin only; hiding takes a public reason (4-200
// characters) and restoring works on anything, whoever hid it. Hidden content
// stays on-chain (and on IPFS); it is no longer listed, played or tippable.
// Radio stations drop a hidden track on their next Refresh
// (radio.RefreshArtist for a whole artist).
func HideTrack(cur realm, trackID int, hidden bool, reason string) {
	onlyAdmin(cur)
	t := rd()
	tr := getTrack(t, trackID)
	if tr == nil {
		panic("catalog: unknown track")
	}
	tr.Hidden = hidden
	putTrack(t, tr)
	moderate(cur, t, "track", trackID, hidden, reason)
}

func HideAlbum(cur realm, albumID int, hidden bool, reason string) {
	onlyAdmin(cur)
	t := rd()
	al := getAlbum(t, albumID)
	if al == nil {
		panic("catalog: unknown album")
	}
	al.Hidden = hidden
	putAlbum(t, al)
	moderate(cur, t, "album", albumID, hidden, reason)
}

func HideArtist(cur realm, artistID int, hidden bool, reason string) {
	onlyAdmin(cur)
	t := rd()
	a := getArtist(t, artistID)
	if a == nil {
		panic("catalog: unknown artist")
	}
	a.Hidden = hidden
	putArtist(t, a)
	moderate(cur, t, "artist", artistID, hidden, reason)
}

func HidePlaylist(cur realm, playlistID int, hidden bool, reason string) {
	onlyAdmin(cur)
	t := rd()
	p := getPlaylist(t, playlistID)
	if p == nil {
		panic("catalog: unknown playlist")
	}
	p.Hidden = hidden
	putPlaylist(t, p)
	moderate(cur, t, "playlist", playlistID, hidden, reason)
}

// moderate records the moderator's public reason and saves t.
func moderate(cur realm, t *tx, kind string, id int, hidden bool, reason string) {
	mark(t, kind, id, hidden, reason)
	save(cur, t)
}

// mark records the moderator's public reason for one item (the caller saves).
func mark(t *tx, kind string, id int, hidden bool, reason string) {
	reason = strings.TrimSpace(reason)
	k := kind + ":" + text.Itoa(id)
	if hidden {
		mustText("reason", reason, 4, maxReason)
		t.set(cRemoved, k, reason)
	} else {
		t.del(cRemoved, k)
	}
	emitEvent("Moderated", "kind", kind, "target", text.Itoa(id), "hidden", strconv.FormatBool(hidden), "reason", reason, "by", "moderator")
}

// maxHideBatch bounds HideSource: 2 writes per artist.
const maxHideBatch = 50

// HideSource hides every artist read from a platform ("audius" or
// "jamendo"), and so all their tracks, for a platform that ends GnoRadio's
// API access. It walks artist ids from `from`, count (1-50) at a time, and
// returns where to go on (0 once past the last artist). One artist opting out
// is a HideArtist. Admin only.
func HideSource(cur realm, kind string, from, count int, reason string) int {
	onlyAdmin(cur)
	if !isRef(kind) || from < 1 || count < 1 || count > maxHideBatch {
		panic("catalog: HideSource(audius|jamendo, from >= 1, count 1-" + text.Itoa(maxHideBatch) + ", reason)")
	}
	mustText("reason", strings.TrimSpace(reason), 4, maxReason)
	t := rd()
	last := int(t.count(mArtists))
	for id := from; id < from+count && id <= last; id++ {
		if a := getArtist(t, id); a != nil && a.Kind == kind {
			// An artist that hid itself gets the reason too, so HideOwn cannot show it again;
			// one a moderator hid keeps its own reason.
			if r, ok := t.get(cRemoved, "artist:"+text.Itoa(id)); a.Hidden && ok && r != "" {
				continue
			}
			if !a.Hidden {
				a.Hidden = true
				putArtist(t, a)
			}
			mark(t, "artist", id, true, reason)
		}
	}
	save(cur, t)
	if from+count > last {
		return 0
	}
	return from + count
}

// HideOwn hides or shows again the caller's own track, album or artist
// profile ("artist", with the profile's id). The artist can show again only
// what they hid themselves: what the moderator hid stays hidden.
func HideOwn(cur realm, kind string, id int, hidden bool) {
	caller := userCaller(cur)
	noPayment()
	t := rd()
	a := getArtist(t, artistOf(t, caller))
	if a == nil {
		panic("catalog: create your artist profile first")
	}
	k := kind + ":" + text.Itoa(id)
	if reason, ok := t.get(cRemoved, k); ok && reason != "" {
		panic("catalog: hidden by the moderator; contact them to restore it")
	}
	switch kind {
	case "track":
		tr := getTrack(t, id)
		if tr == nil || tr.Artist != a.ID {
			panic("catalog: not your track")
		}
		mustToggle(tr.Hidden, hidden)
		tr.Hidden = hidden
		putTrack(t, tr)
	case "album":
		al := getAlbum(t, id)
		if al == nil || al.Artist != a.ID {
			panic("catalog: not your album")
		}
		mustToggle(al.Hidden, hidden)
		al.Hidden = hidden
		putAlbum(t, al)
	case "artist":
		if id != a.ID {
			panic("catalog: not your profile")
		}
		mustToggle(a.Hidden, hidden)
		a.Hidden = hidden
		putArtist(t, a)
	default:
		panic("catalog: kind must be track, album or artist")
	}
	if hidden {
		t.set(cRemoved, k, "")
	} else {
		t.del(cRemoved, k)
	}
	save(cur, t)
	emitEvent("Moderated", "kind", kind, "target", text.Itoa(id), "hidden", strconv.FormatBool(hidden), "reason", "", "by", "artist")
}

func mustToggle(was, hidden bool) {
	if was == hidden {
		if hidden {
			panic("catalog: already hidden")
		}
		panic("catalog: already shown")
	}
}

// HiddenNote says why a track, album, artist or playlist is hidden, for its
// page: "Removed by moderation: <reason>", "Hidden by the artist.", or "".
func HiddenNote(kind string, id int) string {
	reason, ok := rd().get(cRemoved, kind+":"+text.Itoa(id))
	switch {
	case !ok:
		return ""
	case reason == "":
		return "Hidden by the artist."
	}
	return "Removed by moderation: " + reason
}

// Verify marks an artist whose identity was checked off-chain.
func Verify(cur realm, artistID int, verified bool) {
	onlyAdmin(cur)
	t := rd()
	a := mustArtist(t, artistID)
	a.Verified = verified
	putArtist(t, a)
	t.del(cClaims, store.Pad(artistID)) // settled by the admin either way
	if !verified {
		t.del(cProofs, store.Pad(artistID))
	}
	save(cur, t)
	emitEvent("Verified", "artist", text.Itoa(artistID), "verified", strconv.FormatBool(verified))
}

// AllowHost adds or removes an https host that audio and covers may use.
func AllowHost(cur realm, host string, allowed bool) {
	onlyAdmin(cur)
	host = strings.ToLower(strings.TrimSpace(host))
	if !validHost(host) {
		panic("catalog: invalid host")
	}
	t := rd()
	if allowed {
		t.set(cHosts, host, "1")
	} else {
		t.del(cHosts, host)
	}
	save(cur, t)
	emitEvent("HostAllowed", "host", host, "allowed", strconv.FormatBool(allowed))
}
