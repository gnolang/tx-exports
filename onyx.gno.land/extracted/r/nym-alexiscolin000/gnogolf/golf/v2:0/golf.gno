// Package golf is the game realm: it keeps the holes, the players' rounds,
// the records and the rankings. Every hole is data (a GG1 string, p/…/course),
// never code: golf decodes it and plays it with p/…/physics. The owner
// publishes the course's holes into slots of a cup ("garden/7"), each publish
// a new version ("garden/7/v2"); once the owner opens publishing, anyone can
// publish a community hole ("<address>/<slug>/v1", PublishMine), playable and
// recorded but outside the course and its ranking.
//
// Reads take a version's id or its alias ("garden/7", "<address>/<slug>"),
// its current version. Writes take the exact id only, as HoleState or Holes gave
// it: a round cannot be replayed on a version it was not played on.
//
// Who can change what (in full on the hub page): the owner holds one power,
// the course itself: its holes (Publish), what the lists show (Hide), and
// whether anyone can publish (SetPublishing).
package golf

import (
	"chain"
	"chain/runtime"
	"math"
	"strconv"
	"strings"
	"unicode"

	"gno.land/p/nym-alexiscolin000/gnogolf/course"
	"gno.land/p/nym-alexiscolin000/gnogolf/physics"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/sys/users"
)

const (
	maxPower = 10.0
	// maxShots bounds a commit; its work (workBudget) may bound it lower.
	maxShots = 12
)

// The refusals said in more than one place.
const (
	errShot         = "golf: a shot is an angle and a power between 0 and 10"
	errFine         = "golf: a shot's angle and power go in steps of 0.01, as the game sends them"
	errStrokeLimit  = "golf: this round is over its stroke limit, Reset to play again"
	errShotTooHeavy = "golf: one shot on this hole could cost more than a transaction can replay"
	errTooStormy    = "golf: in its dearest weather, a commit on this hole would leave too little room for a shot"
	errUnknownHole  = "golf: unknown hole: "
)

type entry struct {
	id    string // "<alias>/v<n>"
	name  string // the hole's name, cleaned; frozen when it was published
	par   int    // frozen like the name
	world string // "garden", "island", "town": frozen too
	order float64
	// official: a version the owner published into a slot; only these rank
	official bool
	// its provenance, set at publish (the hole itself is never stored: hole())
	slot    string  // the alias it answers to: "garden/7", "<address>/<slug>"
	version int     // its number under that alias, from 1
	by      address // who published it
	height  int64
	sha     string // sha256 of its data, hex
	note    string
	// Its rounds, bests, board and wear are rows of store's shared collections
	// (views), not trees of its own, whose first leaf (a few KB) its first
	// player would pay.
	plays int
	// the records per mode (rec), flat: a nested object costs a few hundred
	// bytes more
	best, proBest     int
	bestBy, proBestBy address
	next              string // the version that took this one's place, "" while it is current
	// its drain once archived (drain); nil if never archived
	out *draining
}

// The versions: the course's, current and archived, and everyone else's: id -> encodeEntry.
var (
	courseHoles = view{"holes", ""}
	community   = view{"community", ""}
)

// saveEntry keeps a version as it is now: every call that changes one ends with it.
func saveEntry(e *entry) {
	if seen != nil {
		seen[e.id] = e
	}
	if e.official {
		courseHoles.Set(e.id, encodeEntry(e))
	} else {
		community.Set(e.id, encodeEntry(e))
	}
}

// record is the hole's record in one mode: who holds it, in how many
// strokes, 0 if never completed.
type record struct {
	by   address
	best int
}

// rec is the entry's record in mode m.
func (e *entry) rec(m int) record {
	if m == pro {
		return record{e.proBestBy, e.proBest}
	}
	return record{e.bestBy, e.best}
}

// roundTree is the version's rounds under way: player address -> *round. A
// round is stored from its first commit that does not finish it, and removed
// as it is holed (stroke) or Reset: a finish is kept as a best, not a round.
func (e *entry) roundTree() view { return view{"rounds", e.id + " "} }

// bests is the version's results in mode m: player address -> their best
// finished round there, kept across replays, as bestOf writes it.
func (e *entry) bests(m int) view { return bestsOf(e.id, m) }

func bestsOf(id string, m int) view { return view{"bests", id + " " + modeNames[m] + " "} }

// bestOf is how a best is kept: "<strokes> <height> <period> <shots>". The
// height ranks it before a later tie (boardKey); the period and shots let
// Ghost replay it in its own weather. The mode is in the key.
func bestOf(r *round) string {
	return strconv.Itoa(r.strokes) + " " + strconv.FormatInt(runtime.ChainHeight(), 10) + " " +
		strconv.FormatInt(r.period, 10) + " " + r.shots
}

// errBest is a best not as bestOf writes it: never written, refused if read.
const errBest = "golf: a best not as bestOf writes it: "

// bestStrokes is a kept best's strokes, 0 for none ("").
func bestStrokes(s string) int {
	if s == "" {
		return 0
	}
	i := strings.Index(s, " ")
	if i < 0 {
		panic(errBest + s)
	}
	n, err := strconv.Atoi(s[:i])
	if err != nil {
		panic(errBest + s)
	}
	return n
}

// bestFields is a kept best's height, period and shots.
func bestFields(s string) (int64, int64, string) {
	f := strings.SplitN(s, " ", 4)
	if len(f) < 4 {
		panic(errBest + s)
	}
	at, err := strconv.ParseInt(f[1], 10, 64)
	period, err2 := strconv.ParseInt(f[2], 10, 64)
	if err != nil || err2 != nil {
		panic(errBest + s)
	}
	return at, period, f[3]
}

// board is the version's board in mode m: boardKey(best, player) ->
// player, the named players' bests, fewest strokes first.
func (e *entry) board(m int) view { return view{"boards", e.id + " " + modeNames[m] + " "} }

func newEntry(id, name string, par int, world string, order float64) *entry {
	return &entry{id: id, name: name, par: par, world: world, order: order}
}

// hole is the entry's hole, decoded from its data for this call only: a
// public call decodes it once and passes it down, and it is never stored.
func (e *entry) hole() *course.Simple {
	data, _ := holeData.Get(e.id)
	s, err := course.Decode(data)
	if err != nil {
		panic("golf: the data of " + e.id + " does not decode: " + err.Error()) // checked at publish: cannot happen
	}
	return s
}

// draining is an archived hole's drain, per mode: the next player to take
// out, and whether all are out. The players whose first finish came after it
// was archived (never counted, so never taken out) are its fresh rows.
type draining struct {
	from [modes]string
	done [modes]bool
}

// copies is a version's bests sent again from another's (copyOf): player -> "1",
// kept, never ranked (no board row, no standing, no drain to take them out).
func (e *entry) copies(m int) view { return copiesOf(e.id, m) }

func copiesOf(id string, m int) view { return view{"copies", id + " " + modeNames[m] + " "} }

// How near a round must be to a record already on the board, shot for shot,
// to be that record sent again: a player's pull never lands this close to
// another's, three shots running.
const (
	copyAngle = 0.05 // degrees, round the circle
	copyPower = 0.02
	copyMin   = 3    // shots: two people keying a short round send alike
	copyDepth = 10   // the board's first page: the records worth copying
)

// copyOf reports whether shots are a record of a board's first page (either
// mode's: the modes differ by the client's aim line alone, so a round replays
// the same in both; another player's) sent again: as many shots, each within
// copyAngle and copyPower, three shots or more, one of them pulled (not keyed:
// a whole degree, or a power on 0.5, the keyboard's and a typed form's). The
// tick is not compared: on most holes it changes nothing, and on a timed one
// another tick of the same beat plays the same.
func copyOf(e *entry, p, shots string) bool {
	mine := strings.Split(shots, ";")
	if len(mine) < copyMin {
		return false
	}
	pulled := false
	for _, s := range mine {
		if a, pw, _ := parseShot(s); !keyed(a, pw) {
			pulled = true
		}
	}
	if !pulled {
		return false
	}
	for m := 0; m < modes; m++ {
		n, found := 0, false
		e.board(m).Iterate("", "", func(_, q string) bool {
			if q == p {
				return false
			}
			_, _, theirs := bestFields(bestOfPlayer(e, m, q))
			found = alike(mine, strings.Split(theirs, ";"))
			n++
			return found || n == copyDepth
		})
		if found {
			return true
		}
	}
	return false
}

// keyed is a shot a keyboard or a form sends: a whole degree, or a power on 0.5.
func keyed(a, p float64) bool {
	return math.Abs(a-math.Round(a)) < 1e-6 || math.Abs(p*2-math.Round(p*2)) < 1e-6
}

func alike(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		x, px, _ := parseShot(a[i])
		y, py, _ := parseShot(b[i])
		d := math.Mod(math.Abs(x-y), 360) // round the circle: angles are kept in (-360, 360)
		if d > 180 {
			d = 360 - d
		}
		if d > copyAngle+1e-9 || math.Abs(px-py) > copyPower+1e-9 {
			return false
		}
	}
	return true
}

// fresh is an archived version's first finishes the drain has yet to reach: player -> "1".
func (e *entry) fresh(m int) view { return view{"fresh", e.id + " " + modeNames[m] + " "} }

type round struct {
	bx, by  float64 // the ball, exactly: flat, not a nested Vec2 object
	fx, fy  float64 // where the last stroke started: its path is replayed from there
	strokes int
	period  int64  // the weather it is played in: set by its first stroke
	shots   string // the decisions so far, "angle,power,tick;…": the round, replayable
	mode    int    // assisted or pro: set by its first stroke, like the weather
}

func (r *round) ball() physics.Vec2 { return physics.Vec2{X: r.bx, Y: r.by} }

// A round is played in one of two modes, each with its own records and
// rankings: assisted (the full aim preview) or pro (the preview cut short).
// The chain cannot see a screen: the mode is the player's word.
const (
	assisted = iota
	pro
	modes
)

// modeOf reads a mode's name: "assisted" (or "") or "pro"; anything else
// panics rather than answer for another mode.
func modeOf(name string) int {
	switch name {
	case "", "assisted":
		return assisted
	case "pro":
		return pro
	}
	panic(`golf: a mode is "assisted" or "pro", got: ` + name)
}

var modeNames = [modes]string{"assisted", "pro"}

// modeTitles is how the pages head a mode's board.
var modeTitles = [modes]string{"Assisted", "Pro"}

// The indexes: collections of store (kv.gno), shared by every version and
// mode, made at its deploy: a first player pays for their own rows only.
var (
	// id -> a version's GG1 string, apart from its entry so that listing
	// holes never loads it
	holeData = view{"data", ""}
	// slotKey(world, order) -> id of the current version there, in course order
	slots = view{"slots", ""}
	// "<address>/<slug>" -> id of the current version of a community hole
	aliases = view{"aliases", ""}
	// the listed community holes, two kinds of row in one collection:
	//   - "<address> " + recentKey(publish height, slug) -> id: an author's
	//     holes not hidden, newest last;
	//   - recentKey(their newest row's height, address) -> "": one per
	//     author (moveAuthor), the latest to publish last.
	// A height is digits and an address "g1…": the two never mix.
	byAuthor = view{"authors", ""}
	// "<address>/<slug>" -> "1": community holes hidden (Hide), every
	// version, out of byAuthor; still playable
	hidden = view{"hidden", ""}
	// recentKey(archive height, id) -> id of an archived course version
	archived = view{"archived", ""}
	// per mode: player -> encodeRow, their standing over the official holes
	totals = [modes]view{{"totals", "assisted "}, {"totals", "pro "}}
	// per mode: rankKey(row) -> player, the named players with a hole, best
	// first
	ranks = [modes]view{{"ranks", "assisted "}, {"ranks", "pro "}}
	// per mode: rankKey(row) -> player, standings with no hole left (setRow)
	idle = [modes]view{{"ranks", "idle assisted "}, {"ranks", "idle pro "}}
	// golf's own settings and the archived holes still draining: meta
	meta = view{"meta", ""}
)

// archiving is the archived holes still in the standings, oldest first (drain).
func archiving() []string {
	v, _ := meta.Get("archiving")
	if v == "" {
		return nil
	}
	return strings.Split(v, " ")
}

func setArchiving(ids []string) { meta.Set("archiving", strings.Join(ids, " ")) }

// row is one player's standing across the course: their best on each hole
// counted, summed, and those holes' pars, summed. Its score against par,
// strokes - par, is what ranks it after its holes.
type row struct {
	player              string
	holes, strokes, par int
	height              int64 // of the finish that last improved it: the first there ranks first
}

const topSize = 10

// named reports whether a player has a gno.land name (r/sys/users). Only
// named players rank: a name takes a registration, so a script cannot fill
// the boards with free addresses. Every finish is still kept.
func named(player string) bool {
	return !users.ResolveAddress(address(player)).IsDeleted()
}

// nameOf is a named player's name, "" for anyone else.
func nameOf(player string) string {
	if u := users.ResolveAddress(address(player)); !u.IsDeleted() && nameish(u.Name()) {
		return u.Name()
	}
	return ""
}

// nameish is a name as r/sys/users registers it (a-z, then a-z, 0-9, "_" and
// "-", at most 64), checked again because the pages print names in links.
func nameish(n string) bool {
	if n == "" || len(n) > 64 || n[0] < 'a' || n[0] > 'z' {
		return false
	}
	for i := 0; i < len(n); i++ {
		if c := n[i]; !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// find is the hole with this exact id, nil if none.
// Within a call that writes (begin), a version is one object, however often
// it is found: a finish on an archived hole and the drain it runs change the
// same one, and the call keeps it once as it ends (flush forgets them all).
// A read caches nothing: called within another realm's transaction, it would
// keep its cache in this realm's state, stale once the rules change.
func find(id string) *entry {
	if e := seen[id]; e != nil {
		return e
	}
	v, ok := courseHoles.Get(id)
	if !ok {
		if v, ok = community.Get(id); !ok {
			return nil
		}
	}
	e := decodeEntry(v)
	if seen != nil {
		seen[id] = e
	}
	return e
}

// current is the id an alias points at now: a course slot's or a community
// hole's current version; "" if it is neither.
func current(alias string) string {
	if k, ok := slotKeyOf(alias); ok {
		v, _ := slots.Get(k)
		return v
	}
	v, _ := aliases.Get(alias)
	return v
}

// mustHole is the hole a write names: its exact id. An alias is refused: a
// new version may have taken its place since the round's shots were chosen.
func mustHole(id string) *entry {
	if e := find(id); e != nil {
		return e
	}
	if now := current(id); now != "" {
		panic("golf: " + id + " is an alias: play its version by id, " + now)
	}
	panic(errUnknownHole + id)
}

// readHole is the hole a read names: an exact id, or an alias for its
// current version.
func readHole(id string) *entry {
	if e := find(id); e != nil {
		return e
	}
	if now := current(id); now != "" {
		return find(now)
	}
	panic(errUnknownHole + id)
}

// recentKey orders by height, then by what is at that height.
func recentKey(height int64, what string) string { return pad(int(height), 12) + " " + what }

// pad writes n in width digits, zeros first: keys that sort as numbers.
func pad(n, width int) string {
	s := strconv.Itoa(n)
	for len(s) < width {
		s = "0" + s
	}
	return s
}

// rankKey orders the course ranking: most holes first, then the best score
// against par (a hole at par counts the same whatever its par), then the
// first there, then the address. The score is signed: vsParBias puts it in
// seven digits. The holes take five: a standing can count more than the
// course's slots while a republished hole drains (its old best still counts,
// its new one adds a hole), so they get room well past maxCourse.
func rankKey(r *row) string {
	return pad(99999-r.holes, 5) + "/" + pad(vsParBias+r.strokes-r.par, 7) + "/" + pad(int(r.height), 12) + "/" + r.player
}

// maxCourse bounds the course's slots (Publish); a standing's holes are at
// most those plus the archived versions drain has not taken it out of yet.
// vsParBias is more than a standing can be under or over par: a hole is -18
// to +59 (1 to 60 strokes, par 1 to 19), so a full course at most 9999 * 59 =
// 589,941 over, 179,982 under, and the seven digits hold 55,555 holes.
const (
	maxCourse = 9999
	vsParBias = 1000000
)

// boardKey orders a hole's board by each player's best v: fewest strokes,
// then the first to make them (a best's shots are public: whoever replays
// them ties it and ranks after), then the address.
func boardKey(v string, player string) string {
	at, _, _ := bestFields(v)
	return pad(bestStrokes(v), 3) + "/" + pad(int(at), 12) + "/" + player
}

// boardStrokes is the strokes of a board's key: always its three digits.
func boardStrokes(k string) int {
	n, err := strconv.Atoi(k[:3])
	if err != nil {
		panic("golf: bad board key: " + k) // pad writes three digits: cannot happen
	}
	return n
}

// setRow moves a player's standing, as of height at, and keeps the ranking
// in step (and the standing itself). A standing with no hole left is not
// freed, nor its key, which moves to idle: its deposit is the player's, and
// freeing it would refund whoever drained it. It moves back at the player's
// next hole.
func setRow(m int, r *row, n, strokes, par int, at int64) {
	k := rankKey(r)
	had := ranks[m].Remove(k)
	if idle[m].Remove(k) {
		had = true
	}
	r.holes, r.strokes, r.par, r.height = n, strokes, par, at
	totals[m].Set(r.player, encodeRow(r))
	switch {
	case r.holes > 0 && named(r.player):
		ranks[m].Set(rankKey(r), r.player)
	case had:
		idle[m].Set(rankKey(r), r.player)
	}
}

// improve moves a player's standing by a new best on an official hole of par
// par (was: their old best there, 0 if none): only those count, or anyone's
// own hole would be a way to the top. The standing is kept, not recomputed,
// so a finish costs the same however many play.
func improve(m int, player string, par, was, best int) {
	r := &row{player: player}
	if v, ok := totals[m].Get(player); ok {
		r = decodeRow(v)
	}
	if was == 0 {
		setRow(m, r, r.holes+1, r.strokes+best, r.par+par, runtime.ChainHeight())
	} else {
		setRow(m, r, r.holes, r.strokes+best-was, r.par, runtime.ChainHeight())
	}
}

// retire archives an official hole replaced by next. Its bests stay there as
// its records but leave the course standings, in batches (drain): the Publish
// takes retireBatch, each course finish finishBatch, a Drain up to drainMax.
func retire(old *entry, next string) {
	old.next, old.out = next, &draining{}
	saveEntry(old)
	archived.Set(recentKey(runtime.ChainHeight(), old.id), old.id)
	setArchiving(append(archiving(), old.id))
	chain.Emit(EventHoleRetired, "hole", old.id, "next", next)
	drain(retireBatch)
}

// How many archived players a Publish, a course finish and a Drain take out
// of the standings: sized so none costs more however many played.
const (
	retireBatch = 150
	finishBatch = 4
	drainMax    = 400
)

// drain takes up to n archived players out of the standings, oldest
// archived hole first.
func drain(n int) {
	list := archiving()
	if len(list) == 0 {
		return
	}
	for n > 0 && len(list) > 0 {
		e := find(list[0])
		d := e.out
		for m := 0; m < modes && n > 0; m++ {
			if d.done[m] {
				continue
			}
			stopped := e.bests(m).Iterate(d.from[m], "", func(p string, v string) bool {
				if n == 0 {
					d.from[m] = p
					return true
				}
				if !e.fresh(m).Has(p) && !e.copies(m).Has(p) { // (neither ever counted)
					if t, ok := totals[m].Get(p); ok {
						r := decodeRow(t)
						setRow(m, r, r.holes-1, r.strokes-bestStrokes(v), r.par-e.par, r.height)
					}
				}
				n--
				return false
			})
			if !stopped {
				d.done[m] = true
			}
		}
		saveEntry(e)
		if d.done[assisted] && d.done[pro] {
			list = list[1:]
		}
	}
	setArchiving(list)
}

// Drain takes up to n players (1 to 400) of archived holes out of the course
// standings, sooner than the finishes would, and returns how many archived
// holes still have players in them. Anyone can call it. A standing it
// empties is kept at 0 holes (setRow): nothing is refunded to the caller.
func Drain(cur realm, n int) int {
	begin()
	if n < 1 {
		n = 1
	}
	if n > drainMax {
		n = drainMax
	}
	drain(n)
	flush(cur)
	return len(archiving())
}

// counts reports whether a best on e by player (was: their previous best, 0
// if none) moves their standing: e is a current official hole, or an archived
// one whose drain has not reached them yet and where they already counted. A
// first finish on an archived hole never counts.
func counts(e *entry, m int, player string, was int) bool {
	if !e.official {
		return false
	}
	if e.next == "" {
		return true
	}
	if was == 0 || e.out.done[m] || player < e.out.from[m] {
		return false
	}
	return !e.fresh(m).Has(player)
}

// Launch plays one shot of the caller's round on hole (an exact id): angle in
// degrees (0 = right, 90 = down), power in (0, 10]. It is how gnoweb plays,
// with no aim preview, so its rounds are pro rounds. It answers with where
// the ball stopped, or the score if holed; PlayRoundAt commits many shots.
func Launch(cur realm, hole string, angle, power float64) string {
	begin()
	r := launchNow(cur, hole, angle, power)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func launchNow(cur realm, hole string, angle, power float64) string {
	e := mustHole(hole)
	h := e.hole()
	player := cur.Previous().Address()
	r := roundOf(e, h, player)
	fresh := r.strokes == 0
	if fresh {
		r.period = Period() // a round starts in the weather of the moment, and keeps it
		r.mode = pro
	} else if r.mode != pro {
		panic(otherMode(r))
	}

	fc := weatherOf(e, h, r.period)
	w := newWork(h, fc.Zones)
	w.fixed = fixedGas(e, fc)
	w.next(h)
	shot, holed := stroke(e, h, r, player, angle, power, 0, fc.Zones)
	w.add(shot)
	saveEntry(e)
	if holed {
		return ufmt.Sprintf("Holed in %d on %s! Your best there: %s:%s/%s", r.strokes, e.id, hub, e.id, player.String())
	}
	e.roundTree().Set(player.String(), encodeRound(r)) // (under way: kept as it stands now)
	// what a gnoweb player needs for the next shot
	a, d := aim(r.ball(), h.Cup())
	return ufmt.Sprintf("Stroke %d on %s: the ball stopped %.1f from the cup, which is at %.0f° from it. Your round: %s:%s/%s",
		r.strokes, e.id, d, a, hub, e.id, player.String())
}

// aim is the angle, in the shot's degrees, and the straight-line distance
// from a ball to the cup: walls and slopes are the player's to allow for.
func aim(from, cup physics.Vec2) (float64, float64) {
	d := cup.Sub(from)
	a := math.Atan2(d.Y, d.X) * 180 / math.Pi
	if a < 0 {
		a += 360
	}
	return a, d.Len()
}

// PlayRound is PlayRoundAt in the current period, for a caller with none to
// give (a form, a script); a round under way keeps its own. Prefer
// PlayRoundAt: a commit included after the weather turned is then played in
// the weather its shots were chosen in.
func PlayRound(cur realm, hole string, shots string) string {
	begin()
	r := playRoundNow(cur, hole, shots)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func playRoundNow(cur realm, hole string, shots string) string {
	e, p := mustHole(hole), cur.Previous().Address()
	period := Period()
	if v, ok := e.roundTree().Get(p.String()); ok { // (a round is kept from its first stroke on)
		period = decodeRound(v).period // stroke() still refuses a stale one
	}
	return playRound(e, p, shots, period, assisted)
}

// PlayRoundAt replays shots into the caller's assisted round on hole (an
// exact id), continuing it, in the weather of period: the current one or the
// one before, and a round under way keeps its own. The client sends
// decisions, never outcomes: the chain replays them.
//
// shots is "angle,power[,tick];…" (MsgCall carries no slice), at most 12,
// fewer on a heavy hole: a commit past the work budget is refused with the
// number of shots that fit, and the rest goes in the next commit.
func PlayRoundAt(cur realm, hole string, shots string, period int64) string {
	begin()
	r := playRoundAtNow(cur, hole, shots, period)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func playRoundAtNow(cur realm, hole string, shots string, period int64) string {
	return playRound(mustHole(hole), cur.Previous().Address(), shots, period, assisted)
}

// PlayRoundPro is PlayRoundAt for a round played in pro mode: the aim
// preview cut short. It counts on the pro records and rankings only.
func PlayRoundPro(cur realm, hole string, shots string, period int64) string {
	begin()
	r := playRoundProNow(cur, hole, shots, period)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func playRoundProNow(cur realm, hole string, shots string, period int64) string {
	return playRound(mustHole(hole), cur.Previous().Address(), shots, period, pro)
}

func playRound(e *entry, player address, shots string, period int64, mode int) string {
	h := e.hole()
	r := roundOf(e, h, player)
	if r.strokes == 0 {
		playablePeriod(period)
		r.period, r.mode = period, mode
	} else if r.period != period {
		panic(ufmt.Sprintf("golf: this round is being played in the weather of period %d", r.period))
	} else if r.mode != mode {
		panic(otherMode(r))
	}

	list := shotList(shots)
	fc := weatherOf(e, h, r.period) // once for the whole commit
	weather := fc.Zones
	w := newWork(h, weather)
	w.fixed = fixedGas(e, fc)
	for _, s := range list {
		w.next(h)
		angle, power, tick := parseShot(s)
		shot, holed := stroke(e, h, r, player, angle, power, tick, weather)
		w.add(shot)
		if holed {
			saveEntry(e)
			return ufmt.Sprintf("holed in %d strokes", r.strokes)
		}
	}
	saveEntry(e)
	e.roundTree().Set(player.String(), encodeRound(r)) // under way: kept as it stands now
	return ufmt.Sprintf("%d shots replayed, ball at %.1f,%.1f after %d strokes",
		w.played, r.bx, r.by, r.strokes)
}

// otherMode refuses to go on with a round in a mode it was not started in.
func otherMode(r *round) string {
	return "golf: this round is being played in " + modeNames[r.mode] + " mode"
}

// shotList is a commit's shots: the non-empty entries of "a,p;a,p;…", at
// least one and at most maxShots.
func shotList(shots string) []string {
	var list []string
	for _, s := range strings.Split(shots, ";") {
		if s = strings.TrimSpace(s); s == "" {
			continue
		}
		if len(list) == maxShots {
			panic("golf: too many shots in one commit")
		}
		list = append(list, s)
	}
	if len(list) == 0 {
		panic("golf: no shots")
	}
	return list
}

// work is a commit's estimated gas so far. A shot counts the larger of its
// path's estimate and its Shot.Work's, plus its pulses' set-up, on top of
// what the commit spent before its shots (fixed: decoding, forecast). A shot
// that could pass workBudget is refused before anything is kept, and each is
// played under a work cap (physics.Field.Cap), so no commit can pass it; the
// client mirrors the model. An estimate, not a gas meter: see docs/golf.md,
// "The work budget".
type work struct {
	walls, pieces int64 // on the board this commit: walls, and every piece and polygon edge
	setup         int64 // what each shot spends outside its Shot.Work: a pulse's pieces, set up afresh
	bound         int64 // shotBound, and the set-up
	fixed         int64 // spent before the shots: decoding, forecast
	spent, most   int64
	played        int
	cap           int // the work cap of the shot being played
}

// The budget: of the 2e9 gas a wallet lets a transaction simulate, 1.4e9 for
// a commit, decoding and forecast included; the rest for package loads and
// bookkeeping.
const (
	workBudget   = 1400000000
	workPerShot  = 10000000
	workPerWall  = 150000
	workPerPoint = 1200000
	workPerPiece = 15000
	workPerUnit  = 1000
	// a pulse's walls and posts, set up afresh for each shot outside its
	// Shot.Work
	workPerPulseWall = 700000
	workPerPulsePost = 200000
)

// Decoding a hole's data costs at most decodeBase and decodePerByte a byte.
const (
	decodeBase    = 6000000
	decodePerByte = 4000
)

// fixedGas is what a commit on e spends before its shots, in the forecast
// fc: decoding the hole, and drawing the forecast.
func fixedGas(e *entry, fc course.Forecast) int64 {
	data, _ := holeData.Get(e.id)
	return decodeGas(len(data)) + int64(fc.Work)*workPerUnit + storeGas
}

// storeGas is what a commit spends keeping its rows in store, on top of v1's
// work: reading the hole, its version and the round across the realm,
// decoding them, and its writes in one batch. Measured at 20.6M on the
// heaviest commit that does not finish (z_worst_play_filetest, against v1's):
// 25M, counted before the shots and at publish (worstGas). A finish spends
// some 30M to 40M more there (its best, the board, the standing, the drain's
// share), outside the work budget, as v1's finish was: the room between the
// budget and what a transaction may ask covers it.
const storeGas = 25000000

// decodeGas bounds decoding size bytes of a hole's data.
func decodeGas(size int) int64 { return decodeBase + decodePerByte*int64(size) }

// maxShotGas bounds a hole's heaviest shot (shotBound and its pulses'
// set-up): a hole past it is refused at publish.
const maxShotGas = 1300000000

// minShotWork is the work, in the physics' units, a commit's first shot may
// always do whatever the weather: four fifths of MaxWork. A shot is capped at
// what is left of the budget (work.next), so a hole whose dearest weather
// would leave less is refused at publish (worstGas): on a published hole,
// every shot of less than minShotWork plays out in any weather (as a commit's
// first, if need be), and an author whose board is too heavy is told at
// publish, not by a hole that misbehaves in the rain. A shot past it may be
// cut short; none is known: the course's heaviest real shot does 441,737
// over the full grid of tee shots (mountain/16, full power, in a storm), and
// the heaviest found in an adversarial search 0.74 of MaxWork (docs/golf.md);
// the course's tightest room in its dearest weather is 839,278 (mountain/7),
// 39,278 over the floor.
const minShotWork = 4 * physics.MaxWork / 5

// worstGas is what a commit on h (size bytes of data) spends up to a first
// shot of minShotWork in its dearest weather: decoding, the forecast at its
// most (course.WorstForecastWork), and the shot, its walls and its pulses'
// set-up, as work.next caps it.
func worstGas(h *course.Simple, size int) int64 {
	w := newWork(h, nil)
	return decodeGas(size) + storeGas + int64(course.WorstForecastWork(h))*workPerUnit +
		workPerShot + w.walls*workPerWall + w.setup + (physics.MaxWorkStep+minShotWork)*workPerUnit
}

// newWork is a commit's work on a hole, before any shot: its walls and
// pieces, a pulse's as if always there, and the weather's.
func newWork(h *course.Simple, weather []physics.Zone) *work {
	w := &work{}
	if f := h.Field(); f != nil {
		w.walls = int64(len(f.Walls))
		w.pieces = pieces(f.Walls, f.Posts, f.Zones)
	}
	for _, p := range h.Pulses {
		w.walls += int64(len(p.Walls))
		w.pieces += pieces(p.Walls, p.Posts, p.Zones)
		w.setup += int64(len(p.Walls))*workPerPulseWall + int64(len(p.Posts))*workPerPulsePost
	}
	w.pieces += pieces(nil, nil, weather)
	w.bound = shotBound(w.walls) + w.setup
	return w
}

// shotBound is the most one shot on a board of walls walls can cost: the
// physics ends a stroke at MaxWork, passing it by MaxWorkStep at most.
func shotBound(walls int64) int64 {
	return workPerShot + walls*workPerWall + (physics.MaxWork+physics.MaxWorkStep)*workPerUnit
}

// pieces counts what a ball is tested against: each wall, post and zone, and
// each edge of a zone's polygon.
func pieces(ws []physics.Wall, ps []physics.Post, zs []physics.Zone) int64 {
	n := len(ws) + len(ps) + len(zs)
	for i := range zs {
		n += len(zs[i].Poly)
	}
	return int64(n)
}

// next refuses the next shot if it could overrun the budget, and caps its
// work at what is left of it.
func (w *work) next(h *course.Simple) {
	if w.played == 0 && w.bound > workBudget {
		w.refuse()
	}
	if w.played > 0 && w.spent+w.most > workBudget {
		w.refuse()
	}
	c := (workBudget-w.fixed-w.spent-workPerShot-w.walls*workPerWall)/workPerUnit - physics.MaxWorkStep
	c -= w.setup / workPerUnit
	if c < 1 {
		w.refuse()
	}
	if c > physics.MaxWork {
		c = physics.MaxWork
	}
	w.cap = int(c)
	if f := h.Field(); f != nil {
		f.Cap = w.cap // the decoded hole of this call only: never stored
	}
}

// refuse refuses the shot being played: it does not fit the budget.
func (w *work) refuse() {
	if w.played == 0 {
		panic(errShotTooHeavy)
	}
	panic(ufmt.Sprintf("golf: more shots than one transaction can replay on this hole: commit the first %d, then the rest", w.played))
}

func (w *work) add(s physics.Shot) {
	if w.cap < physics.MaxWork && s.Work > w.cap {
		w.refuse() // it reached its cap: it would have gone further
	}
	c := workPerShot + w.walls*workPerWall + int64(len(s.Path))*(workPerPoint+w.pieces*workPerPiece)
	if u := workPerShot + w.walls*workPerWall + int64(s.Work)*workPerUnit; u > c {
		c = u // a shot that did more than its path shows
	}
	c += w.setup
	w.spent += c
	if c > w.most {
		w.most = c
	}
	w.played++
}

// Reset abandons the caller's round under way on hole (an exact id), freeing
// its storage: the next stroke starts a new one from the tee. A finished round
// is not kept (its best is), so a new one needs no Reset. With no round under
// way it does nothing, and says nothing.
func Reset(cur realm, hole string) {
	begin()
	resetNow(cur, hole)
	flush(cur) // (only once it went through: a refusal writes nothing)
}

func resetNow(cur realm, hole string) {
	e := mustHole(hole)
	player := cur.Previous().Address().String()
	if e.roundTree().Remove(player) {
		chain.Emit(EventRoundReset, "hole", e.id, "player", player)
	}
}

// validShot refuses what would poison a round, and what the game cannot
// send (a step finer than 0.01), and returns the shot as recorded. NaN and infinities pass every comparison, so they are refused by
// name. The power is quantized before it is checked (0.00001 would round to
// 0). The angle is brought into (-360, 360), so a huge one cannot overflow to
// NaN in the physics, and again after rounding (-359.99996 is -0, not -360).
func validShot(angle, power float64) (float64, float64) {
	power = q4(power)
	if math.IsNaN(angle) || math.IsInf(angle, 0) || !(power > 0 && power <= maxPower) {
		panic(errShot)
	}
	angle = q4(math.Mod(angle, 360))
	if angle <= -360 || angle >= 360 {
		angle = math.Mod(angle, 360)
	}
	// finer than the game's own steps: a solver's precision (a knife-edge
	// shot), never a player's pull, nor its gnokey command's
	if !cents(angle) || !cents(power) {
		panic(errFine)
	}
	return angle, power
}

// cents reports whether x is a whole number of hundredths (as q4 left it).
func cents(x float64) bool { return math.Abs(x*100-math.Round(x*100)) < 1e-6 }

// resolve checks what the physics returned for a stroke: a path a read may
// print, and a ball that is a number. A hole is anyone's data.
func resolve(shot physics.Shot, holed bool) (physics.Shot, bool) {
	if len(shot.Path) > maxPath {
		panic("golf: the hole returned an oversized path")
	}
	rest := shot.Rest()
	if math.IsNaN(rest.X) || math.IsNaN(rest.Y) || math.IsInf(rest.X, 0) || math.IsInf(rest.Y, 0) {
		panic("golf: the hole returned a ball off the board")
	}
	return shot, holed
}

// back brings a ball that came to rest off the board (a leak in a hole's
// walls) back to from, where the shot started; the stroke counts, with no
// penalty. Every stroke golf plays or replays goes through it.
func back(h *course.Simple, from physics.Vec2, shot physics.Shot, holed bool) physics.Shot {
	rest := shot.Rest()
	w, hh := h.W, h.H
	if holed || len(shot.Path) == 0 || (rest.X >= 0 && rest.X <= float64(w) && rest.Y >= 0 && rest.Y <= float64(hh)) {
		return shot
	}
	// copies: the hole's own slices are the hole's
	shot.Path = append(append(make([]physics.Vec2, 0, len(shot.Path)+1), shot.Path...), from)
	shot.Air = append(append(make([]bool, 0, len(shot.Air)+1), shot.Air...), false)
	shot.Cause = append(append(make([]byte, 0, len(shot.Cause)+1), shot.Cause...), '-')
	return shot
}

// stroke resolves one shot into the round and reports whether it was holed.
func stroke(e *entry, h *course.Simple, r *round, player address, angle, power float64, tick int, weather []physics.Zone) (physics.Shot, bool) {
	if r.strokes >= maxRoundStrokes {
		panic(errStrokeLimit)
	}
	notOver(r.period) // every stroke, not only the first
	// played exactly as it is recorded, so the record replays
	angle, power = validShot(angle, power)

	from := r.ball()
	shot, holed := resolve(h.PreviewWith(from, angle*math.Pi/180, power, r.strokes, tick, weather))
	shot = back(h, from, shot, holed)
	w, hh := h.W, h.H
	e.mark(course.WearIndexOn(shot.Rest(), w, hh)) // where the round's ball is: back's, for a leak
	// the decisions, as played: what anyone needs to replay the round
	if r.shots != "" {
		r.shots += ";"
	}
	played := ufmt.Sprintf("%.4f,%.4f,%d", angle, power, tick)
	r.shots += played
	rest := shot.Rest()
	r.fx, r.fy, r.bx, r.by = from.X, from.Y, rest.X, rest.Y
	r.strokes++
	e.plays++

	if !holed {
		chain.Emit(EventShot, "hole", e.id, "player", player.String(),
			"strokes", strconv.Itoa(r.strokes), "mode", modeNames[r.mode], "shot", played)
		return shot, false
	}
	m, p := r.mode, player.String()
	// a player's best stays theirs: replaying the hole never erases it, and a
	// tie keeps the older round, shots and all
	best, _ := e.bests(m).Get(p)
	// another's round sent again (nearly: copyOf): kept as this player's
	// round and ghost, never ranked; it never replaces a best of their own,
	// and a round of their own replaces it, better or not
	copied, wasCopy := copyOf(e, p, r.shots), e.copies(m).Has(p)
	if was := bestStrokes(best); (was == 0 || r.strokes < was || wasCopy && !copied) && !(copied && was > 0 && !wasCopy) {
		if was > 0 && !wasCopy {
			e.board(m).Remove(boardKey(best, p))
		}
		best = bestOf(r)
		e.bests(m).Set(p, best)
		counted := was // (what their standing holds of this hole: a copy, nothing)
		if wasCopy {
			counted = 0
		}
		switch {
		case copied:
			e.copies(m).Set(p, "1")
			chain.Emit(EventCopyNotRanked, "hole", e.id, "player", p, "mode", modeNames[m])
		case counts(e, m, p, counted):
			e.copies(m).Remove(p)
			improve(m, p, e.par, counted, r.strokes)
		default:
			e.copies(m).Remove(p)
			if counted == 0 && e.official && e.next != "" && !e.out.done[m] && p >= e.out.from[m] {
				// the drain has yet to reach this first finish: it was never
				// counted, so it must not be taken out
				e.fresh(m).Set(p, "1")
			}
		}
	}
	if named(p) && !e.copies(m).Has(p) {
		seat(e, m, p, best)
	}
	if e.official {
		drain(finishBatch) // only the course's finishes pay for the course's drain
	}
	chain.Emit(EventHoled, "hole", e.id, "player", p,
		"strokes", strconv.Itoa(r.strokes), "mode", modeNames[m], "shots", r.shots)
	// the round is its best now, or no better than it: not kept (a round of
	// this commit's alone was never stored)
	e.roundTree().Remove(p)
	return shot, true
}

// seat puts a named player where their best puts them: on the hole's board,
// in its record if it tops it, and in the course ranking if they stand in it.
// Every finish does it, improved or not, so a player named since ranks.
func seat(e *entry, m int, p string, best string) {
	k := boardKey(best, p)
	if !e.board(m).Has(k) {
		e.board(m).Set(k, p)
	}
	// the record is a named player's (a throwaway address could hold it for
	// good) and the board's top, so a tie goes to the first to make it
	if n, rec := bestStrokes(best), e.rec(m); rec.best == 0 || n < rec.best ||
		n == rec.best && address(p) != rec.by && k < boardKey(bestOfPlayer(e, m, rec.by.String()), rec.by.String()) {
		if m == pro {
			e.proBest, e.proBestBy = n, address(p)
		} else {
			e.best, e.bestBy = n, address(p)
		}
	}
	if v, ok := totals[m].Get(p); ok && decodeRow(v).holes > 0 {
		if rk := rankKey(decodeRow(v)); !ranks[m].Has(rk) {
			idle[m].Remove(rk) // a standing parked while unnamed leaves idle as it ranks
			ranks[m].Set(rk, p)
		}
	}
}

// bestOfPlayer is a player's kept best on e in mode m, "" for none.
func bestOfPlayer(e *entry, m int, p string) string {
	v, _ := e.bests(m).Get(p)
	return v
}

// Claim ranks the caller's bests kept while they had no name: on the boards
// of the course's current holes, in both modes, and in the course ranking.
// It returns how many bests it seated, and refuses a caller with no gno.land
// name. It reads the course's holes only, so it costs the same for everyone.
func Claim(cur realm) int {
	begin()
	r := claimNow(cur)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func claimNow(cur realm) int {
	p := cur.Previous().Address().String()
	if !named(p) {
		panic("golf: take a gno.land name first: only named players are ranked")
	}
	n := 0
	slots.Iterate("", "", func(_ string, id string) bool {
		var e *entry // (decoded only where the player has a best: most holes they have none)
		for m := 0; m < modes; m++ {
			if best, ok := bestsOf(id, m).Get(p); ok && !copiesOf(id, m).Has(p) {
				if e == nil {
					e = find(id)
				}
				seat(e, m, p, best)
				n++
			}
		}
		if e != nil {
			saveEntry(e) // (its record may be theirs now)
		}
		return false
	})
	return n
}

// maxRoundStrokes bounds a round's history (Round shows it); maxPath the path
// a hole may return for a stroke (an honest one: a few hundred points).
const (
	maxRoundStrokes = 60
	maxPath         = 512
)

// q4 rounds to the precision a shot is recorded at.
func q4(x float64) float64 { return math.Round(x*1e4) / 1e4 }

// maxTick bounds the third field of a shot: any timed piece turns in fewer.
const maxTick = 1023

// parseShot reads "angle,power" or "angle,power,tick". The tick is where the
// timed pieces were when the player let go (0 if absent), clamped to
// 0..maxTick.
func parseShot(s string) (float64, float64, int) {
	parts := strings.Split(s, ",")
	if len(parts) != 2 && len(parts) != 3 {
		panic(`golf: a shot is "angle,power" or "angle,power,tick", got: ` + s)
	}
	angle, err := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
	if err != nil {
		panic("golf: bad angle: " + s)
	}
	power, err := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
	if err != nil {
		panic("golf: bad power: " + s)
	}
	tick := 0
	if len(parts) == 3 {
		tick = clampTick(strings.TrimSpace(parts[2]), s)
	}
	return angle, power, tick
}

// clampTick reads a tick: an optional sign and digits, clamped to
// 0..maxTick, even past what an int holds.
func clampTick(t, shot string) int {
	digits := strings.TrimPrefix(strings.TrimPrefix(t, "-"), "+")
	if digits == "" {
		panic("golf: bad tick: " + shot)
	}
	for i := 0; i < len(digits); i++ {
		if digits[i] < '0' || digits[i] > '9' {
			panic("golf: bad tick: " + shot)
		}
	}
	if strings.HasPrefix(t, "-") {
		return 0
	}
	if digits = strings.TrimLeft(digits, "0"); len(digits) > 4 {
		return maxTick
	}
	n, err := strconv.Atoi("0" + digits)
	if err != nil {
		panic("golf: bad tick: " + shot) // digits only, at most 4: cannot happen
	}
	if n > maxTick {
		return maxTick
	}
	return n
}

// roundOf is the player's round under way on e, or a new one from the tee,
// not stored: its commit stores it if it does not finish it.
func roundOf(e *entry, h *course.Simple, player address) *round {
	if v, ok := e.roundTree().Get(player.String()); ok {
		return decodeRound(v)
	}
	s := h.Start()
	return &round{bx: s.X, by: s.Y}
}

// maxName and maxNote bound a hole's name and a version's note.
const (
	maxName = 40
	maxNote = 140
)

// cleanName keeps a hole's name to one short line of plain text
// (cleanText), with at least a letter or a digit in it.
func cleanName(n string) string {
	s := cleanText(n, maxName)
	for _, c := range s {
		if unicode.IsLetter(c) || unicode.IsDigit(c) {
			return s
		}
	}
	return "Untitled hole"
}

// cleanText keeps an author's text to one line of plain text, at most max
// characters: no control, format (Cf: bidi, zero-width, tags) or nonspacing
// (Mn: stacked accents, variation selectors) characters, no blank-looking
// ones, nothing that ends a markdown table cell or opens a link, a tag, an
// HTML entity, a strikethrough, a mention or an email link.
func cleanText(n string, max int) string {
	b := make([]rune, 0, max)
	for _, c := range n {
		if len(b) >= max {
			break
		}
		switch {
		case c < 0x20 || c >= 0x7f && c < 0xa0:
			continue
		case c == 0xad, c == 0x34f, c == 0x61c, c == 0x115f, c == 0x1160, c == 0x17b4, c == 0x17b5, c == 0x180e,
			c >= 0x200b && c <= 0x200f, c >= 0x2028 && c <= 0x202e, c >= 0x2060 && c <= 0x206f,
			c == 0x2800, c == 0x3164, c >= 0xfe00 && c <= 0xfe0f, c == 0xfeff, c == 0xffa0,
			c >= 0xe0000 && c <= 0xe0fff:
			continue
		case unicode.In(c, unicode.Mn, unicode.Cf):
			// é typed as one (NFC) stays; combining marks (Devanagari, Thai) go
			continue
		case !unicode.IsPrint(c) && c != ' ':
			// what Go would print escaped (\U…), which JSON readers refuse
			continue
		case strings.ContainsRune("|[]<>`*_#\\&~@", c):
			continue
		}
		b = append(b, c)
	}
	// no bare link a page might make clickable (": /" keeps the length)
	return strings.TrimSpace(strings.ReplaceAll(string(b), "://", ": /"))
}

// maxSkin bounds a skin's length.
const maxSkin = 24

// cleanSkin keeps a skin to what it is meant to be: a short lower-case id.
func cleanSkin(s string) string {
	b := make([]byte, 0, maxSkin)
	for i := 0; i < len(s) && len(b) < maxSkin; i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == ' ' || c == '-' || c == '_' {
			b = append(b, c)
		}
	}
	return string(b)
}
