// Package home is the GnoRadio website on gnoweb, release 1. It owns no
// data: every page is rendered from the catalog, radio and tickets realms,
// and its two settings (app.gno) live in the data realm, "home/config".
package home

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	roles "gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/safe/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"

	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v1"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
	"gno.land/r/nym-alexiscolin000/gnoradio/radio/v1"
	"gno.land/r/nym-alexiscolin000/gnoradio/tickets/v1"
)

const (
	catalogPath = "gno.land/r/nym-alexiscolin000/gnoradio/catalog/v1"
	radioPath   = "gno.land/r/nym-alexiscolin000/gnoradio/radio/v1"
	ticketsPath = "gno.land/r/nym-alexiscolin000/gnoradio/tickets/v1"
	dataPath    = "gno.land/r/nym-alexiscolin000/gnoradio/data"
	maxCovers   = 8
	pageSize    = 20
	ugnot       = 1_000_000
)

var (
	catalogTx = txlink.Realm(catalogPath)
	radioTx   = txlink.Realm(radioPath)
	ticketsTx = txlink.Realm(ticketsPath)
	dataTx    = txlink.Realm(dataPath)
	self      = unsafe.CurrentRealm().PkgPath()
	base      = strings.TrimPrefix(self, runtime.ChainDomain()) // gnoweb path of this realm
)

// Render serves:
//
//	""                       home: main station on air, stations, new releases, top, concerts
//	"stations" "station/<n>" radio stations and their schedule
//	"track/<id>"             a track
//	"artist/<id|name>"       an artist
//	"album/<id>" "playlist/<id>"
//	"catalog?p=N&g=G" "artists?p=N" "albums?p=N" "playlists?p=N"
//	"concerts?p=N" "event/<id>" "ticket/<id>"
//	"listener" "listener/<g1…>" listeners: top curators; one listener's likes, playlists, tickets, badges
//	"charts" "join" "about" "moderation?p=N"
//
// Bare entity segments ("track", "artist"…, linked by gnoweb's breadcrumb)
// open the matching list. Entity pages with long lists take ?p=N too.
//
// Raw path input is never echoed: ids are parsed, names and addresses looked up.
func Render(path string) string {
	p, query, _ := strings.Cut(path, "?")
	pg, genre := 1, 0
	for _, kv := range strings.Split(query, "&") {
		k, v, _ := strings.Cut(kv, "=")
		switch n := atoi(v); k {
		case "p":
			if n > 1 && n < 100000 {
				pg = n
			}
		case "g":
			if n >= 1 && n <= catalog.NumGenres {
				genre = n
			}
		}
	}
	out := route(p, pg, genre)
	if out == "" {
		out = header("Not found", "-") + "This page does not exist. [← Back to the radio](" + page("") + ")\n"
	}
	return banner() + out
}

// banner tells visitors what the data realm says of the release in force
// (data.Writers): a newer site, a paused role, or a release on its way.
func banner() string {
	if s := data.Writer("home"); s != self {
		return "> [!WARNING] GnoRadio has moved\n> The new version lives at [" + s + "](" +
			strings.TrimPrefix(s, runtime.ChainDomain()) + ").\n\n"
	}
	for _, r := range [3]string{"catalog", "radio", "tickets"} {
		if data.Paused(r) {
			return "> [!CAUTION] GnoRadio is paused\n> Its owner or guardian stopped the " + r +
				" for now. Pages stay readable, and promo budgets can still be withdrawn.\n\n"
		}
	}
	if at := releaseAt(data.Writers()); at > 0 {
		return "> [!NOTE] A new release takes over on " + date(at) + "\n> Its code is public until then: [see what changes](" +
			strings.TrimPrefix(dataPath, runtime.ChainDomain()) + "$source&file=data.gno), `Writers()`.\n\n"
	}
	return ""
}

// releaseAt reads "at" of data.Writers(): when a ready release takes over, 0
// when none is on its way.
func releaseAt(js string) int64 {
	_, v, ok := strings.Cut(js, `"at":`)
	if !ok {
		return 0
	}
	if i := strings.IndexByte(v, ','); i >= 0 {
		v = v[:i]
	}
	n, _ := strconv.ParseInt(v, 10, 64)
	return n
}

func route(p string, pg, genre int) string {
	switch p {
	case "":
		return renderHome()
	case "stations", "station":
		return renderStations()
	case "catalog", "track":
		return renderCatalog(pg, genre)
	case "artists", "artist":
		return renderArtists(pg)
	case "albums", "album":
		return renderAlbums(pg)
	case "playlists", "playlist":
		return renderPlaylists(pg)
	case "concerts", "event", "ticket":
		return renderConcerts(pg)
	case "listener":
		return renderListeners()
	case "charts":
		return renderCharts()
	case "join":
		return renderJoin()
	case "about":
		return renderAbout()
	case "moderation":
		return renderModeration(pg)
	}
	kind, arg, ok := strings.Cut(p, "/")
	if !ok {
		return ""
	}
	switch kind {
	case "station":
		if n, err := strconv.Atoi(arg); err == nil && n >= 0 && n < radio.StationCount() {
			return renderStation(n)
		}
	case "track":
		if t, ok := catalog.GetTrack(atoi(arg)); ok {
			return renderTrack(t)
		}
	case "artist":
		id := atoi(arg)
		if id == 0 {
			id = catalog.ArtistByName(arg)
		}
		if a, ok := catalog.GetArtist(id); ok {
			if a.Hidden {
				return renderRemoved(catalog.HiddenNote("artist", a.ID))
			}
			return renderArtist(a, pg)
		}
	case "album":
		if al, ok := catalog.GetAlbum(atoi(arg)); ok {
			switch {
			case al.Hidden:
				return renderRemoved(catalog.HiddenNote("album", al.ID))
			case !catalog.ArtistVisible(al.Artist):
				return renderRemoved(catalog.HiddenNote("artist", al.Artist))
			}
			return renderAlbum(al)
		}
	case "playlist":
		if pl, ok := catalog.GetPlaylist(atoi(arg)); ok {
			if pl.Hidden {
				return renderRemoved(catalog.HiddenNote("playlist", pl.ID))
			}
			return renderPlaylist(pl, pg)
		}
	case "event":
		id := atoi(arg)
		if e, ok := tickets.EventInfo(id); ok {
			if !catalog.ArtistVisible(e.ArtistID) {
				return renderRemoved(catalog.HiddenNote("artist", e.ArtistID))
			}
			return renderEvent(e)
		}
		if note := tickets.HiddenNote(id); note != "" {
			return renderRemoved(note)
		}
	case "ticket":
		if tk, ok := tickets.TicketInfo(atoi(arg)); ok {
			return renderTicket(tk)
		}
	case "listener":
		if addr := address(arg); roles.Canonical(addr) { // never the upper-case spelling of a wallet
			return renderListener(addr, pg)
		}
	}
	return ""
}

// ---- pages ----

func renderHome() string {
	var b strings.Builder
	b.WriteString(header("GnoRadio", ""))
	b.WriteString("**Community radio and open music player, 100% on-chain: every tip lands in the artist's wallet, in the same transaction.** " +
		"[Read the code that guarantees it](" + sourceURL(catalogPath, "social.gno") + ").\n\n")
	listen := page("station/0")
	if u := appURL(); u != "" {
		listen = strings.TrimRight(u, "/") + "/"
	}
	b.WriteString("**[▶ Listen now](" + listen + ")** · **[Pick a track](" + page("catalog") + ")** · **[◈ Tip an artist](" + page("artists") + ")**\n\n")
	b.WriteString(onAir(0))

	b.WriteString("<gno-columns>\n## Stations\n\n")
	for _, s := range stationOrder()[:7] {
		tracks, _, _ := radio.StationInfo(s)
		b.WriteString("- " + stationLink(s) + " · " + plural(tracks, "track") + "\n")
	}
	b.WriteString("\n[All stations →](" + page("stations") + ")\n")
	b.WriteString("<gno-columns-sep />\n## Most liked\n\n")
	shown := 0
	for _, r := range catalog.TopLiked() {
		if t, ok := catalog.GetTrack(atoi(r.Key)); ok && playable(t) && shown < 6 {
			shown++
			b.WriteString(text.Itoa(shown) + ". " + trackLink(t) + " · ♥ " + text.Itoa(t.Likes) + "\n")
		}
	}
	if shown == 0 {
		b.WriteString("No likes yet.\n")
	}
	b.WriteString("<gno-columns-sep />\n## Concerts\n\n")
	up := tickets.Upcoming(4)
	if len(up) == 0 {
		b.WriteString("No concert announced. [Announce yours](" + page("join") + ").\n")
	}
	for _, e := range up {
		b.WriteString("- [" + md(e.Title) + "](" + page("event/"+text.Itoa(e.ID)) + ") · " + date(e.Start) + "\n")
	}
	b.WriteString("</gno-columns>\n\n## New releases\n\n")
	var fresh []catalog.Track
	for _, id := range catalog.TrackPage(0, 40, true) {
		if t, ok := catalog.GetTrack(id); ok && playable(t) {
			if fresh = append(fresh, t); len(fresh) == maxCovers {
				break
			}
		}
	}
	switch {
	case len(fresh) > 0:
	case catalog.TrackCount() == 0:
		b.WriteString("> [!INFO] The catalog is empty\n> [Publish the first track](" + page("join") + ").\n")
	default:
		b.WriteString("> [!INFO] No release to show among the newest tracks\n> [Browse the catalog](" + page("catalog") + ").\n")
	}
	b.WriteString(coverGrid(fresh))
	b.WriteString("\n[Full catalog →](" + page("catalog") + ")\n\n")
	if hasTreasury() {
		b.WriteString("<gno-columns>\n" + supportBlock() + "<gno-columns-sep />\n## Recent activity\n\n" + activityFeed(8) + "</gno-columns>\n\n---\n\n" + stats())
	} else {
		b.WriteString("## Recent activity\n\n" + activityFeed(8) + "\n---\n\n" + stats())
	}
	return b.String()
}

// coverGrid lays covers out in columns, each with a "Title · Artist" line.
func coverGrid(ts []catalog.Track) string {
	if len(ts) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("<gno-columns>\n")
	for i, t := range ts {
		if i > 0 {
			b.WriteString("<gno-columns-sep />\n")
		}
		link := page("track/" + text.Itoa(t.ID))
		b.WriteString("[" + coverSVG(t.ID, t.Artist, t.Title, 150) + "](" + link + ")\n\n**[" + md(t.Title) + "](" + link + ")** · " + artistRef(t.Artist) + "\n")
	}
	return b.String() + "</gno-columns>\n"
}

// hasTreasury is false at the free launch: support and the tip share panic then.
func hasTreasury() bool { return catalog.Treasury().IsValid() }

// supportBlock shows GnoRadio's own funding: treasury, monthly goal, links.
func supportBlock() string {
	if !hasTreasury() {
		return ""
	}
	to, total, supporters, monthTotal, goal := catalog.SupportInfo()
	var b strings.Builder
	b.WriteString("## Keep GnoRadio on air\n\n")
	if goal > 0 {
		b.WriteString("This month: **" + text.GNOT(monthTotal) + "** of " + text.GNOT(goal) + "  \n")
	} else {
		b.WriteString("This month: **" + text.GNOT(monthTotal) + "**  \n")
	}
	b.WriteString(text.GNOT(total) + " from " + plural(supporters, "supporter") + " since launch")
	if to.IsValid() {
		b.WriteString(", to the " + role(to, "GnoRadio treasury"))
	}
	b.WriteString(".\n\n**◈ Support:** [1 GNOT](" + supportURL(1) + ") · [5 GNOT](" + supportURL(5) + ") · [20 GNOT](" + supportURL(20) + ")  \n" +
		"Optional. GnoRadio pays nothing to run: listeners and artists sign their own transactions. Support funds the project's work; artists' tips never fund it. " +
		"[Read the code](" + sourceURL(catalogPath, "support.gno") + ").\n")
	return b.String()
}

// activityFeed merges the catalog's and the radio's latest public actions,
// newest first, as the app does.
func activityFeed(n int) string {
	cat, rad := catalog.Activities(n), radio.Activities(n)
	var b strings.Builder
	for i, j, k := 0, 0, 0; k < n && (i < len(cat) || j < len(rad)); k++ {
		if j >= len(rad) || i < len(cat) && cat[i].At >= rad[j].At {
			b.WriteString(catalogLine(cat[i]))
			i++
		} else {
			b.WriteString(radioLine(rad[j]))
			j++
		}
	}
	if b.Len() == 0 {
		return "Nothing yet: like, tip, pick or publish to start the feed.\n"
	}
	return b.String()
}

func catalogLine(a catalog.Activity) string {
	line := ""
	switch a.Kind {
	case "publish":
		line = "published " + trackRef(a.Track)
	case "like":
		line = "liked " + trackRef(a.Track)
	case "tip":
		line = "tipped " + text.GNOT(a.Amount) + " on " + trackRef(a.Track)
	case "support":
		line = "supported GnoRadio with " + text.GNOT(a.Amount)
	case "follow":
		line = "followed " + artistRef(a.Artist)
	case "playlist":
		line = "published [a playlist](" + page("playlist/"+text.Itoa(a.Track)) + ")"
	case "album":
		line = "released [an album](" + page("album/"+text.Itoa(a.Track)) + ")"
	case "claim":
		return "- **Profile verified** · " + artistRef(a.Artist) + " · " + date(a.At) + "\n"
	default:
		line = md(a.Kind)
	}
	return "- " + who(a.By) + " " + line + " · " + date(a.At) + "\n"
}

func radioLine(a radio.Activity) string {
	verb := "picked "
	switch a.Kind {
	case "curator":
		verb = "programmed "
	case "sponsored":
		verb = "made a sponsored pick of "
	}
	where := ""
	if a.Station >= 0 && a.Station < radio.StationCount() {
		where = " on " + stationLink(a.Station)
	}
	return "- " + who(a.By) + " " + verb + trackRef(a.Track) + where + " · " + date(a.At) + "\n"
}

func onAir(st int) string {
	id, off, queued := radio.NowPlaying(st)
	t, ok := catalog.GetTrack(id)
	if id == 0 || !ok || !playable(t) {
		return onAirSVG(radio.StationName(st), "", "", 0, 0) + "\n\n"
	}
	src := "rotation"
	if queued && radio.OnAirPay(st) > 0 {
		src = "sponsored pick · paid by " + md(catalog.ArtistName(t.Artist))
	} else if queued {
		src = "queued by a listener"
		if n := radio.OnAirNote(st); n != "" {
			src += " · ♥ *" + md(n) + "*"
		}
	}
	live := ""
	if l := inApp("stations", "Go live in the app"); l != "" {
		live = " · " + l
	}
	out := onAirSVG(radio.StationName(st), t.Title, catalog.ArtistName(t.Artist), off, t.Duration) + "\n\n" +
		"**[▶ Listen from " + clock(off) + "](" + listenURL(t.ID, t.Audio, off) + ")** · " + trackLink(t) + " · " + src + live + "\n\n"
	if tippable(catalog.ArtistOwner(t.Artist), catalog.ArtistVerified(t.Artist)) {
		out += "**◈ Tip it on air:** [1 GNOT](" + tipOnAirURL(st, t.ID, 1) + ") · [5 GNOT](" + tipOnAirURL(st, t.ID, 5) + ") · [20 GNOT](" + tipOnAirURL(st, t.ID, 20) + ")"
		if queued && radio.OnAirPay(st) == 0 {
			if p := catalog.PromoShare(t.Artist); p > 0 {
				out += " · " + text.Itoa(p) + "% goes to the listener who picked it"
			}
		}
		out += "\n\n"
	}
	return out
}

func renderStations() string {
	var b strings.Builder
	b.WriteString(header("Stations", "stations"))
	b.WriteString("Every station plays the same second for everyone. Pick one, or queue a track on it from any track page.")
	if l := inApp("stations", "Listen in the app"); l != "" {
		b.WriteString(" " + l + ".")
	}
	// One line per station rather than a table: it reads on a phone.
	b.WriteString("\n\n")
	for _, s := range stationOrder() {
		tracks, _, queued := radio.StationInfo(s)
		line := "- **" + stationLink(s) + "** · " + plural(tracks, "track")
		if queued > 0 {
			line += " · " + plural(queued, "pick") + " waiting"
		}
		if id, _, _ := radio.NowPlaying(s); id != 0 {
			line += " · on air: " + md(catalog.TrackTitle(id))
		}
		b.WriteString(line + "\n")
	}
	if p := radio.Pending(); p > 0 {
		b.WriteString("\n" + plural(p, "track") + " not on the stations yet: [add them](" + radioTx.NewLink("Sync").AddArgs("max", "200").URL() + ") (anyone can).\n")
	}
	b.WriteString("\n" + pickRules())
	return b.String()
}

// pickRules explains the limits radio enforces, read from radio itself.
func pickRules() string {
	cooldown, replay, ahead, queue, perArtist, bookMin, bookMax, perHour, booked := radio.PickRules()
	return "## How picks work\n\n" +
		"- One pick per listener per station per " + strings.TrimPrefix(hours(cooldown), "1 ") + ", and one waiting per station.\n" +
		"- " + text.Itoa(perArtist) + " waiting per artist on a station; a track is not picked again on a station within " + hours(replay) + ".\n" +
		"- Genre stations take only their genre; New this week takes only new tracks.\n" +
		"- At most " + hours(ahead) + " of picks ahead on a station, " + text.Itoa(queue) + " waiting at most.\n" +
		"- A pick can be booked " + text.Itoa(int(bookMin/60)) + " minutes to " + hours(bookMax) + " ahead, " + text.Itoa(perHour) + " booked picks per station per hour (UTC) and " + text.Itoa(booked) + " of the " + text.Itoa(queue) + " waiting at most.\n" +
		"- A pick starts when the song on air ends: nothing is cut.\n"
}

// hours says a whole number of hours in words: "1 hour", "3 hours".
func hours(sec int64) string { return plural(int(sec/3600), "hour") }

func renderStation(st int) string {
	var b strings.Builder
	b.WriteString(header(md(radio.StationName(st)), "-"))
	tracks, _, _ := radio.StationInfo(st)
	if tracks == 0 {
		b.WriteString("> [!INFO] This station is empty for now\n> " + genreBrowse(st) + "\n\n")
		return b.String()
	}
	b.WriteString(onAir(st))
	b.WriteString("## Up next\n\n")
	shown := 0
	for _, s := range radio.UpNext(st) {
		if shown == 10 {
			break
		}
		t, ok := catalog.GetTrack(s.Track)
		if !ok {
			continue
		}
		shown++
		line := "- " + hour(s.Start) + " UTC · " + trackLink(t) + " · queued by " + who(s.By)
		if s.At > 0 {
			line = "- " + day(s.Start) + hour(s.Start) + " UTC · " + trackLink(t) + " · booked by " + who(s.By)
		}
		if s.Pay > 0 {
			line += " · sponsored pick, paid by " + md(catalog.ArtistName(t.Artist))
		}
		if s.Note != "" {
			line += " · ♥ *" + md(s.Note) + "*"
		}
		b.WriteString(line + "\n")
	}
	if shown == 0 {
		b.WriteString("Nothing queued: the rotation plays. " + genreBrowse(st) + "\n")
	}
	b.WriteString("\n" + topCurators(st) + flowLine(st, tracks))
	return b.String()
}

// flowLine says how a station chooses what plays when nobody picked.
func flowLine(st, tracks int) string {
	if st != radio.MainStation {
		return plural(tracks, "track") + " in rotation, looping; listeners' picks play first.\n"
	}
	hour := ""
	if g := radio.HourGenre(time.Now().Unix()); g != 0 {
		hour = "This hour: **" + md(catalog.GenreName(g)) + "**. "
	}
	return "Main follows the time of day: one genre an hour, calm at night and peaking in the evening. " + hour +
		"Listeners' picks play first. " + plural(tracks, "track") + " in rotation.\n"
}

func renderTrack(t catalog.Track) string {
	if !playable(t) {
		note := catalog.HiddenNote("track", t.ID)
		if note == "" {
			note = catalog.HiddenNote("artist", t.Artist)
		}
		if note == "" {
			note = "This track is no longer available."
		}
		return renderRemoved(note)
	}
	a, _ := catalog.GetArtist(t.Artist)
	id := text.Itoa(t.ID)
	var b strings.Builder
	b.WriteString(header(md(t.Title), "-"))
	b.WriteString("<gno-columns>\n" + coverSVG(t.ID, t.Artist, t.Title, 300) + "\n<gno-columns-sep />\n")
	b.WriteString("### by " + artistLink(a) + "\n\n")
	b.WriteString(md(catalog.GenreName(t.Genre)) + " · " + clock(t.Duration) + " · " + licenseLink(t.License))
	if t.CMO == "sacem-nc" {
		b.WriteString(" · declared to SACEM")
	}
	b.WriteString("  \n")
	if t.Credits != "" {
		b.WriteString("Credits: " + md(t.Credits) + "  \n")
	}
	b.WriteString("♥ " + text.Itoa(t.Likes) + " · ◈ " + text.GNOT(t.Tips) + " from " + plural(t.Supporters, "supporter"))
	if t.Album != 0 {
		if al, ok := catalog.GetAlbum(t.Album); ok && !al.Hidden {
			b.WriteString(" · from [" + md(al.Title) + "](" + page("album/"+text.Itoa(al.ID)) + ")")
		}
	}
	// One primary action line; the rest waits in the folded block below.
	b.WriteString("\n\n**[▶ Listen](" + listenURL(t.ID, t.Audio, 0) + ")** · **[♥ Like](" + catalogTx.NewLink("Like").AddArgs("trackID", id).URL() + ")** · " +
		"**[Pick it on Main](" + queueURL(0, t.ID) + ")**")
	if l := inApp("track/"+id, "Open in the app"); l != "" {
		b.WriteString(" · " + l)
	}
	b.WriteString("\n\n" + support(t, a) + promoLines(a, t.ID, t.Genre))
	b.WriteString("</gno-columns>\n\n")

	switch t.Origin {
	case catalog.OriginCurated:
		b.WriteString("> [!NOTE] Curated · " + licenseLink(t.License) + "\n> " + md(t.Attribution) + "." + sourceLink("Source", t.SourceURL) + "\n\n")
	case catalog.OriginAudius, catalog.OriginJamendo:
		b.WriteString("> [!NOTE] Read live from " + platformName(t.Origin) + ": its title, artist and cover are not stored on chain (the platform's terms), the app shows them. © the artist, " +
			licenseLink(t.License) + ".")
		if l := inApp("track/"+id, "Open in the app"); l != "" {
			b.WriteString(" " + l + ".")
		}
		b.WriteString("\n\n")
	}

	if len(t.Splits) > 0 {
		b.WriteString("## Where your tip goes\n\n| Recipient | Share |\n|---|---|\n")
		rest := int64(100)
		for _, s := range t.Splits {
			b.WriteString("| " + who(s.To) + " | " + text.Itoa64(s.Pct) + "% |\n")
			rest -= s.Pct
		}
		b.WriteString("| " + artistLink(a) + " (artist) | " + text.Itoa64(rest) + "% |\n\n")
	}
	b.WriteString("## Early listeners\n\n")
	for i, addr := range t.Early {
		b.WriteString(text.Itoa(i+1) + ". " + who(addr) + "\n")
	}
	if len(t.Early) < 10 {
		b.WriteString("\n**" + text.Itoa(10-len(t.Early)) + "** early-listener badges left: [like it now](" + catalogTx.NewLink("Like").AddArgs("trackID", id).URL() + ").\n")
	}
	g := radio.StationName(t.Genre)
	b.WriteString("\n> [!NOTE]- More actions and proof\n> [Unlike](" + catalogTx.NewLink("Unlike").AddArgs("trackID", id).URL() + ") · " +
		"Queue on [Main](" + queueURL(0, t.ID) + ") or [" + md(g) + "](" + queueURL(t.Genre, t.ID) + ") · " +
		"Book a time on [Main](" + bookURL(0, t.ID) + ") or [" + md(g) + "](" + bookURL(t.Genre, t.ID) + ") (unix time, 15 min to 24 h ahead) · " +
		"[Report](" + catalogTx.NewLink("Report").AddArgs("kind", "track", "target", id, "reason", "").URL() + ")\n>\n")
	b.WriteString("> **Fingerprints.** Audio " + sanitize.InlineCode(t.Audio))
	if t.AudioSHA != "" {
		b.WriteString(" · sha256 " + sanitize.InlineCode(t.AudioSHA))
	}
	if t.Cover != "" {
		b.WriteString("  \n> Cover " + sanitize.InlineCode(t.Cover))
		if t.CoverSHA != "" {
			b.WriteString(" · sha256 " + sanitize.InlineCode(t.CoverSHA))
		}
	}
	b.WriteString("  \n> Published " + date(t.Created) + "\n")
	return b.String()
}

// support explains how this track can be supported, by origin and claim.
func support(t catalog.Track, a catalog.Artist) string {
	if tippable(a.Owner, a.Verified) {
		to := "100% of the artist share goes to the artist"
		if n := len(t.Splits); n == 1 {
			to = "The artist share is split with 1 collaborator"
		} else if n > 1 {
			to = "The artist share is split with " + text.Itoa(n) + " collaborators"
		}
		out := "**◈ Tip:** [1 GNOT](" + tipURL(t.ID, 1) + ") · [5 GNOT](" + tipURL(t.ID, 5) + ") · [20 GNOT](" + tipURL(t.ID, 20) + ")  \n"
		if hasTreasury() {
			out += "Or [5 GNOT + 10% to keep GnoRadio on air](" + tipSupportURL(t.ID, 5, 10) + ").  \n"
		}
		return out + to + ", same transaction.\n"
	}
	return verifyNote(a) + "\n"
}

// platformName names the platform a pointer is read from.
func platformName(origin string) string {
	if origin == catalog.OriginJamendo {
		return "Jamendo"
	}
	return "Audius"
}

// verifyNote says where an artist without tips stands: verified without a
// wallet, verification in progress, or not verified yet.
func verifyNote(a catalog.Artist) string {
	if a.Verified && a.Owner == "" {
		return "Verified source · no wallet linked yet, so tips are off."
	}
	if pending, to, ready := catalog.ClaimState(a.ID); pending {
		fin := catalogTx.NewLink("FinalizeClaim").AddArgs("artistID", text.Itoa(a.ID)).URL()
		if time.Now().Unix() >= ready {
			return "Verification for " + who(to) + " is ready: [finish it](" + fin + ") (anyone can)."
		}
		return "Verification in progress for " + who(to) + ": ready " + date(ready) + ", then [finish it](" + fin + ")."
	}
	return "Tips open once the artist verifies this profile. Is this you? " + verifyLink(a.ID)
}

// promoLines shows what the artist shares with listeners who play them: the
// promo share of each tip and the sponsored-pick refund, when on.
func promoLines(a catalog.Artist, trackID, genre int) string {
	if !tippable(a.Owner, a.Verified) {
		return ""
	}
	s := ""
	if p := catalog.PromoShare(a.ID); p > 0 {
		s += "Promo share: **" + text.Itoa(p) + "%** of each tip goes to the listener who picked it on air and whoever shared the link.  \n"
	}
	if pay := catalog.PromoOffer(a.ID); pay > 0 {
		s += "Sponsored picks: the artist refunds **" + text.GNOT(pay) + "** once your pick airs"
		if trackID > 0 {
			s += ": [pick it on Main](" + sponsoredURL(0, trackID) + ") or [on " + md(radio.StationName(genre)) + "](" + sponsoredURL(genre, trackID) + ")"
		}
		s += ".\n"
	}
	if s == "" {
		return ""
	}
	return "\n" + s
}

func renderArtist(a catalog.Artist, pg int) string {
	var b strings.Builder
	title := md(a.Name)
	if a.Verified {
		title += " ✓"
	}
	b.WriteString(header(title, "-"))
	b.WriteString("<gno-columns>\n" + avatarSVG(text.Itoa(a.ID)+a.Name, 160) + "\n<gno-columns-sep />\n")
	if a.Verified {
		// A proof shows control of a site, not who the artist is: say which.
		if h := catalog.ProofHost(a.ID); h != "" {
			b.WriteString("✓ Verified via **" + md(h) + "**: the artist proved they control this site.\n\n")
		} else {
			b.WriteString("✓ Verified by the GnoRadio moderator.\n\n")
		}
	}
	if a.Bio != "" {
		b.WriteString(md(a.Bio) + "\n\n")
	}
	followers := plural(a.Followers, "follower")
	switch {
	case a.Owner != "":
		wallet := short(a.Owner)
		if roles.Canonical(a.Owner) {
			wallet = "[" + wallet + "](" + page("listener/"+a.Owner.String()) + ")"
		}
		b.WriteString("◈ **" + text.GNOT(a.Tips) + "** received · " + followers + "  \nWallet: " + wallet)
		if !tippable(a.Owner, a.Verified) {
			b.WriteString("  \n" + verifyNote(a))
		}
		b.WriteString("\n")
	case a.Kind == catalog.OriginAudius || a.Kind == catalog.OriginJamendo:
		b.WriteString("Read live from " + platformName(a.Kind) + " · " + followers + "  \n" + verifyNote(a) + "\n")
	default:
		b.WriteString("Curated CC artist" + sourceLink("source", a.Source) + " · " + followers + "  \n" + verifyNote(a) + "\n")
	}
	b.WriteString(promoLines(a, 0, 0) + "\n")
	b.WriteString("[Follow](" + catalogTx.NewLink("Follow").AddArgs("artistID", text.Itoa(a.ID)).URL() + ") · " +
		"[Unfollow](" + catalogTx.NewLink("Unfollow").AddArgs("artistID", text.Itoa(a.ID)).URL() + ")")
	if l := inApp("artist/"+text.Itoa(a.ID), "Open in the app"); l != "" {
		b.WriteString(" · " + l)
	}
	b.WriteString("\n</gno-columns>\n\n")

	// Tracks, newest first, pageSize per page; page 1 shows the first covers.
	b.WriteString("## Tracks\n\n")
	n := catalog.ArtistTrackCount(a.ID)
	hi := n - (pg-1)*pageSize
	lo := hi - pageSize
	if lo < 0 {
		lo = 0
	}
	var ids []int
	if hi > 0 {
		ids = catalog.ArtistTrackPage(a.ID, lo, hi-lo)
	}
	var covers []catalog.Track
	var rows strings.Builder
	for i := len(ids) - 1; i >= 0; i-- {
		t, ok := catalog.GetTrack(ids[i])
		if !ok || !playable(t) {
			continue
		}
		if pg == 1 && len(covers) < maxCovers {
			covers = append(covers, t)
		} else {
			rows.WriteString("- " + trackLink(t) + "\n")
		}
	}
	if len(covers) == 0 && rows.Len() == 0 {
		b.WriteString("No track yet.\n")
	}
	b.WriteString(coverGrid(covers) + "\n" + rows.String() + "\n" + pager("artist/"+text.Itoa(a.ID), pg, n) + "\n")
	if len(a.Albums) > 0 {
		b.WriteString("## Albums\n\n")
		for _, id := range a.Albums {
			if al, ok := catalog.GetAlbum(id); ok && !al.Hidden {
				b.WriteString("- [" + md(al.Title) + "](" + page("album/"+text.Itoa(al.ID)) + ") · " + text.Itoa(al.Year) + "\n")
			}
		}
		b.WriteString("\n")
	}
	var evs []tickets.Event
	for _, id := range tickets.ArtistEvents(a.ID, 10) {
		if e, ok := tickets.EventInfo(id); ok {
			evs = append(evs, e)
		}
	}
	if len(evs) > 0 {
		// At most 10: an insertion sort by start time.
		for i := 1; i < len(evs); i++ {
			for j := i; j > 0 && evs[j].Start < evs[j-1].Start; j-- {
				evs[j], evs[j-1] = evs[j-1], evs[j]
			}
		}
		b.WriteString("## Concerts\n\n")
		now := time.Now().Unix()
		for _, e := range evs {
			b.WriteString("- " + date(e.Start) + " · [" + md(e.Title) + "](" + page("event/"+text.Itoa(e.ID)) + ") · " + md(e.Venue) + eventTag(e, now) + "\n")
		}
	}
	b.WriteString("\n[Report this profile](" + catalogTx.NewLink("Report").AddArgs("kind", "artist", "target", text.Itoa(a.ID), "reason", "").URL() + ")\n")
	return b.String()
}

// eventTag marks a cancelled or past concert in a list.
func eventTag(e tickets.Event, now int64) string {
	switch {
	case e.Cancelled:
		return " · **cancelled**"
	case e.Start <= now:
		return " · past"
	}
	return ""
}

func renderAlbum(al catalog.Album) string {
	var b strings.Builder
	a, _ := catalog.GetArtist(al.Artist)
	b.WriteString(header(md(al.Title), "-"))
	b.WriteString("<gno-columns>\n" + coverSVG(al.ID*7919, al.Artist, al.Title, 260) + "\n<gno-columns-sep />\n")
	var total int64
	var tips int64
	tracks := make([]*catalog.Track, len(al.Tracks)) // read once, for the totals and the table
	for i, id := range al.Tracks {
		if t, ok := catalog.GetTrack(id); ok {
			tracks[i] = &t
			total += t.Duration
			tips += t.Tips
		}
	}
	b.WriteString("### " + artistLink(a) + "\n\n" + text.Itoa(al.Year) + " · " + plural(len(al.Tracks), "track") + " · " + clock(total) + " · ◈ " + text.GNOT(tips) + "\n</gno-columns>\n\n")
	b.WriteString("| # | Track | Time | ♥ |\n|---|---|---|---|\n")
	for i, t := range tracks {
		if t != nil && playable(*t) {
			b.WriteString("| " + text.Itoa(i+1) + " | [" + md(t.Title) + "](" + page("track/"+text.Itoa(t.ID)) + ") | " + clock(t.Duration) + " | " + text.Itoa(t.Likes) + " |\n")
		}
	}
	b.WriteString("\n")
	if l := inApp("album/"+text.Itoa(al.ID), "Play it in the app"); l != "" {
		b.WriteString(l + " · ")
	}
	b.WriteString("[Report this album](" + catalogTx.NewLink("Report").AddArgs("kind", "album", "target", text.Itoa(al.ID), "reason", "").URL() + ")\n")
	return b.String()
}

func renderPlaylist(pl catalog.Playlist, pg int) string {
	var b strings.Builder
	b.WriteString(header(md(pl.Title), "-"))
	b.WriteString("Playlist by " + who(pl.Owner) + " · " + plural(len(pl.Tracks), "track") + " · updated " + date(pl.Updated))
	if l := inApp("playlist/"+text.Itoa(pl.ID), "Play it in the app"); l != "" {
		b.WriteString(" · " + l)
	}
	b.WriteString("\n\n| # | Track | Time |\n|---|---|---|\n")
	for i := (pg - 1) * pageSize; i < len(pl.Tracks) && i < pg*pageSize; i++ {
		if t, ok := catalog.GetTrack(pl.Tracks[i]); ok && playable(t) {
			b.WriteString("| " + text.Itoa(i+1) + " | " + trackLink(t) + " | " + clock(t.Duration) + " |\n")
		}
	}
	b.WriteString("\n" + pager("playlist/"+text.Itoa(pl.ID), pg, len(pl.Tracks)))
	b.WriteString("\n[Report this playlist](" + catalogTx.NewLink("Report").AddArgs("kind", "playlist", "target", text.Itoa(pl.ID), "reason", "").URL() + ")\n")
	return b.String()
}

func renderCatalog(pg, genre int) string {
	var b strings.Builder
	route, total := "catalog", catalog.TrackCount()
	ids := catalog.TrackPage((pg-1)*pageSize, pageSize, true)
	if genre > 0 {
		route, total = "catalog?g="+text.Itoa(genre), catalog.GenreCount(genre)
		ids = catalog.GenrePage(genre, (pg-1)*pageSize, pageSize)
		b.WriteString(header("Catalog · "+md(catalog.GenreName(genre)), "catalog"))
	} else {
		b.WriteString(header("Catalog", "catalog"))
	}
	b.WriteString("Browse: [all](" + page("catalog") + ")")
	for g := 1; g <= catalog.NumGenres; g++ {
		b.WriteString(" · [" + md(catalog.GenreName(g)) + "](" + page("catalog?g="+text.Itoa(g)) + ")")
	}
	b.WriteString(" · [Artists](" + page("artists") + ") · [Albums](" + page("albums") + ") · [Playlists](" + page("playlists") + ")\n\n")
	if len(ids) == 0 {
		b.WriteString("> [!INFO] No track here yet\n> [Publish one](" + page("join") + ").\n")
		return b.String()
	}
	b.WriteString("| Track | Genre | Time | ♥ |\n|---|---|---|---|\n")
	for _, id := range ids {
		if t, ok := catalog.GetTrack(id); ok && playable(t) {
			b.WriteString("| " + trackLink(t) + " | " + md(catalog.GenreName(t.Genre)) + " | " + clock(t.Duration) + " | " + text.Itoa(t.Likes) + " |\n")
		}
	}
	b.WriteString("\n" + pager(route, pg, total))
	return b.String()
}

func renderArtists(pg int) string {
	var b strings.Builder
	b.WriteString(header("Artists", "catalog"))
	b.WriteString("| Artist | Tracks | Followers | Tips |\n|---|---|---|---|\n")
	for _, id := range catalog.ArtistPage((pg-1)*pageSize, pageSize) {
		if a, ok := catalog.GetArtist(id); ok && !a.Hidden {
			name := artistLink(a)
			if a.Owner == "" {
				name += " · " + md(a.Kind) + ", unclaimed"
			}
			b.WriteString("| " + name + " | " + text.Itoa(len(a.Tracks)) + " | " + text.Itoa(a.Followers) + " | " + text.GNOT(a.Tips) + " |\n")
		}
	}
	b.WriteString("\n" + pager("artists", pg, catalog.ArtistCount()))
	return b.String()
}

func renderAlbums(pg int) string {
	var b strings.Builder
	b.WriteString(header("Albums", "catalog"))
	for _, id := range catalog.AlbumPage((pg-1)*pageSize, pageSize) {
		if al, ok := catalog.GetAlbum(id); ok && !al.Hidden && catalog.ArtistVisible(al.Artist) {
			b.WriteString("- [" + md(al.Title) + "](" + page("album/"+text.Itoa(al.ID)) + ") · " + artistRef(al.Artist) + " · " + text.Itoa(al.Year) + "\n")
		}
	}
	b.WriteString("\n" + pager("albums", pg, catalog.AlbumCount()))
	return b.String()
}

func renderPlaylists(pg int) string {
	var b strings.Builder
	b.WriteString(header("Playlists", "catalog"))
	for _, id := range catalog.PlaylistPage((pg-1)*pageSize, pageSize) {
		if owner, title, n, hidden, ok := catalog.PlaylistBrief(id); ok && !hidden {
			b.WriteString("- [" + md(title) + "](" + page("playlist/"+text.Itoa(id)) + ") · " + plural(n, "track") + " · by " + who(owner) + "\n")
		}
	}
	b.WriteString("\n" + pager("playlists", pg, catalog.PlaylistCount()))
	return b.String()
}

// maxPastScan bounds how many concert ids the cancelled list reads.
const maxPastScan = 300

func renderConcerts(pg int) string {
	var b strings.Builder
	b.WriteString(header("Concerts", "concerts"))
	if pg == 1 {
		b.WriteString("## Upcoming\n\n")
		up := tickets.Upcoming(20)
		if len(up) == 0 {
			b.WriteString("No concert announced. [Announce yours](" + page("join") + ").\n")
		}
		for _, e := range up {
			b.WriteString("- **" + date(e.Start) + "** · [" + md(e.Title) + "](" + page("event/"+text.Itoa(e.ID)) + ") · " +
				artistRef(e.ArtistID) + " · " + md(e.Venue) + "\n")
		}
		if l := inApp("concerts", "Get tickets in the app"); l != "" {
			b.WriteString("\n" + l + "\n")
		}
	}
	now := time.Now().Unix()
	// Future concerts that were cancelled, page 1 only: the newest ids.
	// ponytail: an old id cancelled for a far date can be missed, and
	// maxPastScan cancelled announcements hide older ones; an index of
	// cancellations in tickets would list them all.
	var cancelled strings.Builder
	nCancelled := 0
	for id, scanned := tickets.EventCount(), 0; pg == 1 && id >= 1 && scanned < maxPastScan && nCancelled < 10; id, scanned = id-1, scanned+1 {
		if e, ok := tickets.EventInfo(id); ok && e.Cancelled && e.Start > now && catalog.ArtistVisible(e.ArtistID) {
			nCancelled++
			cancelled.WriteString("- ~~" + date(e.Start) + "~~ · [" + md(e.Title) + "](" + page("event/"+text.Itoa(e.ID)) + ") · " + artistRef(e.ArtistID) + "\n")
		}
	}
	// Past concerts, latest first, from the tickets' start-time index: what
	// was cancelled or hidden takes no room there.
	var past strings.Builder
	ids, total := tickets.PastEvents((pg-1)*pageSize, pageSize)
	shown, more := 0, pg*pageSize < total
	for _, id := range ids {
		if e, ok := tickets.EventInfo(id); ok && catalog.ArtistVisible(e.ArtistID) {
			past.WriteString("- " + date(e.Start) + " · [" + md(e.Title) + "](" + page("event/"+text.Itoa(e.ID)) + ") · " + artistRef(e.ArtistID) + eventTag(e, now) + "\n")
			shown++
		}
	}
	if nCancelled > 0 {
		b.WriteString("\n## Cancelled\n\n" + cancelled.String())
	}
	b.WriteString("\n## Past concerts\n\n")
	if shown == 0 {
		if total == 0 {
			b.WriteString("No past concert yet.\n")
		} else {
			b.WriteString("Nothing to show on this page.\n")
		}
	}
	b.WriteString(past.String() + "\n" + pagerMore("concerts", pg, more))
	return b.String()
}

func renderEvent(e tickets.Event) string {
	var b strings.Builder
	b.WriteString(header(md(e.Title), "-"))
	b.WriteString(tickets.EventSVG(e.ID) + "\n\n")
	a, _ := catalog.GetArtist(e.ArtistID)
	b.WriteString("**" + artistLink(a) + "** · " + md(e.Venue) + " · **" + date(e.Start) + "** · seats **" + text.Itoa(e.Sold) + " / " + text.Itoa(e.Capacity) + "**\n\n")
	if u := sanitize.URL(e.Link); u != "" && a.Verified { // an unverified profile's link may be phishing
		b.WriteString("Link: [" + md(e.Link) + "](" + u + ") (public)\n\n")
	}
	switch {
	case e.Cancelled && e.Price > 0:
		b.WriteString("> [!CAUTION] Cancelled\n> Payments went straight to the artist: contact them for a refund.\n")
	case e.Cancelled:
		b.WriteString("> [!CAUTION] Cancelled\n> This free concert will not take place.\n")
	case time.Now().Unix() >= e.Start:
		b.WriteString("> [!NOTE] Past concert\n> Tickets stay in their holders' collections.\n")
	case e.Sold >= e.Capacity:
		b.WriteString("> [!WARNING] Sold out\n")
	case e.Price > 0 && !tippable(a.Owner, a.Verified):
		b.WriteString("> [!NOTE] Tickets open once the artist verifies this profile\n> Is this you? " + verifyLink(a.ID) + "\n")
	default:
		link := ticketsTx.NewLink("BuyTicket").AddArgs("eventID", text.Itoa(e.ID))
		label, limit := "Get a free ticket", "one free ticket per wallet"
		if e.Price > 0 {
			fee := tickets.ServiceFee()
			link = link.SetSend(strconv.FormatInt(e.Price+fee, 10) + "ugnot")
			label, limit = "Buy for "+text.GNOT(e.Price+fee), "up to 4 per wallet"
			if fee > 0 {
				limit = text.GNOT(e.Price) + " to the artist + " + text.GNOT(fee) + " GnoRadio service fee · " + limit
			}
		}
		b.WriteString("**[" + label + "](" + link.URL() + ")** · " + limit + "\n\n")
		b.WriteString("Your ticket is an NFT drawn on-chain, in your name. 100% of the ticket price goes to the artist. " +
			"You can gift it; there is no resale market. At the door the artist checks it in and it becomes an \"I was there\" keepsake.\n")
	}
	b.WriteString("\n[← All concerts](" + page("concerts") + ")\n")
	return b.String()
}

func renderTicket(tk tickets.Ticket) string {
	var b strings.Builder
	e, ok := tickets.EventInfo(tk.Event)
	if !ok {
		b.WriteString(header("Ticket #"+text.Itoa(tk.Serial), "-"))
		b.WriteString(tickets.TicketSVG(tk.ID) + "\n\n")
		note := tickets.HiddenNote(tk.Event)
		if note == "" {
			note = "This concert is no longer listed"
		}
		b.WriteString("> [!NOTE] Concert removed\n> " + md(strings.TrimSuffix(removedNote(note), ".")) + ". The ticket stays in its holder's collection.\n\n")
		b.WriteString("Holder: " + who(tickets.TicketOwner(tk.ID)) + "\n")
		return b.String()
	}
	b.WriteString(header("Ticket #"+text.Itoa(tk.Serial)+" · "+md(e.Title), "-"))
	b.WriteString(tickets.TicketSVG(tk.ID) + "\n\n")
	b.WriteString("Holder: " + who(tickets.TicketOwner(tk.ID)) + " · [concert](" + page("event/"+text.Itoa(e.ID)) + ")" + ticketTag(tk, e) + "\n\n")
	if !tk.Attended && !e.Cancelled {
		b.WriteString("Holder: [gift this ticket](" + ticketsTx.NewLink("TransferTicket").AddArgs("to", "", "ticketID", text.Itoa(tk.ID)).URL() + ") · " +
			"[show at the door](" + ticketsTx.NewLink("Present").AddArgs("ticketID", text.Itoa(tk.ID), "code", "").URL() + ") with the door's code · " +
			"Artist: [check in at the door](" + ticketsTx.NewLink("CheckIn").AddArgs("ticketID", text.Itoa(tk.ID), "code", "").URL() + ")\n")
	}
	return b.String()
}

// ticketTag marks an attended ticket or a cancelled concert.
func ticketTag(tk tickets.Ticket, e tickets.Event) string {
	switch {
	case tk.Attended:
		return " · ✓ I was there"
	case e.Cancelled:
		return " · **cancelled**"
	}
	return ""
}

// renderListeners is the bare "listener" path: who picks for the stations.
func renderListeners() string {
	var b strings.Builder
	b.WriteString(header("Listeners", "-"))
	b.WriteString("Every listener has a public page: open one from the activity feed, a playlist or a station.\n\n## Top curators this week\n\n")
	top := radio.TopCurators(-1) // every station
	if len(top) == 0 {
		b.WriteString("No pick this week yet. [Pick a track](" + page("catalog") + ").\n")
	}
	for i, c := range top {
		b.WriteString(text.Itoa(i+1) + ". " + who(c.Address) + " · " + plural(c.Picks, "pick") + " · " + plural(c.Tips, "tip") + " on air · earned " + text.GNOT(c.Earned) + "\n")
	}
	b.WriteString("\n[Charts →](" + page("charts") + ")\n")
	return b.String()
}

func renderListener(addr address, pg int) string {
	var b strings.Builder
	b.WriteString(header(md(displayName(addr)), "-"))
	b.WriteString("`" + addr.String() + "`")
	if userName(addr) == "" {
		b.WriteString(" · a nickname until this wallet registers a [gno.land name](/r/sys/users)")
	}
	b.WriteString("\n\n")
	if id := catalog.ArtistOf(addr); id != 0 {
		if s := artistRef(id); s != "" {
			b.WriteString("Also the artist " + s + ".\n\n")
		}
	}
	likes, follows, tipped, lists := catalog.UserStats(addr)
	b.WriteString("♥ " + plural(likes, "like") + " · " + plural(follows, "follow") + " · ◈ " + text.GNOT(tipped) + " given · " +
		plural(tickets.Attended(addr), "concert") + " attended\n\n")
	if c := radio.CuratorOf(addr); c.Picks > 0 {
		b.WriteString("**Curator:** " + plural(c.Picks, "pick") + " · " + plural(c.Tips, "tip") + " received on air · earned " + text.GNOT(c.Earned))
		if c.Promo > 0 {
			b.WriteString(" · " + text.GNOT(c.Promo) + " refunded for sponsored picks")
		}
		b.WriteString("\n\n")
	}
	if len(lists) > 0 {
		b.WriteString("## Playlists\n\n")
		for _, id := range lists {
			if _, title, n, hidden, ok := catalog.PlaylistBrief(id); ok && !hidden {
				b.WriteString("- [" + md(title) + "](" + page("playlist/"+text.Itoa(id)) + ") · " + plural(n, "track") + "\n")
			}
		}
		b.WriteString("\n")
	}
	route := "listener/" + addr.String()
	b.WriteString("## Tickets\n\n")
	ids := tickets.TicketsOf(addr, (pg-1)*pageSize, pageSize)
	if len(ids) == 0 {
		b.WriteString("No ticket. [See concerts](" + page("concerts") + ").\n")
	}
	for _, id := range ids {
		if tk, ok := tickets.TicketInfo(id); ok {
			e, ok := tickets.EventInfo(tk.Event)
			if !ok {
				b.WriteString("- [Removed by moderation #" + text.Itoa(tk.Serial) + "](" + page("ticket/"+text.Itoa(tk.ID)) + ")\n")
				continue
			}
			b.WriteString("- [" + md(e.Title) + " #" + text.Itoa(tk.Serial) + "](" + page("ticket/"+text.Itoa(tk.ID)) + ") · " + date(e.Start) + ticketTag(tk, e) + "\n")
		}
	}
	liked := catalog.LikedPage(addr, (pg-1)*pageSize, pageSize)
	b.WriteString("\n## Likes\n\n")
	var badges strings.Builder
	shown := 0
	for _, id := range liked {
		if t, ok := catalog.GetTrack(id); ok && playable(t) {
			b.WriteString("- " + trackLink(t) + "\n")
			for i, e := range t.Early {
				if e == addr && shown < maxCovers {
					badges.WriteString("[" + badgeSVG(t.Title, i+1) + "](" + page("track/"+text.Itoa(t.ID)) + ")")
					shown++
				}
			}
		}
	}
	if len(liked) == 0 {
		b.WriteString("No like yet.\n")
	}
	b.WriteString("\n## Follows\n\n")
	followed := catalog.FollowsPage(addr, (pg-1)*pageSize, pageSize)
	for _, id := range followed {
		if s := artistRef(id); s != "" {
			b.WriteString("- " + s + "\n")
		}
	}
	if len(followed) == 0 {
		b.WriteString("Follows no artist yet.\n")
	}
	b.WriteString("\n## Early-listener badges\n\n")
	if shown == 0 {
		b.WriteString("No early-listener badge on this page: be among the first 10 to like a new track.")
	}
	b.WriteString(badges.String() + "\n\n")
	more := len(ids) == pageSize || len(liked) == pageSize || len(followed) == pageSize
	b.WriteString(pagerMore(route, pg, more))
	return b.String()
}

func renderCharts() string {
	var b strings.Builder
	b.WriteString(header("Charts", "charts"))
	b.WriteString("## Most supported artists\n\n")
	var rows []bar
	for _, r := range catalog.TopArtists() {
		if name, _, hidden, ok := catalog.ArtistBrief(atoi(r.Key)); ok && !hidden {
			rows = append(rows, bar{name, r.Value})
		}
	}
	if len(rows) == 0 {
		b.WriteString("> [!INFO] No tips yet\n> Open a track by a claimed artist and support them.\n\n")
	} else {
		b.WriteString(barsSVG(rows, text.GNOT) + "\n\n")
	}
	b.WriteString("## Most liked tracks\n\n| # | Track | ♥ | Supporters |\n|---|---|---|---|\n")
	n := 0
	for _, r := range catalog.TopLiked() {
		if t, ok := catalog.GetTrack(atoi(r.Key)); ok && playable(t) {
			n++
			b.WriteString("| " + text.Itoa(n) + " | " + trackLink(t) + " | " + text.Itoa(t.Likes) + " | " + text.Itoa(t.Supporters) + " |\n")
		}
	}
	if n == 0 {
		b.WriteString("| | No likes yet | | |\n")
	}
	b.WriteString("\n## Top supporters\n\n")
	fans := catalog.TopFans()
	if len(fans) == 0 {
		b.WriteString("> [!INFO] No supporter yet\n> Tips to artists put you on this board.\n")
	}
	for i, r := range fans {
		b.WriteString(text.Itoa(i+1) + ". " + who(address(r.Key)) + " · " + text.GNOT(r.Value) + "\n")
	}
	return b.String()
}

func renderJoin() string {
	return header("Join GnoRadio", "join") +
		"**0. Your wallet is your identity.** Install [Adena](https://adena.app). Each step below opens a transaction you sign in your wallet.\n\n" +
		"## Artists\n\n" +
		"1. [Create your artist profile](" + catalogTx.NewLink("RegisterArtist").AddArgs("name", "", "bio", "").URL() + ") (Latin letters, 2-40 characters).\n" +
		"2. Export **MP3 320 kbps** or **Opus 160 kbps** around **-14 LUFS**, upload it to IPFS (or an allowed host) and note its sha256.\n" +
		"3. [Publish a track](" + radioTx.NewLink("PublishTrack").URL() + "): genre 1-" + text.Itoa(catalog.NumGenres) + ", duration as 3:45, license (CC0, CC BY, CC BY-SA, CC BY-NC… or ALL-RIGHTS-RESERVED), " +
		"collaborators as `g1…:30` in percent, and answer `yes` to: *\"" + md(catalog.RightsTerms()) + "\"* It joins its genre station right away, in the same transaction.\n" +
		"4. [Group tracks into an album](" + catalogTx.NewLink("CreateAlbum").URL() + ") and [announce a concert](" + ticketsTx.NewLink("CreateEvent").URL() + "): " +
		"start in UTC as `2026-11-20 21:00`, price in GNOT (`0` for free, `2.5`), and the number of seats.\n" +
		"5. [Set your promo share](" + catalogTx.NewLink("SetPromoShare").AddArgs("pct", "").URL() + "): 0 to 20% of each tip (none until you set it) goes to the listener who picked your track on air and whoever shared the link.\n" +
		"6. Once verified, [fund a sponsored-pick budget](" + catalogTx.NewLink("FundPromo").SetSend("1000000ugnot").URL() + ") (1 GNOT here, five refunds at the default; 0.1 GNOT at least) and " +
		"[set the refund per pick](" + catalogTx.NewLink("SetPromoPay").AddArgs("ugnotPerPick", "200000", "perDay", "0").URL() + "): " +
		"10000-500000 ugnot (0.01-0.5 GNOT) for each pick of your tracks that airs, 1 to 100 a day (0 = the default, 10); " +
		"the default 200000 (0.2 GNOT) covers what the pick and collecting its refund cost the listener. " +
		"[Withdraw the rest](" + dataTx.NewLink("VaultWithdraw").AddArgs("acct", "catalog/").URL() + ") at any time: the budget sits in GnoRadio's data realm, " +
		"account `catalog/` and your artist id on 8 digits (artist 12: `catalog/00000012`).\n\n" +
		"> [!CAUTION] SACEM members\n> Only works declared under a non-commercial CC license: use `sacem-nc` and a CC BY-NC license.\n\n" +
		"## Your music is already here?\n\n" +
		"Imported from Audius or an archive? Open your profile in the app and press **Verify**: put the code it gives you in your Audius bio " +
		"or at `https://yourdomain/.well-known/gnoradio.txt`. A robot checks it; tips open 72 hours later.\n\n" +
		"## Listeners\n\n[Publish a public playlist](" + catalogTx.NewLink("PublishPlaylist").URL() + ") with track ids like `12,40,7`. Private playlists and saves live in the app, for free.\n\n" +
		"Genres: " + genreList() + "\n"
}

// aboutFees names the operator's income, only when there is any: the ticket
// service fee is 0 while no treasury is set.
func aboutFees() string {
	switch {
	case hasTreasury() && tickets.ServiceFee() > 0:
		return " An optional extra and a ticket service fee fund GnoRadio."
	case hasTreasury():
		return " An optional extra funds GnoRadio."
	}
	return ""
}

func renderAbout() string {
	return header("How it works", "about") +
		"<gno-columns>\n" +
		"### Library and Live\n\nPlay any album or playlist in any order, or tune into a station where everyone hears the same second. The schedule lives on-chain; there is no streaming server to switch off.\n" +
		"<gno-columns-sep />\n" +
		"### 0% taken from artists, provably\n\nTips and ticket prices reach the artist in the same transaction." + aboutFees() + " Don't trust us, read the code.\n" +
		"<gno-columns-sep />\n" +
		"### Tickets that remember\n\nEach ticket is an NFT drawn by the contract, in your name. Gift it, get it checked in at the door, keep it after the show.\n" +
		"</gno-columns>\n\n" +
		"## Who does what\n\n" +
		"- **Here (gnoweb):** catalog, profiles, support, tickets and the on-chain proof. Every page is rendered by a contract.\n" +
		"- **The GnoRadio app:** the synced player, uploads, your library. Listening never needs a transaction." + appLine() + "\n" +
		"- **Audio:** IPFS, Arweave, allowed hosts (archive.org) and Audius. Metadata, links and fingerprints live on gno.land.\n\n" +
		"## Rules\n\n- Publish only music you own or control the rights to. Curated tracks are CC0, CC BY or CC BY-SA with attribution; Audius tracks follow the Audius Open Music License.\n" +
		"- Published files stay public: moderation can hide, not erase. Reports are public on [the moderation page](" + page("moderation") + ").\n\n" +
		noticeBlock() +
		"## Verify it yourself\n\n" +
		"- Tips and splits: [social.gno](" + sourceURL(catalogPath, "social.gno") + ") · GnoRadio funding: [support.gno](" + sourceURL(catalogPath, "support.gno") + ")\n" +
		"- Stations and queue: [radio.gno](" + sourceURL(radioPath, "radio.gno") + ") · Tickets and fees: [tickets.gno](" + sourceURL(ticketsPath, "tickets.gno") + ")\n" +
		"- Moderation powers: [moderation.gno](" + sourceURL(catalogPath, "moderation.gno") + "). Current moderator: " + role(catalog.Admin(), "GnoRadio (moderator)") + ".\n"
}

func renderModeration(pg int) string {
	var b strings.Builder
	b.WriteString(header("Moderation", "-"))
	b.WriteString("Moderator: " + role(catalog.Admin(), "GnoRadio (moderator)") + ". Reports are public; decisions are visible transactions.\n\n" + noticeBlock())
	if catalog.ReportCount() == 0 {
		b.WriteString("> [!SUCCESS] No open report\n> Use the Report link on any track, artist, album or playlist.\n")
		return b.String()
	}
	b.WriteString("| # | Date | Target | Reason | By |\n|---|---|---|---|---|\n")
	for _, id := range catalog.ReportPage((pg-1)*pageSize, pageSize) {
		r, ok := catalog.GetReport(id)
		if !ok {
			continue
		}
		reason := sanitize.TableCell(r.Reason)
		if safe.Blocked(r.Reason) { // it may quote what it reports
			reason = "*(hidden: quotes a blocked word)*"
		}
		kind, target := md(r.Kind), text.Itoa(atoi(r.Target))
		b.WriteString("| " + text.Itoa(r.ID) + " | " + date(r.At) + " | [" + kind + " " + target + "](" + page(kind+"/"+target) +
			") | " + reason + " | " + who(r.By) + " |\n")
	}
	b.WriteString("\n" + plural(catalog.ReportCount(), "open report") + ". " + pager("moderation", pg, catalog.ReportCount()))
	return b.String() + pendingClaims()
}

// pendingClaims lists the verifications on their way: each stays public 72
// hours, so anyone can spot an impersonation and report it first.
func pendingClaims() string {
	cs, _ := catalog.PendingClaims(0, 100)
	if len(cs) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("\n\n## Pending verifications\n\nEach profile is verified 72 hours after its claim. Not the real artist? Report the profile.\n\n" +
		"| Artist | Wallet | Proof found on | Ready |\n|---|---|---|---|\n")
	for _, c := range cs {
		if s := artistRef(c.Artist); s != "" {
			b.WriteString("| " + s + " | " + who(c.To) + " | " + md(proofHostOf(c.Proof)) + " | " + date(c.ReadyAt) + " |\n")
		}
	}
	return b.String()
}

// proofHostOf is the host of a proof link, as catalog.ProofHost shows it:
// up to the first / ? or #, and only a plain host (Claim refuses others; a
// later release's record shows "?" rather than a wrong host).
func proofHostOf(url string) string {
	h := strings.TrimPrefix(url, "https://")
	if i := strings.IndexAny(h, "/?#"); i >= 0 {
		h = h[:i]
	}
	h = strings.ToLower(h)
	for _, c := range h {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '-') {
			return "?"
		}
	}
	return h
}

// renderRemoved is the page of hidden content: why it is gone, never what it was.
func renderRemoved(note string) string {
	return header("Removed", "-") + "> [!WARNING] Removed\n> " + md(removedNote(note)) + "\n\n[← Back to the radio](" + page("") + ")\n"
}

// ---- helpers ----

// header is the page title and the nav; cur is the nav entry to mark ("-": none).
func header(title, cur string) string { return "# " + title + "\n\n" + nav(cur) }

// nav links the main pages; the current one is bold and unlinked.
func nav(cur string) string {
	items := [7][2]string{{"", "Radio"}, {"stations", "Stations"}, {"catalog", "Catalog"}, {"concerts", "Concerts"},
		{"charts", "Charts"}, {"join", "For artists"}, {"about", "About"}}
	var b strings.Builder
	for i, it := range items {
		if i > 0 {
			b.WriteString(" · ")
		}
		if it[0] == cur {
			b.WriteString("**" + it[1] + "**")
		} else {
			b.WriteString("[" + it[1] + "](" + page(it[0]) + ")")
		}
	}
	if l := inApp("legal", "Legal"); l != "" {
		b.WriteString(" · " + l)
	}
	return b.String() + "\n\n"
}

// noticeBlock is how to send a copyright or illegal-content notice: the
// on-chain report, plus the admin's contact line when one is set.
func noticeBlock() string {
	s := "## Copyright or illegal content\n\nUse the **Report** link on the track, artist, album or playlist " +
		"(the catalog's [Report](" + catalogTx.NewLink("Report").AddArgs("kind", "", "target", "", "reason", "").URL() + ") transaction): " +
		"say which right it infringes or why it is illegal. Reports are public, with the reporter's address, on [the moderation page](" + page("moderation") + "). " +
		"The moderator hides reported content while checking and shows the reason on its page.\n"
	if c := contact(); c != "" {
		s += "\nContact: " + md(c) + "\n"
	}
	if l := inApp("legal", "Legal notice, privacy and terms"); l != "" {
		s += "\n" + l + "\n"
	}
	return s + "\n"
}

func stats() string {
	return bold(plural(catalog.ArtistCount(), "artist")) + " · " + bold(plural(catalog.TrackCount(), "track")) + " · " +
		bold(plural(catalog.AlbumCount(), "album")) + " · " + bold(plural(tickets.TicketCount(), "ticket")) + " · v" + catalog.Version() + "\n"
}

// bold makes the number of "12 tracks" bold.
func bold(s string) string {
	n, rest, _ := strings.Cut(s, " ")
	return "**" + n + "** " + rest
}

func page(p string) string {
	if p == "" {
		return base
	}
	return base + ":" + p
}

func pager(route string, pg, total int) string { return pagerMore(route, pg, pg*pageSize < total) }

// pagerMore links the previous page and, when more is true, the next one.
func pagerMore(route string, pg int, more bool) string {
	sep := "?p="
	if strings.Contains(route, "?") {
		sep = "&p="
	}
	s := ""
	if pg > 1 {
		s += "[← Previous](" + page(route+sep+text.Itoa(pg-1)) + ") "
	}
	if more {
		s += "[Next →](" + page(route+sep+text.Itoa(pg+1)) + ")"
	}
	return s + "\n"
}

func playable(t catalog.Track) bool { return !t.Hidden && catalog.ArtistVisible(t.Artist) }

func trackLink(t catalog.Track) string {
	return "[" + md(t.Title) + "](" + page("track/"+text.Itoa(t.ID)) + ") · " + artistRef(t.Artist)
}

// artistRef links an artist by id (✓ when verified), or prints nothing for
// a hidden or unknown one. It reads the artist's head only.
func artistRef(id int) string {
	name, verified, hidden, ok := catalog.ArtistBrief(id)
	if !ok || hidden {
		return ""
	}
	s := "[" + md(name) + "](" + page("artist/"+text.Itoa(id)) + ")"
	if verified {
		s += check(id)
	}
	return s
}

// check is the ✓ of a verified artist, with the host its proof was found
// on: " ✓ via example.org", or " ✓" when the moderator verified it.
func check(id int) string {
	if h := catalog.ProofHost(id); h != "" {
		return " ✓ via " + md(h)
	}
	return " ✓"
}

// trackRef links a track by id ("a track" when hidden or unknown).
func trackRef(id int) string {
	if t, ok := catalog.GetTrack(id); ok && playable(t) {
		return "[" + md(t.Title) + "](" + page("track/"+text.Itoa(t.ID)) + ")"
	}
	return "a track"
}

func stationLink(st int) string {
	return "[" + md(radio.StationName(st)) + "](" + page("station/"+text.Itoa(st)) + ")"
}

// tippable mirrors catalog: tips and paid tickets need a claimed, verified
// artist.
func tippable(owner address, verified bool) bool { return owner != "" && verified }

// verifyLink sends an artist to the app's verification steps (catalog/verify.gno).
func verifyLink(artistID int) string {
	if l := inApp("artist/"+text.Itoa(artistID), "Verify it in the app"); l != "" {
		return l
	}
	return "verify it in the GnoRadio app"
}

// genreBrowse points an empty or idle station to tracks it could play.
func genreBrowse(st int) string {
	switch st {
	case radio.MainStation:
		return "[Browse the catalog](" + page("catalog") + "), open a track and choose **Pick it on Main**."
	case radio.NewStation:
		return "The newest tracks join it as they sync. [Browse the catalog](" + page("catalog") + ")."
	case radio.ChoiceStation:
		return "Every track a listener queues joins it. [Browse the catalog](" + page("catalog") + ") and pick one."
	}
	return "[Browse " + md(catalog.GenreName(st)) + " tracks](" + page("catalog?g="+text.Itoa(st)) + "), open one and choose **Queue**."
}

// stationOrder lists Main, then the community stations, then the genres.
func stationOrder() []int {
	out := []int{radio.MainStation, radio.NewStation, radio.ChoiceStation}
	for g := 1; g <= catalog.NumGenres; g++ {
		out = append(out, g)
	}
	return out
}

// sourceURL links a contract file on gnoweb.
func sourceURL(pkgPath, file string) string {
	return strings.TrimPrefix(pkgPath, runtime.ChainDomain()) + "$source&file=" + file
}

// sourceLink is " [label](url)." or "" when there is no URL.
func sourceLink(label, url string) string {
	if url = sanitize.URL(url); url == "" {
		return ""
	}
	return " [" + label + "](" + url + ")."
}

func appLine() string {
	if l := inApp("", "Open it"); l != "" {
		return " " + l + "."
	}
	return ""
}

func artistLink(a catalog.Artist) string {
	s := "[" + md(a.Name) + "](" + page("artist/"+text.Itoa(a.ID)) + ")"
	if a.Verified {
		s += check(a.ID)
	}
	return s
}

// who links an address: its artist profile, else its listener page under
// its gno.land name, or its nickname and short address (a nickname alone is
// easy to grind).
func who(addr address) string {
	if !roles.Canonical(addr) { // a later release may store anything
		return md(displayName(addr))
	}
	if id := catalog.ArtistOf(addr); id != 0 {
		if s := artistRef(id); s != "" {
			return s
		}
	}
	label := "@" + userName(addr)
	if label == "@" {
		label = nickname(addr) + " (" + short(addr) + ")"
	}
	return "[" + md(label) + "](" + page("listener/"+addr.String()) + ")"
}

// listenURL is where a track's audio plays, from offset seconds when the
// host takes a #t= fragment; an Audius track without its page stays here.
// Values from the catalog are checked again here (sanitize.URL): this page
// keeps rendering records later releases write.
func listenURL(id int, audio string, offset int64) string {
	if u := sanitize.URL(rawListenURL(id, audio, offset)); u != "" {
		return u
	}
	return page("track/" + text.Itoa(id))
}

func rawListenURL(id int, audio string, offset int64) string {
	frag := ""
	if offset > 0 && !strings.Contains(audio, "#") {
		frag = "#t=" + text.Itoa64(offset)
	}
	switch {
	case strings.HasPrefix(audio, "ipfs://"):
		return "https://ipfs.io/ipfs/" + strings.TrimPrefix(audio, "ipfs://") + frag
	case strings.HasPrefix(audio, "ar://"):
		return "https://arweave.net/" + strings.TrimPrefix(audio, "ar://") + frag
	case strings.HasPrefix(audio, "audius:"), strings.HasPrefix(audio, "jamendo:"):
		return page("track/" + text.Itoa(id)) // a pointer plays in the app
	}
	return audio + frag
}

// licenseLink links a license id to its deed. Creative Commons ids read
// CC-<terms>-<version>[-<port>], e.g. CC-BY-SA-3.0-DE →
// creativecommons.org/licenses/by-sa/3.0/de/.
func licenseLink(l string) string {
	switch {
	case l == "CC0-1.0":
		return "[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)"
	case l == catalog.AudiusLicense:
		return "[Audius Open Music License](https://openaudiofoundation.org/open-music-license.pdf)"
	case strings.HasPrefix(l, "CC-"):
		var terms []string
		ver, port := "", ""
		for _, part := range strings.Split(strings.TrimPrefix(l, "CC-"), "-") {
			switch {
			case ver == "" && strings.Contains(part, "."):
				ver = part
			case ver == "":
				terms = append(terms, part)
			case port == "":
				port = part
			default:
				return md(l)
			}
		}
		// only a-z, 0-9 and "." reach the URL: a later release may store other ids
		if ver == "" || len(terms) == 0 || !plain(strings.Join(terms, "")+ver+port) {
			return md(l)
		}
		url := "https://creativecommons.org/licenses/" + strings.ToLower(strings.Join(terms, "-")) + "/" + ver + "/"
		label := "CC " + strings.Join(terms, "-") + " " + ver
		if port != "" {
			url += strings.ToLower(port) + "/"
			label += " " + port
		}
		return "[" + md(label) + "](" + url + ")"
	}
	return "All rights reserved"
}

// plain reports whether s holds only ASCII letters, digits and dots.
func plain(s string) bool {
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.') {
			return false
		}
	}
	return true
}

func queueURL(st, id int) string {
	return radioTx.NewLink("Queue").AddArgs("stationID", text.Itoa(st), "trackID", text.Itoa(id)).URL()
}

// bookURL opens QueueAt with the time left for the listener to fill in.
func bookURL(st, id int) string {
	return radioTx.NewLink("QueueAt").AddArgs("stationID", text.Itoa(st), "trackID", text.Itoa(id), "at", "").URL()
}

func sponsoredURL(st, id int) string {
	return radioTx.NewLink("QueueSponsored").AddArgs("stationID", text.Itoa(st), "trackID", text.Itoa(id)).URL()
}

func tipOnAirURL(st, id int, gnots int64) string {
	return radioTx.NewLink("TipOnAir").AddArgs("stationID", text.Itoa(st), "trackID", text.Itoa(id), "supportPct", "0", "ref", "").
		SetSend(strconv.FormatInt(gnots*ugnot, 10) + "ugnot").URL()
}

func supportURL(gnots int64) string {
	return catalogTx.NewLink("SupportGnoRadio").SetSend(strconv.FormatInt(gnots*ugnot, 10) + "ugnot").URL()
}

// tipSupportURL tips gnots to the artist side plus pct% on top for GnoRadio.
func tipSupportURL(id int, gnots, pct int64) string {
	total := gnots * ugnot * (100 + pct) / 100
	return catalogTx.NewLink("TipWithSupport").AddArgs("trackID", text.Itoa(id), "supportPct", text.Itoa64(pct)).SetSend(strconv.FormatInt(total, 10) + "ugnot").URL()
}

func tipURL(id int, gnots int64) string {
	return catalogTx.NewLink("Tip").AddArgs("trackID", text.Itoa(id)).SetSend(strconv.FormatInt(gnots*ugnot, 10) + "ugnot").URL()
}

func genreList() string {
	var parts []string
	for g := 1; g <= catalog.NumGenres; g++ {
		parts = append(parts, text.Itoa(g)+" "+md(catalog.GenreName(g)))
	}
	return strings.Join(parts, " · ")
}

func md(s string) string { return sanitize.InlineText(s) }

func atoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func short(a address) string {
	s := []rune(a.String())
	if len(s) < 12 {
		return md(string(s))
	}
	return md(string(s[:7]) + "…" + string(s[len(s)-4:]))
}

func pad2(n int) string {
	if n < 10 {
		return "0" + text.Itoa(n)
	}
	return text.Itoa(n)
}

func clock(sec int64) string { return text.Itoa64(sec/60) + ":" + pad2(int(sec%60)) }

func date(unix int64) string { return time.Unix(unix, 0).UTC().Format("Jan 2, 2006 15:04") + " UTC" }
func hour(unix int64) string { return time.Unix(unix, 0).UTC().Format("15:04") }

// day is "tomorrow " when unix falls on the next UTC day (a booked pick), else "".
func day(unix int64) string {
	if unix/86400 > time.Now().Unix()/86400 {
		return "tomorrow "
	}
	return ""
}
