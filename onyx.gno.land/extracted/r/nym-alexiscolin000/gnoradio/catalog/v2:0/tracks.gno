package catalog

import (
	"strconv"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// Tracks are added and edited through the radio realm only (radio.PublishTrack,
// radio.ImportTrack, radio.EditTrack): it puts a new track in the station
// rotations, and moves an edited one, in the same transaction. The radio
// names the wallet that signed (caller, by); only the radio writer the data
// realm names may call these.

// PublishFor adds a track by caller's own artist profile.
// duration is "m:ss"; cmo is "none" or "sacem-nc"; splits is optional,
// "g1...:30,g1...:15" in percent (the artist keeps at least 10%);
// rights must be "yes" (the caller accepts RightsTerms).
// audio and cover are ipfs://, ar:// or https:// links (an allowed host,
// with the file's sha256).
func PublishFor(cur realm, caller address, title string, genre int, duration, license, cmo, credits, audio, audioSHA, cover, coverSHA, splits, rights string) int {
	onlyRadio(cur)
	noPayment()
	t := rd()
	aid, _ := ownArtist(t, caller)
	if strings.ToLower(strings.TrimSpace(rights)) != "yes" {
		panic("catalog: accept the rights declaration (answer yes)")
	}
	tr := &Track{Origin: OriginArtist, CMO: "none"}
	setInfo(tr, title, genre, duration, credits, true)
	mustRefAudio(tr, audio)
	setLicense(tr, license, cmo)
	setMedia(tr, audio, audioSHA, cover, coverSHA)
	tr.Splits = parseSplits(splits, caller)
	id := addTrack(t, caller, aid, tr)
	save(cur, t)
	return id
}

// ImportFor adds a curated (CC0 / CC BY / CC BY-SA / CC BY-NC / CC BY-NC-SA)
// track, or a pointer to an Audius or Jamendo track, to an unclaimed artist.
// by must be the admin. A pointer keeps only what the radio needs (audio
// "audius:<id>" or "jamendo:<id>", genre, duration, licence): title, credits,
// cover, source and attribution stay empty and the app reads them live from
// the platform, whose API terms allow session caching only.
func ImportFor(cur realm, by address, artistID int, title string, genre int, duration, license, credits, audio, audioSHA, cover, coverSHA, sourceURL, attribution string) int {
	onlyRadio(cur)
	noPayment()
	if by == "" || by != adminAddr() {
		panic("catalog: admin only")
	}
	t := rd()
	a := mustArtist(t, artistID)
	if a.Kind == OriginArtist {
		panic("catalog: artists publish their own tracks")
	}
	tr := &Track{Origin: a.Kind, CMO: "none"}
	setInfo(tr, title, genre, duration, credits, false)
	mustRefAudio(tr, audio)
	if tr.Origin == OriginAudius {
		tr.License = AudiusLicense
	} else if tr.License = curatedLicense(license); tr.License == "" {
		panic("catalog: curated imports must be CC0, CC BY, BY-SA, BY-NC or BY-NC-SA")
	}
	setMedia(tr, audio, audioSHA, cover, coverSHA)
	sourceURL, attribution = strings.TrimSpace(sourceURL), strings.TrimSpace(attribution)
	if isRef(tr.Origin) {
		if cover != "" || sourceURL != "" || attribution != "" {
			panic("catalog: a pointer stores no cover, source or attribution")
		}
	} else {
		if !text.HTTPS(sourceURL, 300) {
			panic("catalog: sourceURL must be the track's https page at the source")
		}
		mustText("attribution", attribution, 2, maxCredits)
	}
	tr.SourceURL, tr.Attribution = sourceURL, attribution
	if isRef(tr.Origin) { // one record per platform track (the key has a '-', no name skeleton does)
		if _, dup := t.get(cNames, refKey+tr.Audio); dup {
			panic("catalog: this pointer track is already imported (hide it and ReleaseName \"" + refKey + tr.Audio + "\" to import it again)")
		}
	}
	id := addTrack(t, adminAddr(), a.ID, tr)
	if isRef(tr.Origin) { // pointers imported before this key existed have none: fine on a fresh chain
		t.set(cNames, refKey+tr.Audio, text.Itoa(id))
	}
	save(cur, t)
	return id
}

// EditFor fixes a track's details. Its artist only (the admin while the
// artist is unclaimed): caller is who signed.
func EditFor(cur realm, caller address, trackID int, title string, genre int, duration, credits, audio, audioSHA, cover, coverSHA string) {
	onlyRadio(cur)
	noPayment()
	t := rd()
	tr := mustTrack(t, trackID)
	a := getArtist(t, tr.Artist)
	if !mayEdit(caller, a) {
		panic("catalog: only the artist can edit this track")
	}
	mustRefAudio(tr, audio)
	// A pointer keeps its platform id and stores no cover: only its genre,
	// duration and (claimed owner) title change.
	if isRef(tr.Origin) && (strings.TrimSpace(audio) != tr.Audio || strings.TrimSpace(cover) != "" || strings.TrimSpace(coverSHA) != "") {
		panic("catalog: a pointer keeps its audio and stores no cover")
	}
	oldGenre := tr.Genre
	// The owner of a claimed Audius or Jamendo profile may name their own
	// tracks: the record then stores the title with the artist's consent.
	setInfo(tr, title, genre, duration, credits, a.Owner != "")
	if tr.Genre != oldGenre {
		t.removeID(cGenres, store.Pad(oldGenre), tr.ID)
		t.addID(cGenres, store.Pad(tr.Genre), tr.ID)
		t.bump(mGenre+oldGenre, -1)
		t.bump(mGenre+tr.Genre, 1)
	}
	setMedia(tr, audio, audioSHA, cover, coverSHA)
	t.setRec(cTracks, tr.ID, fits(trackRecord(tr)))
	save(cur, t)
	emitEvent("TrackEdited", "id", text.Itoa(tr.ID), "audio", tr.Audio, "duration", text.Itoa64(tr.Duration), "genre", text.Itoa(tr.Genre))
}

func addTrack(t *tx, publisher address, artistID int, tr *Track) int {
	trackIDs, albumIDs := lists(t, artistID)
	if store.Count(trackIDs) >= maxPerArtist {
		panic("catalog: tracks per artist limit reached")
	}
	t.bump(mGenre+tr.Genre, 1)
	tr.ID, tr.Artist, tr.Created = int(t.bump(mTracks, 1)), artistID, now()
	t.addRec(cTracks, tr.ID, fits(trackRecord(tr)))
	setLists(t, artistID, trackIDs+store.Enc(tr.ID), albumIDs)
	t.addID(cGenres, store.Pad(tr.Genre), tr.ID)
	t.activity("publish", publisher, text.Itoa(tr.ID), text.Itoa(artistID), "0")
	emitEvent("TrackPublished", "id", text.Itoa(tr.ID), "artist", text.Itoa(artistID), "origin", tr.Origin, "genre", text.Itoa(tr.Genre),
		"duration", text.Itoa64(tr.Duration), "title", tr.Title, "audio", tr.Audio, "license", tr.License)
	return tr.ID
}

// setInfo sets a track's text and timing. An Audius or Jamendo pointer stores
// no title or credits unless named: its claimed artist's owner fills them in.
// Without that, an edit may keep or clear the stored text (a legacy import), never set new text.
func setInfo(tr *Track, title string, genre int, duration, credits string, named bool) {
	title, credits = strings.TrimSpace(title), strings.TrimSpace(credits)
	switch {
	case isRef(tr.Origin) && (title == "" || title == tr.Title) && (credits == "" || credits == tr.Credits): // cleared or unchanged
	case isRef(tr.Origin) && !named:
		panic("catalog: a pointer stores no title or credits (the app reads them from the platform)")
	default:
		mustText("title", title, 1, maxTitle)
		mustText("credits", credits, 0, maxCredits)
	}
	if genre < 1 || genre > NumGenres {
		panic("catalog: genre must be 1.." + text.Itoa(NumGenres))
	}
	d, ok := parseClock(duration)
	if !ok || d < minDuration || d > maxDuration {
		panic("catalog: duration as m:ss, between 0:10 and 20:00")
	}
	tr.Title, tr.Genre, tr.Duration, tr.Credits = title, genre, d, credits
}

// refKey prefixes a pointer's audio in cNames (the '-' keeps it off every name skeleton).
const refKey = "track-"

// isRef reports whether tracks of this origin are pointers: read live from
// Audius or Jamendo, with no title or credits stored on chain.
func isRef(origin string) bool { return origin == OriginAudius || origin == OriginJamendo }

// mustRefAudio keeps a pointer's audio on its platform ("audius:<id>",
// "jamendo:<id>") and every other track off both.
func mustRefAudio(tr *Track, audio string) {
	prefix := strings.TrimSpace(audio)
	if i := strings.IndexByte(prefix, ':'); i >= 0 {
		prefix = prefix[:i]
	}
	if isRef(prefix) != isRef(tr.Origin) || isRef(tr.Origin) && prefix != tr.Origin {
		panic("catalog: Audius and Jamendo tracks use audio audius:<id> or jamendo:<id>, other tracks neither")
	}
}

// refLabel is what gnoweb shows for a pointer's empty title or name: the
// platform it is read from ("Audius track", "Jamendo artist").
func refLabel(origin, stored, what string) string {
	if stored != "" || !isRef(origin) {
		return stored
	}
	return strings.ToUpper(origin[:1]) + origin[1:] + " " + what
}

func setLicense(tr *Track, license, cmo string) {
	lic := normLicense(license)
	if lic == "" {
		panic("catalog: unknown license, use one of " + strings.Join(licenses, ", "))
	}
	cmo = strings.ToLower(strings.TrimSpace(cmo))
	switch cmo {
	case "", "none":
		cmo = "none"
	case "sacem-nc":
		if !strings.Contains(lic, "-NC") {
			panic("catalog: SACEM members may only publish works declared under a CC NC license")
		}
	default:
		panic("catalog: collective society must be none or sacem-nc")
	}
	tr.License, tr.CMO = lic, cmo
}

func setMedia(tr *Track, audio, audioSHA, cover, coverSHA string) {
	audio, audioSHA = strings.TrimSpace(audio), strings.ToLower(strings.TrimSpace(audioSHA))
	cover, coverSHA = strings.TrimSpace(cover), strings.ToLower(strings.TrimSpace(coverSHA))
	mustMedia("audio", audio, audioSHA, true)
	if coverSHA != "" && (cover == "" || !isSHA256(coverSHA)) { // coverSHA goes into the JSON as is
		panic("catalog: cover sha256 must be 64 hex characters, with a cover")
	}
	if cover != "" {
		mustMedia("cover", cover, coverSHA, false)
	}
	tr.Audio, tr.AudioSHA, tr.Cover, tr.CoverSHA = audio, audioSHA, cover, coverSHA
}

// parseSplits reads the collaborators: never the artist, never a GnoRadio realm.
func parseSplits(s string, artist address) []Split {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	if len(parts) > maxSplits {
		panic("catalog: at most 4 collaborators")
	}
	var out []Split
	var sum int64
	seen := map[string]bool{}
	for _, p := range parts {
		addrStr, pctStr, ok := strings.Cut(strings.TrimSpace(p), ":")
		to := address(strings.TrimSpace(addrStr))
		pct, err := strconv.ParseInt(strings.TrimSuffix(strings.TrimSpace(pctStr), "%"), 10, 64)
		if !ok || err != nil || !role.Canonical(to) || to == artist || data.IsGnoRadio(to) || seen[to.String()] || pct < 1 || pct > maxSplitPct {
			panic("catalog: collaborators as g1...:30,g1...:15 (percent)")
		}
		seen[to.String()] = true
		sum += pct
		out = append(out, Split{To: to, Pct: pct})
	}
	if sum > maxSplitPct {
		panic("catalog: collaborators may receive at most 90%")
	}
	return out
}
