package golf

import (
	"encoding/hex"
	"math"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nym-alexiscolin000/gnogolf/course"
	"gno.land/p/nym-alexiscolin000/gnogolf/physics"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nym-alexiscolin000/gnogolf/store"
)

// wearRunes draw a cell's wear: none, then up to wearLight, wearWorn and
// wearGroove balls come to rest there, and past.
const (
	wearRunes  = " :;x%" // pristine grass blank: a shot's dots stand out on it
	wearLight  = 2
	wearWorn   = 6
	wearGroove = 14
)

// maxTunnels is how many tunnels the board numbers, 1 to 9.
const maxTunnels = 9

const (
	markWall = '#'
	markPost = '0'
	markCup  = 'U' // not O: in gnoweb's font O and the post's 0 look alike
	markTee  = '*'
)

// Render is the game as text: gnoweb draws the board and submits the shot.
//
// Paths: "" the hub; "<world>" a cup's holes; "<address>" the holes an
// address published; "<hole>" a hole's page, "<hole>/<address>" the same
// with that player's ball, "<hole>/data" a version's provenance and data.
// <hole> is a version's id or an alias. A query string ("?…") is ignored.
func Render(path string) string {
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}
	if path == "" {
		return renderHub()
	}
	if e := lookup(path); e != nil {
		return renderHole(e, e.hole(), "")
	}
	// the segments of a hole's path, which gnoweb links one by one
	if course.IsWorld(path) {
		return renderCup(path)
	}
	if address(path).IsValid() {
		return renderAuthor(address(path))
	}
	// the id has slashes of its own, so what trails it is looked at last
	if i := strings.LastIndex(path, "/"); i >= 0 {
		head, tail := path[:i], path[i+1:]
		if e := lookup(head); e != nil {
			if address(tail).IsValid() {
				return renderHole(e, e.hole(), address(tail))
			}
			if tail == "data" {
				return renderData(e)
			}
		}
	}
	return noSuch(path)
}

// noSuch is the page for a path that is no hole, cup or address.
func noSuch(path string) string {
	what := "That page"
	if c := cleanText(path, maxName); c != "" {
		what = "`" + c + "`"
	}
	return "# No such hole\n\n> [!WARNING]\n> " + what + " is not a hole here. " + md("See every hole", hub) + ".\n"
}

// lookup is readHole that answers nil for no hole.
func lookup(id string) *entry {
	if e := find(id); e != nil {
		return e
	}
	return find(current(id))
}

// playLink is the 3D client's link to this hole: a current course hole by cup
// and order, any other by its id, which no newer version can take.
func playLink(e *entry) string {
	if !e.official || e.next != "" {
		return playURL + "?hole=" + e.id
	}
	return playURL + "?cup=" + e.world + "&hole=" + strconv.Itoa(int(e.order))
}

// cupName is how a world is called on the page.
func cupName(w string) string {
	if r := worldRank(w); r < len(worlds) {
		return worlds[r].name
	}
	if w == "" {
		return "Holes"
	}
	return strings.ToUpper(w[:1]) + w[1:]
}

// who is a player as a link to their gno.land profile.
func who(addr string) string { return md(short(addr), "/u/"+addr) }

func renderHub() string {
	var sb strings.Builder
	sb.WriteString("# Gnogolf — mini-golf on-chain\n\n" + moved() +
		"The course is data its owner published, anyone can add holes of their own, and the chain computes every shot: nobody can fake a score.\n\n" +
		"> [!TIP] How to play\n" +
		"> **In 3D:** " + md("open the game", playURL) + ". Aim with a free preview, then record your round in a transaction (a long one in a few).\n>\n" +
		"> **Here, one shot at a time:** open a hole, fill its Launch form (an angle and a power) and sign it with your gno.land wallet (" + md("Adena", "https://adena.app") + "), then add `/<your address>` to the hole's URL to see your ball.\n>\n" +
		"> Only players with a gno.land name are ranked.\n\n")
	// what to race first: a few records worth beating, not the podium
	beat := ""
	for m := 0; m < modes; m++ {
		if rows := featuredRows(m); rows != "" {
			beat += "**" + modeTitles[m] + "**\n\n" + rows + "\n"
		}
	}
	if beat != "" {
		sb.WriteString("## Records to beat today\n\nA few players worth racing today, each for a reason (never the ranking's top three; drawn again each day). Race their ghosts in the game: their best rounds, replayed stroke for stroke.\n\n" + beat)
	}
	var archived, others []*entry
	type cup struct {
		world      string
		holes, par int
		top        *entry
	}
	var cups []*cup
	for _, e := range listed() {
		switch {
		case e.official && e.next == "":
			// one column per cup: nothing here calls a hole
			if len(cups) == 0 || cups[len(cups)-1].world != e.world {
				cups = append(cups, &cup{world: e.world})
			}
			c := cups[len(cups)-1]
			c.holes++
			c.par += e.par
			if e.plays > 0 && (c.top == nil || e.plays > c.top.plays) {
				c.top = e
			}
		case e.official:
			archived = append(archived, e)
		default:
			others = append(others, e)
		}
	}
	if len(cups) == 0 {
		sb.WriteString("_No course hole yet._\n\n")
	} else {
		// a column a cup, so they all fit one row (gnoweb's columns wrap past four)
		head, rule, sizes, tops := "| ", "|---", "| holes · par", "| most played"
		for _, c := range cups {
			top := "—"
			if c.top != nil {
				top = c.top.name
			}
			head += " | " + md(cupName(c.world), hub+":"+c.world)
			rule += "|---"
			sizes += " | " + strconv.Itoa(c.holes) + " · " + strconv.Itoa(c.par)
			tops += " | " + top
		}
		sb.WriteString(head + " |\n" + rule + "|\n" + sizes + " |\n" + tops + " |\n\n")
	}

	sb.WriteString("## Community holes\n\nAnyone can publish a hole of their own with PublishMine while the owner keeps publishing open. These are not part of the course: they have no cup and do not count in its ranking.\n\n")
	switch {
	case len(others) > 0:
	case publishing:
		sb.WriteString("_None yet. Publish yours with " + md("PublishMine", hub+"$help&func=PublishMine") + "._\n")
	default:
		sb.WriteString("_None yet: publishing opens with the game's hole builder._\n")
	}
	names := map[string]string{} // the record holders' names, read once each (bestCell)
	if len(others) > 0 {
		sb.WriteString("| hole | by | par | best | shots played |\n|---|---|---|---|---|\n")
		for _, e := range others {
			sb.WriteString("| " + md(e.name, hub+":"+e.slot) + " | " + md(short(e.by.String()), hub+":"+e.by.String()) + " | " + strconv.Itoa(e.par) + " | " + bestCell(e, names) + " | " +
				strconv.Itoa(e.plays) + " |\n")
		}
	}
	if len(archived) > 0 {
		sb.WriteString("\n## Archived course holes\n\nA newer version took each one's place in its cup. They can still be played, and keep their records, but no longer count in the course-wide ranking. Every version of a slot is on its data page.\n\n" +
			"| hole | version | par | best | shots played | now |\n|---|---|---|---|---|---|\n")
		for _, e := range archived {
			sb.WriteString("| " + md(e.name, hub+":"+e.id) + " | " + e.id + " | " + strconv.Itoa(e.par) + " | " + bestCell(e, names) + " | " +
				strconv.Itoa(e.plays) + " | " + md(e.next, hub+":"+e.next) + " |\n")
		}
	}
	sb.WriteString("\n")
	sb.WriteString("## The boards\n\nEach named player's best finish on each current hole of the course, added up: most holes first, then the best score against par (each hole's strokes less its par, added up: a hole at par counts the same whatever its par). " +
		"Assisted rounds (played with the 3D game's aim line) and pro rounds (without it, on the player's word; every round played on this page is pro) are ranked apart.\n\n")
	for m := 0; m < modes; m++ {
		sb.WriteString("### " + modeTitles[m] + "\n\n")
		rows, i := "", 0
		eachRanked(m, func(r *row, name string) {
			i++
			rows += "| " + strconv.Itoa(i) + " | " + md("@"+name, "/u/"+name) + " | " + strconv.Itoa(r.holes) + " | " + vsPar(r.strokes-r.par) + " |\n"
		})
		if rows == "" {
			sb.WriteString("_Nobody has finished a hole of the course yet._\n\n")
			continue
		}
		sb.WriteString("| rank | player | holes | vs par |\n|---|---|---|---|\n" + rows + "\n")
	}

	sb.WriteString(fairPlay())
	sb.WriteString(noAdmin())
	return sb.String()
}

// fairPlay says what keeps a score honest, and where the rules stand.
func fairPlay() string {
	return "## Fair play\n\n" +
		"- **The chain plays every shot.** A round is its shots (an angle, a power, the moment of the release), replayed here: nobody can send a score.\n" +
		"- **Shots go in the game's steps of 0.01**, angle and power: a finer one (a program's precision) is refused.\n" +
		"- **A record sent again is not ranked.** A round that sends one of the hole's top records again, shot for shot within a hair, is kept (the player's round and ghost) but ranks nowhere.\n" +
		"- **The site's boards hide suspected bots**, and say why; the chain and this page keep every record.\n" +
		"- **The rules and the data are apart:** the records are kept in " + md("Gnogolf's data", strings.TrimPrefix(dataRealm, "gno.land")) + ", which takes writes from these rules alone. New rules take over three days after their code is on chain, so anyone can read them first; nothing is reset.\n\n"
}

// moved is the banner every page shows once these rules no longer save (the
// data's writer is another, or saves are paused) or the course has moved.
func moved() string {
	switch w := store.Writer(); {
	case w == "":
		return "> [!WARNING] Saves are paused\n> " + md("Gnogolf's data", strings.TrimPrefix(dataRealm, "gno.land")) + " takes no save until these rules are resumed or new ones named: rounds here are refused, every record can still be read.\n\n"
	case w != self:
		return "> [!NOTE] New rules play this course\n> " + md(w, strings.TrimPrefix(w, "gno.land")) + " keeps its records now: play there; a round sent here is refused.\n\n"
	case successor != "":
		return "> [!NOTE] This course has moved\n> Its successor is " + md(successor, strings.TrimPrefix(successor, "gno.land")) +
			". Everything here still plays and keeps its records.\n\n"
	}
	return ""
}

// renderCup is a cup's page: its current holes, in order.
func renderCup(world string) string {
	var sb strings.Builder
	sb.WriteString("# " + cupName(world) + "\n\n" + moved())
	k := slotKey(world, 0)
	k = k[:len(k)-3] // the world's slots are the keys "<rank><world>/…"
	n, names := 0, map[string]string{}
	slots.Iterate(k, k[:len(k)-1]+"0", func(_, v string) bool {
		e := find(v)
		if n == 0 {
			sb.WriteString("| # | hole | par | best | shots played |\n|---|---|---|---|---|\n")
		}
		n++
		sb.WriteString("| " + strconv.Itoa(int(e.order)) + " | " + md(e.name, hub+":"+e.slot) + " | " + strconv.Itoa(e.par) + " | " +
			bestCell(e, names) + " | " + strconv.Itoa(e.plays) + " |\n")
		return n >= maxListed
	})
	if n == 0 {
		return noSuch(world)
	}
	return sb.String() + "\n" + md("Every cup", hub) + "\n"
}

// renderAuthor is the holes an address published, as their current versions.
func renderAuthor(a address) string {
	var sb strings.Builder
	sb.WriteString("# Community holes by " + who(a.String()) + "\n\n" + moved())
	n, names := 0, map[string]string{}
	aliases.Iterate(a.String()+"/", a.String()+"0", func(k, v string) bool {
		if hidden.Has(k) {
			return false // off the lists, as Hide says: this page is one
		}
		e := find(v)
		if n == 0 {
			sb.WriteString("| hole | versions | par | best | shots played | data |\n|---|---|---|---|---|---|\n")
		}
		n++
		sb.WriteString("| " + md(e.name, hub+":"+e.slot) + " | " + strconv.Itoa(e.version) + " | " + strconv.Itoa(e.par) + " | " +
			bestCell(e, names) + " | " + strconv.Itoa(e.plays) + " | " + source(e) + " |\n")
		return n >= pageMax
	})
	if n == 0 {
		sb.WriteString("_This address has published no community hole._\n")
	}
	return sb.String() + "\n" + md("Every hole", hub) + "\n"
}

// bestCell is a hole's records, assisted then pro, for a table cell. names
// caches holders: r/sys/users is read once a player, not once a record.
func bestCell(e *entry, names map[string]string) string {
	best := ""
	for m := 0; m < modes; m++ {
		if r := e.rec(m); r.best > 0 {
			if best != "" {
				best += " · "
			}
			by := r.by.String()
			name, ok := names[by]
			if !ok {
				name = byName(by)
				names[by] = name
			}
			best += ufmt.Sprintf("%s %d, %s", modeNames[m], r.best, name)
		}
	}
	if best == "" {
		return "—"
	}
	return best
}

// weatherNote is the hole's weather now (f, the forecast of this period) and
// how long it lasts, on a hole's own page.
func weatherNote(f course.Forecast) string {
	left := PeriodSeconds - time.Now().Unix()%PeriodSeconds
	what := "Clear"
	switch f.Kind {
	case course.Wind:
		a, _ := aim(physics.Vec2{}, f.Wind)
		what = ufmt.Sprintf("Wind toward **%.0f°**: it pushes every roll that way", a)
	case course.Rain:
		what = "Rain: the green runs fast, and puddles slow the ball"
	case course.Fog:
		what = "Fog: it hides nothing here, and does not touch the ball"
	case course.Storm:
		what = "Storm: rain, puddles and wind"
	case course.Snow:
		what = "Snow: the green runs slow"
	}
	// ufmt has no width: the seconds padded by hand
	return ufmt.Sprintf("> [!NOTE] Weather now\n> %s — for %d min %s s more. A round keeps the weather it started in, and can be played on until the next weather is over: after that it must be Reset.\n\n",
		what, left/60, pad(int(left%60), 2))
}

// noAdmin states who can change what, the owner's own powers included.
func noAdmin() string {
	holder := who(owner.String())
	if owner == "" {
		holder = "nobody: the role was given up, and the course is frozen for good"
	}
	return "\n> [!INFO]- Who can change what\n" +
		"> Anyone can play (Launch, PlayRound, PlayRoundAt, PlayRoundPro), Reset their own round, " +
		"publish holes of their own (PublishMine) while publishing is open, and settle the ranking sooner (Drain). These rules never edit or delete a round, a record, a best, a standing or a published version, " +
		"and nobody can change this realm's code. Its rules can be replaced, its records kept: the owner of " + md("Gnogolf's data", strings.TrimPrefix(dataRealm, "gno.land")) + " may propose new rules, which take over three days after their code is on chain (anyone can read it first: what they do to the records is in it), and may stop every save at once for a bug (the reads go on) and start these same rules again; that page says which rules are in force. Every hole is data, played by golf's own physics: no hole runs code of its own. Check it yourself: " + md("the source", hub+"$source") + ".\n>\n" +
		"> One party holds a real power: the course's owner, now " + holder + ". The owner publishes the course holes and their new versions (Publish). " +
		"A new version takes its slot: the old one is archived, still playable, its records kept, but its bests leave the course-wide ranking, which the new version starts afresh. " +
		"So the owner shapes the course, and through it the ranking, and a stolen owner key could archive every slot, for good. " +
		"A version identical to the current one is refused, but a replacement can still be unplayable: a hole can be replaced, never taken down. " +
		"When a version is published picks its id, and its id seeds its weather. " +
		"The owner also sets where the pages link the 3D game (SetPlayURL), and can name, once and for good, a successor this course has moved to (SetSuccessor): a banner, which blocks nothing. " +
		"Whoever holds `" + strings.TrimPrefix(officialPrefix, "gno.land/") + "` can deploy lookalike realms under it. " +
		"The owner can take a community hole off the lists (Hide: a scam or abuse in its name or note), and put it back; it stays playable, its page and data kept. " +
		"The owner opens community publishing and can close it again (SetPublishing): closed, nobody adds a hole or a version, and every hole published plays on. " +
		"The owner cannot edit or remove a version, change a community hole, the weather, the physics or this code, " +
		"and can only hand the role on (Transfer, then Accept) or give it up for good (Renounce).\n"
}

// source links a hole's data page: read it before trusting it with a round.
func source(e *entry) string { return md("data", hub+":"+e.id+"/data") }

func md(label, href string) string { return "[" + label + "](" + href + ")" }

// vsPar is a score against par: "even", "+3", "-2" (ufmt has no %+d).
func vsPar(d int) string {
	switch {
	case d > 0:
		return "+" + strconv.Itoa(d)
	case d < 0:
		return strconv.Itoa(d)
	}
	return "even"
}

// flatRolls is how far a shot rolls on flat grass (a tee shot's Kick, the
// usual friction).
const flatRolls = "On flat grass a power of 10 rolls about 40, a 5 about 15."

func renderHole(e *entry, h *course.Simple, focus address) string {
	f := h.Field()
	var mine *round // the focused player's round, looked up once
	if v, ok := e.roundTree().Get(focus.String()); ok {
		mine = decodeRound(v)
	}
	stroke := 0
	if mine != nil {
		stroke = mine.strokes
	}
	// a timed hole is drawn as it stands for the focused player's next stroke
	ws, ps := h.Extras(stroke)
	f = course.WithZones(course.WithExtras(f, ws, ps), h.ExtraZones(stroke))
	// a community hole's world is its author's word: only the course has cups
	where := md(cupName(e.world), hub+":"+e.world)
	if !e.official {
		where = "Community hole by " + md(short(e.by.String()), hub+":"+e.by.String())
	}
	s := ufmt.Sprintf("# %s\n\n**Par %d** · %s · %s\n\n", e.name, e.par, where, md("Play in 3D", playLink(e))) + moved()
	if e.next != "" {
		next := e.next
		if n := find(e.next); n != nil {
			next = n.name
		}
		s += "> [!NOTE]\n> Archived: " + md(next, hub+":"+e.next) + " (" + e.next + ") took its place. It can still be played, and your best here still shows on this page"
		if e.official {
			s += ", but it no longer counts in the course-wide ranking"
		}
		s += ".\n\n"
	}
	if focus != "" {
		s += roundSummary(e, focus, mine)
	}
	// the page's forecast, drawn once: its note, and the last shot of a round
	// played in it
	now := weatherOf(e, h, Period())
	s += weatherNote(now)
	if h.Varies() {
		if focus == "" {
			s += "_This hole changes with every stroke. It is drawn for a first shot; add `/<your address>` to the URL to see it for your next one._\n\n"
		} else {
			s += ufmt.Sprintf("_This hole changes with every stroke. Drawn for %s's stroke %d._\n\n", short(focus.String()), stroke+1)
		}
	}
	if boardWork(f, h) > maxBoardWork {
		s += "_This hole is too detailed to draw here: " + md("play it in 3D", playLink(e)) + "._\n\n"
	} else {
		b := board(e, h, f, mine, now)
		leg, walls := legend(f)
		s += "```\n" + b + "```\n\n"
		s += key(b, walls) + leg + "\n\n"
	}

	s += "## Play\n\n"
	// the one number a text player cannot read off the board: where the cup is
	from, who := h.Start(), "the tee"
	if mine != nil {
		from, who = mine.ball(), "the ball"
	}
	a, d := aim(from, h.Cup())
	s += ufmt.Sprintf("From %s the cup is **%.0f°** away, **%.1f** units in a straight line (0° = right, 90° = down). %s\n\n", who, a, d, flatRolls)
	s += "_Rounds played here have no aim preview, so they go on the **Pro** board. A shot needs a gno.land wallet (Adena); the 3D game previews shots for free._\n\n"
	s += "<gno-form exec=\"Launch\">\n"
	s += ufmt.Sprintf("<gno-input name=\"hole\" value=\"%s\" readonly=\"true\" description=\"this hole\" required=\"true\" />\n", e.id)
	s += "<gno-input name=\"angle\" description=\"angle in degrees: 0 = right, 90 = down\" placeholder=\"e.g. 12.5\" required=\"true\" />\n"
	s += "<gno-input name=\"power\" description=\"power: above 0, up to 10\" placeholder=\"e.g. 6\" required=\"true\" />\n"
	s += "</gno-form>\n\n"
	s += ufmt.Sprintf("_After your shot, see your ball at `%s:%s/<your address>`._\n\n", hub, e.id)
	s += "A round under way you would rather start afresh? Put your ball back on the tee (a holed round needs nothing: the next shot starts a new one):\n\n"
	s += "<gno-form exec=\"Reset\">\n"
	s += ufmt.Sprintf("<gno-input name=\"hole\" value=\"%s\" readonly=\"true\" description=\"this hole\" required=\"true\" />\n", e.id)
	s += "</gno-form>\n\n"
	if e.official && e.next == "" {
		s += "Took a gno.land name after saving rounds? " + md("Claim", hub+"$help&func=Claim") + " puts them on the boards now.\n\n"
	}

	s += ufmt.Sprintf("## Best rounds\n\n%d rounds under way here; finished: %d assisted, %d pro.", e.roundTree().Size(), e.bests(assisted).Size(), e.bests(pro).Size())
	if e.board(assisted).Size()+e.board(pro).Size() == 0 {
		s += " No named player has finished it yet.\n\n"
	} else {
		s += " The named players' bests: each keeps its round, which the 3D game replays as a ghost to race.\n\n"
	}
	for m := 0; m < modes; m++ {
		rows := ""
		n, walked := 0, 0
		e.board(m).Iterate("", "", func(k, v string) bool {
			walked++
			p := v
			if name := nameOf(p); name != "" { // a name deleted since is skipped
				n++
				rows += ufmt.Sprintf("| %d | [@%s](%s:%s/%s) | %d | %s |\n", n, name, hub, e.id, p, boardStrokes(k), race(e, p, "race"))
			}
			return n >= topSize || walked >= maxWalked
		})
		if rows != "" {
			s += "### " + modeTitles[m] + "\n\n| # | player | score | ghost |\n|---|---|---|---|\n" + rows + "\n"
		}
	}
	return s + "\n_This hole is " + source(e) + " — read it before you trust it with a round._\n"
}

// roundSummary is how a player stands on the hole: their round under way, if
// any, and their best in each mode, with where it puts them on the hole's
// board, or why nowhere. A holed round is not kept: its best is.
func roundSummary(e *entry, p address, r *round) string {
	who := short(p.String())
	name := nameOf(p.String())
	if name != "" {
		who = "@" + name
	}
	s := ""
	if r != nil {
		over := ""
		if r.period < Period()-1 {
			over = " Its weather is over: Reset (below) before the next shot."
		}
		s = ufmt.Sprintf("> %s's round: %s so far, not holed yet.%s\n>\n> %s\n>\n", who, count(r.strokes, "stroke"), over, shotsOf(r.shots))
	}
	for m := 0; m < modes; m++ {
		v := bestOfPlayer(e, m, p.String())
		if v == "" {
			continue
		}
		best := bestStrokes(v)
		s += ufmt.Sprintf("> **%s's best here: %d** (par %d, %s), %s. ", who, best, e.par, vsPar(best-e.par), modeNames[m])
		b := e.board(m)
		switch k := boardKey(v, p.String()); {
		case b.Has(k):
			s += ufmt.Sprintf("**#%d of %d** on the %s board. %s.\n>\n", b.index(k)+1, b.Size(), modeNames[m], race(e, p.String(), "Race this ghost in 3D"))
		case e.copies(m).Has(p.String()):
			s += "Not ranked: it is a record of the board sent again (Fair play, on the course's page).\n>\n"
		case name == "":
			s += "Not on the board: only players with a gno.land name are ranked.\n>\n"
		case e.official && e.next == "":
			s += "Not on the board yet: the name came after this round. Claim (below, or the game's \"Rank them\") ranks it now.\n>\n"
		default: // Claim seats the course's current holes only
			s += "Not on the board yet: the name came after this round. Finish it again: a named player's every finish puts their best on the board.\n>\n"
		}
		_, _, shots := bestFields(v)
		s += "> " + shotsOf(shots) + "\n>\n"
	}
	if s == "" {
		return "> [!NOTE]\n> " + who + " has no round on this hole yet.\n\n"
	}
	return "> [!NOTE]\n" + strings.TrimSuffix(s, ">\n") + "\n"
}

// shotsOf is a round's shots for a page: golf's own "%.4f,%.4f,%d", digits
// and punctuation only.
func shotsOf(shots string) string {
	return "Shots: `" + strings.ReplaceAll(shots, ";", "; ") + "`"
}

// renderData is a data version's page: where it came from, its versions,
// and its data, which is all the hole there is.
func renderData(e *entry) string {
	pkgs := strings.Replace(officialPrefix, "gno.land/r/", "/p/", 1) // the course's packages, as "/p/<ns>/"
	s := "# " + e.name + ": its data\n\n**" + e.id + "**, version " + strconv.Itoa(e.version) + " of " + md(e.slot, hub+":"+e.slot) +
		", published at height " + strconv.FormatInt(e.height, 10) + " by " + who(e.by.String()) + ". " + md("Play it", hub+":"+e.id) + ".\n\n"
	if e.note != "" {
		s += "> " + e.note + "\n\n"
	}
	if e.next != "" {
		s += "_Archived: " + md(e.next, hub+":"+e.next) + " took its place._\n\n"
	}
	s += "## Versions\n\n| version | height | by | sha256 | note |\n|---|---|---|---|---|\n"
	now := find(current(e.slot))
	for n := firstVersion(now); n <= now.version; n++ {
		v := find(e.slot + "/v" + strconv.Itoa(n))
		if v == nil {
			continue // (one before this course's first here: imported from v1, with v1's number)
		}
		s += "| " + md(v.id, hub+":"+v.id+"/data") + " | " + strconv.FormatInt(v.height, 10) + " | " + who(v.by.String()) + " | `" + v.sha[:16] + "…` | " + v.note + " |\n"
	}
	data, _ := holeData.Get(e.id)
	s += "\n## The data\n\n" + strconv.Itoa(len(data)) + " bytes of GG1, sha256 `" + e.sha + "`. " +
		"Every call decodes it with " + md("course", pkgs+"course$source") + " and plays it with " + md("physics", pkgs+"physics$source") +
		"; " + md("golf", hub+"$source") + " checked it once, when it was published. HoleData gives it back as hex:\n\n"
	return s + "```\n" + hex.EncodeToString([]byte(data)) + "\n```\n"
}

// board rasterises the hole: wear, then zones, posts, walls, cup, and mine,
// the focused player's round (nil for none); now is this period's forecast.
func board(e *entry, h *course.Simple, f *physics.Field, mine *round, now course.Forecast) string {
	bw, bh := h.W, h.H
	g := make([][]rune, bh)
	wear := e.wearGrid()
	for y := 0; y < bh; y++ {
		row := make([]rune, bw)
		for x := 0; x < bw; x++ {
			row[x] = wearRune(wear, x*course.WearW/bw, y*course.WearH/bh)
		}
		g[y] = row
	}
	// the walls, traced once: drawn, and what the flood fill stops at
	wall := make([][]rune, bh)
	for y := range wall {
		wall[y] = make([]rune, bw)
	}
	for _, w := range f.Walls {
		trace(wall, w.Seg, mark(w.Mark, markWall))
	}

	// the last flight first, so the pieces drawn over it stay visible
	if mine != nil {
		fc := now
		if mine.period != now.Period { // a round begun in the period before
			fc = weatherOf(e, h, mine.period)
		}
		for _, p := range lastShot(h, mine, fc).Path {
			put(g, p, '·')
		}
	}

	tunnel := 0
	for i := range f.Zones {
		z := &f.Zones[i]
		m := mark(z.Mark, '?')
		if z.Kind == physics.Tunnel && tunnel < maxTunnels {
			// a tunnel's mouth and exit share a digit
			tunnel++
			m = rune('0' + tunnel)
		}
		drawZone(g, z, m)
	}
	for y := range wall {
		for x, c := range wall[y] {
			if c != 0 {
				g[y][x] = c
			}
		}
	}
	for _, p := range f.Posts {
		fill(g, p.Circle, mark(p.Mark, markPost))
		put(g, p.C, mark(p.Mark, markPost)) // a small post still shows
	}
	tunnel = 0
	for _, z := range f.Zones {
		if z.Kind == physics.Tunnel && tunnel < maxTunnels {
			tunnel++
			put(g, z.Vec, rune('0'+tunnel))
		}
	}
	put(g, h.Start(), markTee)
	put(g, h.Cup(), markCup)

	// ground no ball can reach is not green: blank it, as the 3D client does
	blankUnreachable(g, wall, f, h.Start(), h.Cup())

	// only your own ball: everyone's at once would bury the board
	if mine != nil {
		put(g, mine.ball(), '@')
	}

	var sb strings.Builder
	for _, row := range g {
		sb.WriteString(string(row) + "\n")
	}
	return sb.String()
}

// drawZone marks the cells whose centre the zone holds, as the physics sees it
// (physics.Zone.Contains): a polygon's row from where the centre line crosses
// its edges, an ellipse's as the run the physics' test finds from its middle.
func drawZone(g [][]rune, z *physics.Zone, m rune) {
	bh := len(g)
	if bh == 0 {
		return
	}
	bw := len(g[0])
	x0, x1 := boxCells(z.Min.X, z.Max.X, bw)
	y0, y1 := boxCells(z.Min.Y, z.Max.Y, bh)
	if x0 >= x1 {
		return
	}
	poly := len(z.Poly) >= 3
	var flip []bool
	if poly {
		flip = make([]bool, x1+1)
	}
	for y := y0; y < y1; y++ {
		row, py := g[y], float64(y)+0.5
		switch {
		case poly:
			// even-odd, as inPoly: a sweep from the right flips at each
			// crossing's cell. No sort: a row costs its edges and cells.
			for x := x0; x <= x1; x++ {
				flip[x] = false
			}
			a := z.Poly[len(z.Poly)-1]
			for _, b := range z.Poly { // the edge from a to b
				if (a.Y > py) != (b.Y > py) {
					c := cellAt(a.X+(py-a.Y)*(b.X-a.X)/(b.Y-a.Y), x0, x1)
					flip[c] = !flip[c]
				}
				a = b
			}
			in := false
			for x := x1 - 1; x >= x0; x-- {
				if flip[x+1] {
					in = !in
				}
				if in != z.Outside {
					row[x] = m
				}
			}
		case z.Round:
			hx, hy := (z.Max.X-z.Min.X)/2, (z.Max.Y-z.Min.Y)/2
			dy := (py - z.Min.Y - hy) / hy
			in := func(x int) bool {
				dx := (float64(x) + 0.5 - z.Min.X - hx) / hx
				return dx*dx+dy*dy < 1
			}
			// the cells nearest the middle: if neither is in, none is
			mid := int(math.Floor(z.Min.X + hx - 0.5))
			c := -1
			for _, x := range [2]int{mid, mid + 1} {
				if x < x0 {
					x = x0
				}
				if x >= x1 {
					x = x1 - 1
				}
				if c < 0 && in(x) {
					c = x
				}
			}
			if c >= 0 {
				from := firstCell(x0, c, in)
				to := firstCell(c, x1, func(x int) bool { return !in(x) })
				fillRow(row, from, to, m)
			}
		default:
			fillRow(row, x0, x1, m)
		}
	}
}

// boxCells is the cells from int(lo) to int(hi), within 0..n, whose centre
// lies in [lo, hi): the cells the physics' box test takes.
func boxCells(lo, hi float64, n int) (int, int) {
	a, b := span(lo, hi, n)
	if a >= b {
		return a, a
	}
	a = firstCell(a, b, func(x int) bool { return float64(x)+0.5 >= lo })
	return a, firstCell(a, b, func(x int) bool { return !(float64(x)+0.5 < hi) })
}

// cellAt is the first cell in [lo, hi), lo >= 0, whose centre is at or past c
// (!(x+0.5 < c), as the physics compares), hi if none: ceil(c-0.5).
func cellAt(c float64, lo, hi int) int {
	if !(float64(lo)+0.5 < c) { // NaN too, as a search would find
		return lo
	}
	if c >= float64(hi) {
		return hi
	}
	x := int(c) // c > 0.5: its floor
	if float64(x)+0.5 < c {
		x++
	}
	if x > hi {
		x = hi
	}
	return x
}

// firstCell is the first x in [lo, hi) where ok turns true, hi if it never
// does: ok is false up to some x, and true from there.
func firstCell(lo, hi int, ok func(x int) bool) int {
	for lo < hi {
		mid := (lo + hi) / 2
		if ok(mid) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}

func fillRow(row []rune, from, to int, m rune) {
	for x := from; x < to; x++ {
		row[x] = m
	}
}

// span is the cells from int(lo) to int(hi), within 0..n.
func span(lo, hi float64, n int) (int, int) {
	a, b := int(lo), int(hi)
	if a < 0 {
		a = 0
	}
	if b > n {
		b = n
	}
	return a, b
}

// maxBoardWork bounds a board's drawing, in thousands of gas (boardWork):
// past it the page does not draw, far under the 3e9 a query may use.
const maxBoardWork = 600000

// boardWork estimates board's cost in thousands of gas, with measured weights:
// a board cell; a cell and a polygon edge per row of a zone's box (every edge
// counted as crossing, as a zigzag's do); a step along a wall; a cell of a
// post's box.
func boardWork(f *physics.Field, h *course.Simple) int {
	bw, bh := h.W, h.H
	n := 32 * bw * bh
	for i := range f.Zones {
		z := &f.Zones[i]
		x0, x1 := span(z.Min.X, z.Max.X, bw)
		y0, y1 := span(z.Min.Y, z.Max.Y, bh)
		if x1 > x0 && y1 > y0 {
			n += (y1 - y0) * (5*(x1-x0) + 16*len(z.Poly))
		}
	}
	for i := range f.Walls {
		n += 10 * (int(f.Walls[i].Seg.B.Sub(f.Walls[i].Seg.A).Len()*2) + 2)
	}
	for i := range f.Posts {
		d := int(2*f.Posts[i].R) + 2
		n += 20 * d * d
	}
	return n
}

// key names the board's fixed marks it shows (tee and cup always), with the
// skins of the walls drawn `#`.
func key(b, walls string) string {
	// what the board shows, read once: a big board is thousands of runes
	var on [128]bool
	shot := false // '·', the one mark past ASCII
	for _, c := range b {
		if c < 128 {
			on[c] = true
		} else if c == '·' {
			shot = true
		}
	}
	s := "`*` tee · `U` cup"
	for _, k := range []struct{ marks, what string }{
		{"@", "the ball"}, {"·", "its last shot"}, {"#", "wall"},
		{":;x%", "wear (worn by past shots)"},
	} {
		shown := k.marks == "·" && shot
		for i := 0; i < len(k.marks) && k.marks[i] < 128; i++ {
			shown = shown || on[k.marks[i]]
		}
		if shown {
			s += " · `" + k.marks + "` " + k.what
			if k.marks == "#" && walls != "" {
				s += " (" + walls + ")"
			}
		}
	}
	// tunnels are numbered from 1: name the digits the board has
	digits := ""
	for c := '1'; c <= '9'; c++ {
		if on[c] {
			digits += string(c)
		}
	}
	switch len(digits) {
	case 0:
	case 1:
		s += " · `" + digits + "` a tunnel and its exit"
	default:
		s += " · `" + digits + "` tunnels, each with its exit"
	}
	return s
}

// legend names the pieces the hole gave a skin (a slope with the way it
// falls), and the skins of its `#` walls.
func legend(f *physics.Field) (string, string) {
	s, walls := "", ""
	add := func(m rune, def rune, skin string) {
		if skin == "" {
			return
		}
		r := mark(m, def)
		if r == markWall {
			// the key's own wall: name its skins there, once each
			if !strings.Contains(", "+walls+", ", ", "+skin+", ") {
				if walls != "" {
					walls += ", "
				}
				walls += skin
			}
			return
		}
		// once each: a mark with two meanings (two slopes' ways) says both
		item := ufmt.Sprintf(" · `%s` %s", string(r), skin)
		if strings.Contains(s+" · ", item+" · ") {
			return
		}
		s += item
	}
	for _, z := range f.Zones {
		if z.Kind == physics.Tunnel {
			continue // numbered on the board
		}
		name := cleanSkin(z.Skin)
		if name == "" || name == z.Kind.String() {
			name = z.Kind.String()
		} else {
			name += " (" + z.Kind.String() + ")"
		}
		// a slope says which way it takes the ball, in the shot's degrees (the wind's, the cup's)
		if z.Kind == physics.Slope && (z.Vec.X != 0 || z.Vec.Y != 0) {
			a, _ := aim(physics.Vec2{}, z.Vec)
			if z.Air {
				name += ufmt.Sprintf(", pushes toward %.0f°", a)
			} else {
				name += ufmt.Sprintf(", falls toward %.0f°", a)
			}
		}
		add(z.Mark, '?', name)
	}
	for _, p := range f.Posts {
		add(p.Mark, markPost, cleanSkin(p.Skin))
	}
	for _, w := range f.Walls {
		add(w.Mark, markWall, cleanSkin(w.Skin))
	}
	return s, walls
}

// mark is what a piece shows on the text board. Marks come from the hole's
// author, and the board sits in a code block: only a printable ASCII
// character that cannot close the block or start markdown is kept.
func mark(m, def rune) rune {
	if m <= ' ' || m > '~' || strings.ContainsRune("`[]()<>*_#|\\!@oU0123456789", m) {
		return def
	}
	return m
}

// wearRune takes wear-cell coordinates.
func wearRune(wear []int, x, y int) rune {
	i := y*course.WearW + x
	if i < 0 || i >= len(wear) {
		return rune(wearRunes[0])
	}
	switch v := wear[i]; {
	case v == 0:
		return rune(wearRunes[0])
	case v <= wearLight:
		return rune(wearRunes[1])
	case v <= wearWorn:
		return rune(wearRunes[2])
	case v <= wearGroove:
		return rune(wearRunes[3])
	default:
		return rune(wearRunes[4])
	}
}

// trace draws a wall as points every half unit, put inlined: a board has
// thousands.
func trace(g [][]rune, s physics.Segment, c rune) {
	bh := len(g)
	if bh == 0 {
		return
	}
	bw := len(g[0])
	d := s.B.Sub(s.A)
	steps := int(d.Len()*2) + 1
	for i := 0; i <= steps; i++ {
		k := float64(i) / float64(steps)
		x, y := int(s.A.X+d.X*k), int(s.A.Y+d.Y*k)
		if x == bw {
			x = bw - 1
		}
		if y == bh {
			y = bh - 1
		}
		if x >= 0 && x < bw && y >= 0 && y < bh {
			g[y][x] = c
		}
	}
}

// fill draws a post: the cells whose centre is within its radius. LenCmp
// skips Len's software square root.
func fill(g [][]rune, c physics.Circle, r rune) {
	bh := len(g)
	if bh == 0 {
		return
	}
	bw := len(g[0])
	for y := int(c.C.Y - c.R); y <= int(c.C.Y+c.R); y++ {
		gy := y
		if gy == bh {
			gy = bh - 1
		}
		if gy < 0 || gy >= bh {
			continue
		}
		for x := int(c.C.X - c.R); x <= int(c.C.X+c.R); x++ {
			gx := x
			if gx == bw {
				gx = bw - 1
			}
			if gx >= 0 && gx < bw && (physics.Vec2{X: float64(x) + 0.5, Y: float64(y) + 0.5}).Sub(c.C).LenCmp(c.R) <= 0 {
				g[gy][gx] = r
			}
		}
	}
}

func put(g [][]rune, p physics.Vec2, c rune) {
	x, y := int(p.X), int(p.Y)
	bh := len(g)
	if bh == 0 {
		return
	}
	bw := len(g[0])
	// the far edge belongs to the last cell, not off the board
	if x == bw {
		x = bw - 1
	}
	if y == bh {
		y = bh - 1
	}
	if x < 0 || x >= bw || y < 0 || y >= bh {
		return
	}
	g[y][x] = c
}

func short(addr string) string {
	if len(addr) <= 12 {
		return addr
	}
	return addr[:8] + "…" + addr[len(addr)-4:]
}

// blankUnreachable clears the cells no ball can reach: a flood fill from the
// tee, the cup and where tunnels and hazards put the ball, stopped by walls.
func blankUnreachable(g, wall [][]rune, f *physics.Field, seeds ...physics.Vec2) {
	bh := len(g)
	if bh == 0 {
		return
	}
	bw := len(g[0])
	for _, z := range f.Zones {
		if z.Kind == physics.Tunnel || z.Kind == physics.Hazard {
			seeds = append(seeds, z.Vec)
		}
	}
	// a row's run at a time, no closure: a board has thousands of cells
	seen := make([][]bool, bh)
	for y := range seen {
		seen[y] = make([]bool, bw)
	}
	var stack []int // y*bw + x: a cell whose run is yet to fill
	for _, p := range seeds {
		if x, y := int(p.X), int(p.Y); x >= 0 && y >= 0 && x < bw && y < bh {
			stack = append(stack, y*bw+x)
		}
	}
	for len(stack) > 0 {
		c := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		x, y := c%bw, c/bw
		s, w := seen[y], wall[y]
		if s[x] || w[x] != 0 {
			continue
		}
		l, r := x, x+1
		for l > 0 && !s[l-1] && w[l-1] == 0 {
			l--
		}
		for r < bw && !s[r] && w[r] == 0 {
			r++
		}
		for i := l; i < r; i++ {
			s[i] = true
		}
		// the rows above and below: a cell for each open run under this one
		for ny := y - 1; ny <= y+1; ny += 2 {
			if ny < 0 || ny >= bh {
				continue
			}
			ns, nw := seen[ny], wall[ny]
			open := false
			for i := l; i < r; i++ {
				o := !ns[i] && nw[i] == 0
				if o && !open {
					stack = append(stack, ny*bw+i)
				}
				open = o
			}
		}
	}
	for y := 0; y < bh; y++ {
		for x := 0; x < bw; x++ {
			if !seen[y][x] && wall[y][x] == 0 {
				g[y][x] = ' '
			}
		}
	}
}

// race is the 3D game's dare link (by=): this hole against p's best's ghost.
func race(e *entry, p, label string) string { return md(label, playLink(e)+"&by="+p) }

// byName is a player by their gno.land name when they have one.
func byName(addr string) string {
	if n := nameOf(addr); n != "" {
		return md("@"+n, "/u/"+n)
	}
	return who(addr)
}

// count is n things, said right for one.
func count(n int, what string) string {
	if n == 1 {
		return "1 " + what
	}
	return strconv.Itoa(n) + " " + what + "s"
}
