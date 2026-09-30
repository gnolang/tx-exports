package golf

import (
	"math"
	"strconv"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnogolf/course"
	"gno.land/p/nym-alexiscolin000/gnogolf/physics"
	bptree "gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

// HoleState is the hole as JSON for a client: geometry, skins (names the
// client looks up), weather and wear, all it needs to draw the hole and aim.
// hole is a version's id or an alias; "hole" in the answer is always the
// version's id, the one to write with, with its "slot" and "v", and an
// archived one's "next".
//
// A shot's path (Round, Simulate*) is the flight the chain computed: replay
// it, never re-simulate. Points far apart are a tunnel: do not interpolate.
func HoleState(hole string) string {
	e := readHole(hole)
	h := e.hole()
	f := h.Field()
	var sb strings.Builder
	sb.WriteString("{" + versionJSON +
		`,"hole":` + jstr(e.id) +
		`,"name":` + jstr(e.name) +
		`,"official":` + strconv.FormatBool(e.official))
	if e.slot != "" {
		sb.WriteString(`,"slot":` + jstr(e.slot) + `,"v":` + strconv.Itoa(e.version))
	}
	if e.next != "" {
		sb.WriteString(`,"next":` + jstr(e.next))
	}
	p := Period()
	sb.WriteString(boardJSON(h) +
		`,"par":` + strconv.Itoa(e.par) +
		`,"world":` + jstr(e.world) + `,"order":` + jnum(e.order) +
		`,"timed":` + strconv.FormatBool(h.Varies()) +
		`,"period":` + strconv.FormatInt(p, 10) +
		`,"weather":` + forecastJSON("", weatherOf(e, h, p)) +
		`,"start":` + jvec(h.Start()) +
		`,"cup":` + jvec(h.Cup()) +
		`,"cupR":` + jnum(h.CupRadius) + `,"ballR":` + jnum(f.Radius))
	// the hole's work before the weather (newWork): the client splits a save
	// and sets its gas by it
	w := newWork(h, nil)
	sb.WriteString(ufmt.Sprintf(`,"work":{"walls":%d,"pieces":%d,"setup":%d}`, w.walls, w.pieces, w.setup))
	sb.WriteString(`,"walls":` + wallsJSON(f.Walls) + `,"posts":` + postsJSON(f.Posts))
	sb.WriteString(`,"zones":` + zonesJSON(f.Zones, true))
	sb.WriteString(`,"wear":{"w":` + strconv.Itoa(course.WearW) + `,"h":` + strconv.Itoa(course.WearH) + `,"cells":[`)
	for i, c := range e.wearGrid() {
		sb.WriteString(sep(i))
		sb.WriteString(strconv.Itoa(c))
	}
	sb.WriteString("]}}")
	return sb.String()
}

// roundJSON is one player's round: ball rounded, rest exact (for SimulateFrom)
// and the last stroke replayed: rounds store shots, not paths.
func roundJSON(e *entry, h *course.Simple, player string, r *round) string {
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"player":` + jstr(player) +
		`,"ball":` + jvec(r.ball()) + `,"rest":` + jexact(r.ball()) +
		ufmt.Sprintf(`,"strokes":%d,"period":%d`, r.strokes, r.period) +
		`,"mode":` + jstr(modeNames[r.mode]) +
		`,"shots":` + jstr(r.shots))
	shot := lastShot(h, r, weatherOf(e, h, r.period))
	sb.WriteString(`,"path":[` + pathJSON(shot.Path) + `],"air":` + jstr(airOf(shot)) + `,"cause":` + jstr(string(shot.Cause)))
	sb.WriteString("}")
	return sb.String()
}

// lastShot replays a round's last stroke, read-only, with its stroke number,
// tick and weather (fc, its period's forecast): the same flight, less the
// wear. Empty before a first one.
func lastShot(h *course.Simple, r *round, fc course.Forecast) physics.Shot {
	if r.strokes == 0 || r.shots == "" {
		return physics.Shot{}
	}
	s := r.shots
	if i := strings.LastIndex(s, ";"); i >= 0 {
		s = s[i+1:]
	}
	angle, power, tick := parseShot(s)
	from := physics.Vec2{X: r.fx, Y: r.fy}
	shot, holed := h.PreviewWith(from, angle*math.Pi/180, power, r.strokes-1, tick, fc.Zones)
	return back(h, from, shot, holed)
}

// pathJSON is a shot's path points, comma separated.
func pathJSON(ps []physics.Vec2) string {
	var sb strings.Builder
	for i, p := range ps {
		sb.WriteString(sep(i))
		sb.WriteString(jvec(p))
	}
	return sb.String()
}

// airOf is a shot's air flags, one character per path point: "0001100…".
func airOf(s physics.Shot) string {
	b := make([]byte, len(s.Path))
	for i := range b {
		b[i] = '0'
		if i < len(s.Air) && s.Air[i] {
			b[i] = '1'
		}
	}
	return string(b)
}

// Round is one player's round under way on a hole with its last stroke's
// path, or null if they have none: never started, holed (its best is kept:
// Ghost) or Reset. It costs one stroke of gas.
func Round(hole string, player address) string {
	e := readHole(hole)
	v := e.roundTree().Get(player.String())
	if v == nil {
		return "null"
	}
	return roundJSON(e, e.hole(), player.String(), v.(*round))
}

func sep(i int) string {
	if i == 0 {
		return ""
	}
	return ","
}

// jnum is a number with 3 decimals, the bytes of ufmt's "%.3f" at a fraction
// of its gas. NaN and Inf, not JSON, print 0. Below 1e12, v*1000 is within
// 1.2e-4 of the exact decimal, so its integer part decides the rounding
// unless the fraction is within 1e-3 of a half: those, and huge numbers, go
// to strconv, which is exact.
func jnum(v float64) string {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return "0"
	}
	a := v * 1000
	if a < 0 {
		a = -a
	}
	if a >= 1e12 {
		return strconv.FormatFloat(v, 'f', 3, 64)
	}
	k := int64(a)
	switch f := a - float64(k); {
	case f > 0.499 && f < 0.501:
		return strconv.FormatFloat(v, 'f', 3, 64)
	case f > 0.5:
		k++
	}
	frac := k % 1000
	s := strconv.FormatInt(k/1000, 10) + "."
	if frac < 100 {
		s += "0"
	}
	if frac < 10 {
		s += "0"
	}
	s += strconv.FormatInt(frac, 10)
	if math.Signbit(v) { // "%.3f" keeps the sign of a negative that rounds to 0
		s = "-" + s
	}
	return s
}

// jexact is a point exactly, as the shortest decimals that read back as the
// same float64: what a client hands back to SimulateFrom.
func jexact(v physics.Vec2) string {
	return "[" + strconv.FormatFloat(v.X, 'g', -1, 64) + "," + strconv.FormatFloat(v.Y, 'g', -1, 64) + "]"
}

// versionJSON opens every object a read returns.
const versionJSON = `"version":1`

func jvec(v physics.Vec2) string { return "[" + jnum(v.X) + "," + jnum(v.Y) + "]" }

// jstr quotes an author's string so it cannot break out of its JSON. Every
// byte below 0x20 is escaped: one in one hole's name would make Holes()
// invalid JSON for every client.
func jstr(s string) string {
	const hex = "0123456789abcdef"
	b := make([]byte, 0, len(s)+2)
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b = append(b, '\\', c)
		case c < 0x20:
			b = append(b, '\\', 'u', '0', '0', hex[c>>4], hex[c&15])
		default:
			b = append(b, c)
		}
	}
	return string(append(b, '"'))
}

// Holes lists at most maxListed holes for a client's menu, as listed orders
// them: the course's current holes, its latest archived versions, then
// community holes, newest first, perAuthor an address, none hidden (the rest
// are in Community). official marks the course's holes, the only ones in a
// cup and the course ranking; next is the version that replaced a hole, slot
// its alias, play the 3D client's link, successor the realm that took the
// course over ("" if none). It decodes nothing.
func Holes() string {
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"play":` + jstr(playURL) + `,"successor":` + jstr(successor) + `,"holes":[`)
	for i, e := range listed() {
		sb.WriteString(sep(i) + holeRow(e))
	}
	sb.WriteString("]}")
	return sb.String()
}

// holeRow is one hole as Holes and Community list it.
func holeRow(e *entry) string {
	s := `{"id":` + jstr(e.id) +
		`,"name":` + jstr(e.name) +
		`,"official":` + strconv.FormatBool(e.official) +
		`,"plays":` + strconv.Itoa(e.plays) +
		`,"best":` + strconv.Itoa(e.rec(assisted).best) +
		`,"proBest":` + strconv.Itoa(e.rec(pro).best) +
		`,"par":` + strconv.Itoa(e.par) +
		`,"world":` + jstr(e.world) + `,"order":` + jnum(e.order) + `,"next":` + jstr(e.next)
	if e.slot != "" {
		s += `,"slot":` + jstr(e.slot)
	}
	return s + "}"
}

// Community is a page of every community hole, every version of each, by id:
// all that Holes leaves out. It is paged like Records.
func Community(after string, limit int) string {
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"rows":[`)
	next := page(bpWalk(community), after, limit, func(i int, _ string, v any) {
		sb.WriteString(sep(i) + holeRow(v.(*entry)))
	})
	sb.WriteString(`],"next":` + jstr(next) + "}")
	return sb.String()
}

// perAuthor is the most published holes of one address Holes and the hub
// list: one address publishing a hundred cannot push everyone else's out.
const perAuthor = 3

// listed is the holes in list order, at most maxListed: every current course
// hole in course order; then, if minCommunity places stay free, up to
// maxArchived archived course versions, latest archived first; then, in the
// room left, the newest shown community holes (current, not hidden) among
// each author's perAuthor newest, by block height then alias, last first. An
// author fills perAuthor rows at most, however many holes they publish.
//
// It reads about what it lists: authors latest first, perAuthor keys each,
// until an author's latest is older than every row kept (room+1 authors at
// most). Hidden holes have no byAuthor row: nothing hidden is walked.
func listed() []*entry {
	list := make([]*entry, 0, maxListed)
	full := func() bool { return len(list) >= maxListed }
	slots.Iterate("", "", func(_ string, v any) bool {
		list = append(list, find(v.(string)))
		return full()
	})
	if room := maxListed - minCommunity - len(list); room > 0 {
		if room > maxArchived {
			room = maxArchived
		}
		archived.ReverseIterate("", "", func(_ string, v any) bool {
			list = append(list, find(v.(string)))
			room--
			return room == 0
		})
	}
	room := maxListed - len(list)
	if room <= 0 {
		return list
	}
	// the newest room of the rows seen, newest first, by recentKey(height,
	// alias): an author walked later has only older holes than the one
	// before's latest, so a row past room never comes back
	type seen struct{ key, id string }
	top := make([]seen, 0, room)
	byAuthor.ReverseIterate("", authorRows, func(ak string, _ any) bool {
		if len(top) == room && ak < top[room-1].key {
			return true // their latest, and so all theirs, are older than all kept
		}
		a := ak[13:] + " "
		n := 0
		byAuthor.ReverseIterate(a, a[:len(a)-1]+"!", func(k string, v any) bool {
			// "<address> <height> <slug>" -> "<height> <address>/<slug>"
			key := k[len(a):len(a)+12] + " " + a[:len(a)-1] + "/" + k[len(a)+13:]
			i := len(top)
			for i > 0 && top[i-1].key < key {
				i--
			}
			if i < room {
				if len(top) < room {
					top = append(top, seen{})
				}
				copy(top[i+1:], top[i:len(top)-1])
				top[i] = seen{key, v.(string)}
			}
			n++
			return n == perAuthor
		})
		return false
	})
	for _, s := range top {
		list = append(list, find(s.id))
	}
	return list
}

// authorRows is past the last of byAuthor's author rows ("<height> <address>")
// and before its first hole ("g1…"): no key is ":".
const authorRows = ":"

// maxArchived bounds the archived course versions Holes and the hub list,
// and minCommunity is the room they leave for community holes.
const (
	maxArchived  = 20
	minCommunity = 20
)

// SimulateFrom previews one shot, read-only: from an exact ball (a "rest"
// answered before), shot "angle,power,tick", its stroke number (0 is the
// first; timed and pulse holes change with it) and any period not ahead.
// It is what PlayRoundAt would play, for one shot's gas. As a vm/qeval query
// it needs no transaction or wallet: a client animates a shot the instant it
// is released.
func SimulateFrom(hole string, ballX, ballY float64, shot string, stroke int, period int64) string {
	notAhead(period)
	validStroke(stroke)
	angle, power, tick := parseShot(shot)
	e := readHole(hole)
	h := e.hole()
	ball := onBoard(h, ballX, ballY)
	angle, power = validShot(angle, power)
	sh, holed := resolve(h.PreviewWith(ball, angle*math.Pi/180, power, stroke, tick, weatherOf(e, h, period).Zones))
	sh = back(h, ball, sh, holed)
	return "{" + versionJSON + `,"holed":` + strconv.FormatBool(holed) + `,"bounces":` + strconv.Itoa(sh.Bounces) + shotJSON(sh) + "}"
}

func validStroke(stroke int) {
	if stroke < 0 || stroke >= maxRoundStrokes {
		panic("golf: a stroke is between 0 and 59")
	}
}

// onBoard refuses a ball off the board (or NaN): no round leaves one there.
func onBoard(h *course.Simple, x, y float64) physics.Vec2 {
	w, hh := h.W, h.H
	if !(x >= 0 && x <= float64(w) && y >= 0 && y <= float64(hh)) {
		panic("golf: the ball must be on the board")
	}
	return physics.Vec2{X: x, Y: y}
}

// shotJSON is a shot's path, air, cause, work (Shot.Work, which a client adds
// up as a commit does) and exact resting point.
func shotJSON(shot physics.Shot) string {
	return `,"path":[` + pathJSON(shot.Path) + `],"air":` + jstr(airOf(shot)) + `,"cause":` + jstr(string(shot.Cause)) +
		`,"work":` + strconv.Itoa(shot.Work) + `,"rest":` + jexact(shot.Rest())
}

// SimulateRound replays a shot list from the tee, read-only, and returns its
// last shot and stroke count: what PlayRound would record, refusals included.
// Continue from an exact "rest" (SimulateFrom): rounded points are for drawing.
func SimulateRound(hole string, shots string) string {
	return simulateRound(hole, nil, 0, shots, Period())
}

// SimulateRoundAt is SimulateRound in a period's weather, the current one or
// the one before, as a round's first stroke: it agrees with PlayRoundAt.
func SimulateRoundAt(hole string, shots string, period int64) string {
	playablePeriod(period)
	return simulateRound(hole, nil, 0, shots, period)
}

// SimulateRoundIn is SimulateRound in any period gone by, to check a recorded
// round as the chain played it. Weather still to come is refused.
func SimulateRoundIn(hole string, shots string, period int64) string {
	notAhead(period)
	return simulateRound(hole, nil, 0, shots, period)
}

// SimulateCommit previews the next PlayRoundAt (or PlayRoundPro) commit,
// read-only: shots from the exact ball ("rest") at stroke number stroke (0 is
// the first) in period's weather. It refuses what that commit would (too much
// work, too many strokes, a weather over), so a client checks every commit
// before it signs any. JSON as SimulateRound; strokes counts after the commit.
func SimulateCommit(hole string, ballX, ballY float64, stroke int, shots string, period int64) string {
	if stroke == 0 {
		playablePeriod(period)
	} else {
		notAhead(period)
		notOver(period)
	}
	validStroke(stroke)
	return simulateRound(hole, &physics.Vec2{X: ballX, Y: ballY}, stroke, shots, period)
}

// simulateRound is the SimulateRound* and SimulateCommit replay: from nil is
// the tee, and the first shot is stroke number strokes.
func simulateRound(hole string, from *physics.Vec2, strokes int, shots string, period int64) string {
	e := readHole(hole)
	h := e.hole()
	ball := h.Start()
	if from != nil {
		ball = onBoard(h, from.X, from.Y)
	}
	fc := weatherOf(e, h, period)
	weather := fc.Zones
	list := shotList(shots)
	w := newWork(h, weather)
	w.fixed = fixedGas(e, fc)
	holed := false
	var last physics.Shot
	for _, s := range list {
		if strokes >= maxRoundStrokes {
			panic(errStrokeLimit)
		}
		w.next(h)
		angle, power, tick := parseShot(s)
		angle, power = validShot(angle, power)
		last, holed = resolve(h.PreviewWith(ball, angle*math.Pi/180, power, strokes, tick, weather))
		last = back(h, ball, last, holed)
		w.add(last)
		ball = last.Rest()
		strokes++
		if holed {
			break
		}
	}
	return "{" + versionJSON + `,"holed":` + strconv.FormatBool(holed) + `,"strokes":` + strconv.Itoa(strokes) +
		`,"bounces":` + strconv.Itoa(last.Bounces) + `,"period":` + strconv.FormatInt(period, 10) +
		shotJSON(last) + "}"
}

func boardJSON(h *course.Simple) string {
	w, hh := h.W, h.H
	return `,"board":{"w":` + strconv.Itoa(w) + `,"h":` + strconv.Itoa(hh) + "}"
}

func wallsJSON(ws []physics.Wall) string {
	var sb strings.Builder
	sb.WriteString("[")
	for i := range ws {
		w := &ws[i]
		sb.WriteString(sep(i) + "{" + `"a":` + jvec(w.Seg.A) + `,"b":` + jvec(w.Seg.B) +
			`,"skin":` + jstr(cleanSkin(w.Skin)) + timingJSON(w.Every, w.On, w.Phase) + "}")
	}
	sb.WriteString("]")
	return sb.String()
}

func postsJSON(ps []physics.Post) string {
	var sb strings.Builder
	sb.WriteString("[")
	for i := range ps {
		p := &ps[i]
		sb.WriteString(sep(i) + "{" + `"c":` + jvec(p.C) + `,"r":` + jnum(p.R) +
			`,"skin":` + jstr(cleanSkin(p.Skin)) + "}")
	}
	sb.WriteString("]")
	return sb.String()
}

// zonesJSON is a hole's zones, or the weather's (forecastJSON: no flags).
// With flags, "air" and "capped" are printed only when true.
func zonesJSON(zs []physics.Zone, flags bool) string {
	var sb strings.Builder
	sb.WriteString("[")
	for i := range zs {
		z := &zs[i]
		sb.WriteString(sep(i) + "{" + `"kind":` + jstr(z.Kind.String()) +
			`,"min":` + jvec(z.Min) + `,"max":` + jvec(z.Max) +
			`,"vec":` + jvec(z.Vec) + `,"scale":` + jnum(z.Scale) +
			`,"round":` + strconv.FormatBool(z.Round) + polyJSON(z) + timingJSON(z.Every, z.On, z.Phase))
		if flags && z.Air {
			sb.WriteString(`,"air":true`)
		}
		if flags && z.Capped {
			sb.WriteString(`,"capped":true`)
		}
		sb.WriteString(`,"skin":` + jstr(cleanSkin(z.Skin)) + "}")
	}
	sb.WriteString("]")
	return sb.String()
}

// timingJSON is a timed piece's clock (a tram, a storm's gusts); nothing for
// an untimed one.
func timingJSON(every, on, phase int) string {
	if every <= 0 {
		return ""
	}
	return `,"every":` + strconv.Itoa(every) + `,"on":` + strconv.Itoa(on) + `,"phase":` + strconv.Itoa(phase)
}

// polyJSON is a polygon zone's outline, and whether it is the outside of it;
// nothing for the usual rectangle or ellipse.
func polyJSON(z *physics.Zone) string {
	if len(z.Poly) < 3 {
		return ""
	}
	return `,"poly":[` + pathJSON(z.Poly) + `],"outside":` + strconv.FormatBool(z.Outside)
}

// Extras is what a timed hole adds at one stroke of a round (0 is the first),
// to draw over HoleState's field. Empty for other holes.
func Extras(hole string, stroke int) string {
	h := readHole(hole).hole()
	if stroke < 0 {
		return "{" + versionJSON + `,"walls":[],"posts":[],"zones":[]}`
	}
	ws, ps := h.Extras(stroke)
	return "{" + versionJSON + `,"walls":` + wallsJSON(ws) + `,"posts":` + postsJSON(ps) + `,"zones":` + zonesJSON(h.ExtraZones(stroke), true) + "}"
}

// Leaderboard is a mode's course-wide top ten ("assisted" or "pro"): named
// players' bests on the current course holes, summed; most holes, then the
// best score against par (strokes - par), then the first there. Its cost does
// not grow with players.
func Leaderboard(mode string) string {
	m := modeOf(mode)
	var sb strings.Builder
	// holes: the course's current ones, the only ones that count
	sb.WriteString("{" + versionJSON + `,"mode":` + jstr(modeNames[m]) + `,"holes":` + strconv.Itoa(slots.Size()) + `,"rows":[`)
	n := 0
	eachRanked(m, func(r *row, name string) {
		sb.WriteString(sep(n) + standingRow(r.player, name, r))
		n++
	})
	sb.WriteString("]}")
	return sb.String()
}

// eachRanked walks a mode's top ten: the first named players of its ranking,
// with their names. A name deleted since is skipped, not shown.
func eachRanked(m int, fn func(r *row, name string)) {
	n, walked := 0, 0
	ranks[m].Iterate("", "", func(_ string, v any) bool {
		walked++ // skipped names count: the walk stays bounded
		p := v.(string)
		if name := nameOf(p); name != "" {
			fn(totals[m].Get(p).(*row), name)
			n++
		}
		return n >= topSize || walked >= maxWalked
	})
}

// maxWalked is the most rows a top ten walks, skipped names included.
const maxWalked = 4 * topSize

// strokesRow and standingRow are a player's best or standing row; name is ""
// on the reads that resolve no names. A standing's par is its holes' pars
// summed: strokes - par is its score against par.
func strokesRow(p, name string, strokes int) string {
	return `{"player":` + jstr(p) + nameField(name) + `,"strokes":` + strconv.Itoa(strokes) + "}"
}

func standingRow(p, name string, r *row) string {
	return `{"player":` + jstr(p) + nameField(name) + standingFields(r) + "}"
}

// standingFields is a standing's numbers: holes, strokes and par.
func standingFields(r *row) string {
	return `,"holes":` + strconv.Itoa(r.holes) + `,"strokes":` + strconv.Itoa(r.strokes) + `,"par":` + strconv.Itoa(r.par)
}

func nameField(name string) string {
	if name == "" {
		return ""
	}
	return `,"name":` + jstr(name)
}

// Rank is a player's place in a mode's course ranking, with their standing:
// "rank" 1 is the top, out of "of"; 0 if unnamed or no current course hole
// finished. A name deleted since keeps its place until its next change, so a
// rank may be that many too low.
func Rank(mode string, player address) string {
	m := modeOf(mode)
	p := player.String()
	rank, r := 0, &row{}
	if v := totals[m].Get(p); v != nil {
		r = v.(*row)
		if key := rankKey(r); ranks[m].Has(key) {
			rank = ranks[m].index(key) + 1
		}
	}
	return "{" + versionJSON + `,"mode":` + jstr(modeNames[m]) + `,"player":` + jstr(p) +
		`,"rank":` + strconv.Itoa(rank) + `,"of":` + strconv.Itoa(ranks[m].Size()) + standingFields(r) + "}"
}

// CourseLeaderboard is a page of a mode's course ranking, paged like
// HoleLeaderboard. holes is the course's current holes, players how many the
// ranking holds.
func CourseLeaderboard(mode string, offset, limit int) string {
	m := modeOf(mode)
	limit = clampLimit(limit)
	size := ranks[m].Size()
	if offset < 0 {
		offset = 0
	}
	if offset > size {
		offset = size // and offset+limit cannot overflow
	}
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"mode":` + jstr(modeNames[m]) + `,"holes":` + strconv.Itoa(slots.Size()) +
		`,"players":` + strconv.Itoa(size) + `,"offset":` + strconv.Itoa(offset) + `,"rows":[`)
	n := 0
	ranks[m].IterateByOffset(offset, limit, func(_ string, v any) bool {
		p := v.(string)
		name := nameOf(p)
		if name == "" {
			return false // a name deleted since
		}
		sb.WriteString(sep(n) + standingRow(p, name, totals[m].Get(p).(*row)))
		n++
		return false
	})
	next := 0
	if offset+limit < size {
		next = offset + limit
	}
	sb.WriteString(`],"next":` + strconv.Itoa(next) + "}")
	return sb.String()
}

// Ghost is a player's best round on a hole in a mode, named or not, with its
// height (the first to a score ranks first), period and shots, or null: what a
// duel races. It replays in its own weather (SimulateRoundIn for the first
// stroke, then SimulateFrom from each rest).
func Ghost(hole, mode string, player address) string {
	e, m := readHole(hole), modeOf(mode)
	v := e.bests(m).Get(player.String())
	if v == nil {
		return "null"
	}
	strokes := bestStrokes(v)
	at, period, shots := bestFields(v)
	return "{" + versionJSON + `,"hole":` + jstr(e.id) + `,"mode":` + jstr(modeNames[m]) + `,"player":` + jstr(player.String()) +
		`,"height":` + strconv.FormatInt(at, 10) + `,"strokes":` + strconv.Itoa(strokes) + `,"period":` + strconv.FormatInt(period, 10) + `,"shots":` + jstr(shots) + "}"
}

// HoleRank is a player's place on a hole's board in a mode, with their best,
// as Rank: 0 if unnamed or no finish there.
func HoleRank(hole, mode string, player address) string {
	e, m := readHole(hole), modeOf(mode)
	p := player.String()
	v := e.bests(m).Get(p)
	rank, strokes := 0, bestStrokes(v)
	if strokes > 0 {
		if k := boardKey(v, p); e.board(m).Has(k) {
			rank = e.board(m).index(k) + 1
		}
	}
	return "{" + versionJSON + `,"hole":` + jstr(e.id) + `,"mode":` + jstr(modeNames[m]) + `,"player":` + jstr(p) +
		`,"rank":` + strconv.Itoa(rank) + `,"of":` + strconv.Itoa(e.board(m).Size()) + `,"strokes":` + strconv.Itoa(strokes) + "}"
}

// maxListed bounds Holes() and the hub: anyone can add a hole.
const maxListed = 120

// HoleLeaderboard is a page of a hole's board in a mode: named players' bests,
// fewest strokes then first there, from rank offset+1 (clamped to
// 0..players), at most limit rows (1..100). players is the named players,
// finished anyone who finished; next is the next offset, 0 at the end. A name
// deleted since is skipped, so a page may hold fewer rows. A page reads its
// own rows only.
func HoleLeaderboard(hole, mode string, offset, limit int) string {
	e, m := readHole(hole), modeOf(mode)
	limit = clampLimit(limit)
	board := e.board(m)
	size := board.Size()
	if offset < 0 {
		offset = 0
	}
	if offset > size {
		offset = size // and offset+limit cannot overflow
	}
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"hole":` + jstr(e.id) + `,"mode":` + jstr(modeNames[m]) +
		`,"par":` + strconv.Itoa(e.par) + `,"players":` + strconv.Itoa(size) + `,"finished":` + strconv.Itoa(e.bests(m).Size()) +
		`,"offset":` + strconv.Itoa(offset) + `,"rows":[`)
	n := 0
	board.IterateByOffset(offset, limit, func(k string, v any) bool {
		p := v.(string)
		name := nameOf(p)
		if name == "" {
			return false // a name deleted since
		}
		sb.WriteString(sep(n) + strokesRow(p, name, boardStrokes(k)))
		n++
		return false
	})
	next := 0
	if offset+limit < size {
		next = offset + limit
	}
	sb.WriteString(`],"next":` + strconv.Itoa(next) + "}")
	return sb.String()
}

// pageMax is the most rows one page of a read returns.
const pageMax = 100

// clampLimit keeps a page's size to 1..pageMax.
func clampLimit(n int) int {
	if n < 1 {
		return 1
	}
	if n > pageMax {
		return pageMax
	}
	return n
}

// maxFriends bounds the addresses one Bests or Standings read takes.
const maxFriends = 50

// friends splits a comma-separated list of addresses: each valid one once,
// at most maxFriends. Junk and repeats are skipped and use up nothing.
func friends(list string) []string {
	var out []string
	seen := map[string]bool{}
	for _, p := range strings.Split(list, ",") {
		if len(out) == maxFriends {
			break
		}
		if p = strings.TrimSpace(p); p != "" && !seen[p] && address(p).IsValid() {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}

// Bests is the best finished round on one hole, in a mode, of each of the
// given players (comma-separated addresses, named or not): a board of
// friends, where no stranger and no bot can push anyone off.
func Bests(hole, mode, players string) string {
	e, m := readHole(hole), modeOf(mode)
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"hole":` + jstr(e.id) + `,"mode":` + jstr(modeNames[m]) + `,"par":` + strconv.Itoa(e.par) + `,"rows":[`)
	n := 0
	for _, p := range friends(players) {
		if v := e.bests(m).Get(p); v != nil {
			sb.WriteString(sep(n) + strokesRow(p, "", bestStrokes(v)))
			n++
		}
	}
	sb.WriteString("]}")
	return sb.String()
}

// Standings is each given player's course-wide standing in a mode: how many
// of the course's current holes they finished, in how many strokes, and
// those holes' pars summed.
func Standings(mode, players string) string {
	m := modeOf(mode)
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"mode":` + jstr(modeNames[m]) + `,"holes":` + strconv.Itoa(slots.Size()) + `,"rows":[`)
	n := 0
	for _, p := range friends(players) {
		if v := totals[m].Get(p); v != nil {
			sb.WriteString(sep(n) + standingRow(p, "", v.(*row)))
			n++
		}
	}
	sb.WriteString("]}")
	return sb.String()
}

// Records is a page of every player's best on a hole in a mode, named or not,
// with the height that ranks it before a later tie: all a successor needs to
// carry the boards over in their order.
// The paged reads (Records, Players, Community) walk everything by
// key: after is the last key of the page before ("" for the first), limit is
// clamped to 1..100, next is the after of the next page ("" at the end).
func Records(hole, mode, after string, limit int) string {
	e, m := readHole(hole), modeOf(mode)
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"hole":` + jstr(e.id) + `,"mode":` + jstr(modeNames[m]) + `,"rows":[`)
	next := page(e.bests(m).Iterate, after, limit, func(i int, p string, v any) {
		at, _, _ := bestFields(v)
		sb.WriteString(sep(i) + `{"player":` + jstr(p) + `,"strokes":` + strconv.Itoa(bestStrokes(v)) + `,"height":` + strconv.FormatInt(at, 10) + "}")
	})
	sb.WriteString(`],"next":` + jstr(next) + "}")
	return sb.String()
}

// Players is a page of every course standing in a mode, named or not: its
// holes, strokes and par (all the ranking's key reads) and the height of the
// finish that last improved it (the tie-break), paged like Records.
func Players(mode, after string, limit int) string {
	m := modeOf(mode)
	var sb strings.Builder
	sb.WriteString("{" + versionJSON + `,"mode":` + jstr(modeNames[m]) + `,"rows":[`)
	next := page(totals[m].Iterate, after, limit, func(i int, p string, v any) {
		r := v.(*row)
		sb.WriteString(sep(i) + `{"player":` + jstr(p) + standingFields(r) + `,"height":` + strconv.FormatInt(r.height, 10) + "}")
	})
	sb.WriteString(`],"next":` + jstr(next) + "}")
	return sb.String()
}

// walk is a tree's Iterate: what page reads.
type walk func(start, end string, cb func(key string, v any) bool) bool

func bpWalk(t *bptree.BPTree) walk {
	return func(start, end string, cb func(string, any) bool) bool { return t.Iterate(start, end, cb) }
}

// page walks up to limit entries of t after the key after, and returns the
// key to continue from, "" at the end.
func page(t walk, after string, limit int, fn func(i int, key string, v any)) string {
	limit = clampLimit(limit)
	start := ""
	if after != "" {
		start = after + "\x00" // the first key past after
	}
	n, next, last := 0, "", ""
	t(start, "", func(k string, v any) bool {
		if n == limit {
			next = last
			return true
		}
		fn(n, k, v)
		last = k
		n++
		return false
	})
	return next
}
