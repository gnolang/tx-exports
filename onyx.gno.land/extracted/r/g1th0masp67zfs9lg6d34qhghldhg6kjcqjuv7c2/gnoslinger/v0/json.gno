package gnoslinger

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/engine/v0"
	profiles "gno.land/r/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/profiles/v0"
)

// JSON views for the web client, read through Render("json/...") so the
// string comes back raw from vm/qrender. Built by hand: the shapes are fixed
// and small, and the chain has no encoding/json.

const listLimit = 50

// liveScan is how many of the newest games GamesJSON looks through for the
// ones being played: what the view costs stays bounded however many games
// there are.
const liveScan = 200

// endedLimit is how many of the last finished games GamesJSON lists.
const endedLimit = 10

// GameJSON is the full view of a game:
//
//	{"id","rev","phase","turn","maxTurns","timeout" (seconds),"board",
//	 "players":[{"addr" ("" for a seat nobody took yet),"name","char","hex" ("" until the seat set up),"facing","down","delay","status","committed","revealed","locked" (its timelocked plan, "" once revealed),"missed" (turns in a row it let time out),"playedFoot","playedRun","ranLastTurn",
//	             "aim","aimAt" (the seat the AIM markers follow, -1 when they sit on a hex or there is no aim),"aimHex" (the hex they sit on, "" when they follow a seat),"endurance","serious","gunArm","otherArm","leg",
//	             "guns":[{"id","type","name","location","cocked","shells","capacity","jammed","exploded"}]}]   (one entry per seat, 2 to 4),
//	 "ground":[{"id" (ground id, "g<id>" in a plan),"hex","guns":[{..}]}],
//	 "winner","vp":[victory points per seat],"awards":[{"p","reason","points"}] (rule 15, once a played game ends),
//	 "stake" (ugnot each player puts in, 0 for a free showdown),"pot" (the stakes paid so far),"payouts":[ugnot each seat got, [] until paid],"houseCut" (stakes.gno),"endReason",
//	 "createdAt","updatedAt","timeoutAt" (when the turn in progress can be claimed, 0 unless planning or revealing),
//	 "commitUntil" (the turn's deadline),"revealUntil" (when unrevealed seats can be claimed out),"lockRound" (the drand round the plans are timelocked to) (0 unless planning or revealing),
//	 "lastTurn":null|{"turn","seed","cards":[result card numbers drawn, in order],"plans":[..],
//	             "events":[{"seg","p","kind","action","from","to","facing","down","n","delay","reason","card","result","endurance","target","hit","range","gun","gunId","step","chart","status"}],
//	             "start":[{"hex","facing","down","delay","status","aim","aimAt","aimHex","endurance","serious","gunArm","otherArm","leg","guns":[..]},..],
//	             "ground":[the weapons on the ground at the turn's start, as "ground" above]}}
//
// Times are unix seconds; winner, events[].p and events[].target are seat indexes, -1 for none.
// The plans of the turn in progress are hidden until revealed: only their
// commits show, as flags and timelocked plans.
func GameJSON(id string) string {
	g := getGame(id)
	var b strings.Builder
	b.WriteString(`{"id":` + quote(g.ID))
	b.WriteString(`,"rev":` + strconv.Itoa(g.Rev))
	b.WriteString(`,"phase":` + quote(g.Phase.String()))
	b.WriteString(`,"turn":` + strconv.Itoa(g.Turn))
	b.WriteString(`,"maxTurns":` + strconv.Itoa(g.MaxTurns))
	b.WriteString(`,"timeout":` + strconv.FormatInt(int64(g.Timeout/time.Second), 10))
	b.WriteString(`,"board":"A"`)
	b.WriteString(`,"players":[`)
	for i := range g.Players {
		if i > 0 {
			b.WriteByte(',')
		}
		writePlayer(&b, g, i)
	}
	b.WriteByte(']')
	writeGround(&b, g.State.Ground)
	b.WriteString(`,"winner":` + strconv.Itoa(g.Winner))
	writeVP(&b, g)
	b.WriteString(`,"awards":[`)
	for i, a := range g.Awards {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"p":` + strconv.Itoa(a.Player) + `,"reason":` + quote(a.Reason) + `,"points":` + strconv.Itoa(a.Points) + `}`)
	}
	b.WriteByte(']')
	writeStakes(&b, g)
	b.WriteString(`,"endReason":` + quote(g.EndReason))
	b.WriteString(`,"createdAt":` + strconv.FormatInt(g.CreatedAt.Unix(), 10))
	b.WriteString(`,"updatedAt":` + strconv.FormatInt(g.UpdatedAt.Unix(), 10))
	writeTimeoutAt(&b, g)
	commitUntil, revealUntil, lockRound := int64(0), int64(0), int64(0)
	if g.Phase == PhasePlanning || g.Phase == PhaseRevealing {
		commitUntil, revealUntil, lockRound = g.commitUntil().Unix(), g.revealUntil().Unix(), g.lockRound()
	}
	b.WriteString(`,"commitUntil":` + strconv.FormatInt(commitUntil, 10))
	b.WriteString(`,"revealUntil":` + strconv.FormatInt(revealUntil, 10))
	b.WriteString(`,"lockRound":` + strconv.FormatInt(lockRound, 10))
	b.WriteString(`,"lastTurn":`)
	writeTurnResult(&b, g.lastTurn())
	b.WriteByte('}')
	return b.String()
}

// PlanJSON is where an address's plan for the turn in progress stands; the
// plan itself shows once revealed:
//
//	{"id","turn","seat" (-1 when addr is not a player),"committed","revealed","plan" ("" until revealed)}
func PlanJSON(id, addr string) string {
	g := getGame(id)
	seat := g.seat(address(addr))
	var b strings.Builder
	b.WriteString(`{"id":` + quote(g.ID))
	b.WriteString(`,"turn":` + strconv.Itoa(g.Turn))
	b.WriteString(`,"seat":` + strconv.Itoa(seat))
	committed, revealed, plan := false, false, ""
	if seat >= 0 {
		committed, revealed, plan = g.committed(seat), g.Revealed[seat], g.Plans[seat]
	}
	b.WriteString(`,"committed":` + strconv.FormatBool(committed))
	b.WriteString(`,"revealed":` + strconv.FormatBool(revealed))
	b.WriteString(`,"plan":` + quote(plan))
	b.WriteByte('}')
	return b.String()
}

// TurnJSON is one resolved turn of a game (from 1), the turn result as
// json/game writes its last one: what replays read, a turn per query (the
// "json/history/{id}/{turn}" view), so that what a query costs does not
// grow with the game. Each turn is self-contained (its start and ground).
func TurnJSON(id string, turn int) string {
	g := getGame(id)
	if turn < 1 || turn > len(g.Turns) {
		panic("gnoslinger: turn " + strconv.Itoa(turn) + " is not resolved")
	}
	var b strings.Builder
	writeTurnResult(&b, g.Turns[turn-1])
	return b.String()
}

// HistoryJSON is every resolved turn of a game, oldest first, for tests and
// tools (the tutorial's showdown, make gen-tutorial); no view serves it: a
// long game's history may cost more than a query can.
//
//	{"id","turn","phase","players":[{"addr","char"}],"turns":[turn result...]}
func HistoryJSON(id string) string {
	g := getGame(id)
	var b strings.Builder
	b.WriteString(`{"id":` + quote(g.ID))
	b.WriteString(`,"turn":` + strconv.Itoa(g.Turn))
	b.WriteString(`,"phase":` + quote(g.Phase.String()))
	b.WriteString(`,"players":[`)
	for i, p := range g.Players {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"addr":` + quote(p.Addr.String()) + `,"name":` + quote(profiles.Name(p.Addr)) + `,"char":` + quote(p.Char) + `}`)
	}
	b.WriteString(`],"turns":[`)
	for i, r := range g.Turns {
		if i > 0 {
			b.WriteByte(',')
		}
		writeTurnResult(&b, r)
	}
	b.WriteString("]}")
	return b.String()
}

func writePlayer(b *strings.Builder, g *Game, i int) {
	p, c := g.Players[i], g.State.Chars[i]
	b.WriteString(`{"addr":` + quote(p.Addr.String()))
	b.WriteString(`,"name":` + quote(profiles.Name(p.Addr)))
	b.WriteString(`,"char":` + quote(p.Char))
	b.WriteString(`,"hex":` + quote(c.Hex))
	b.WriteString(`,"facing":` + strconv.Itoa(int(c.Facing)))
	b.WriteString(`,"down":` + strconv.FormatBool(c.Down))
	b.WriteString(`,"delay":` + strconv.Itoa(c.Delay))
	b.WriteString(`,"status":` + quote(c.Status.String()))
	b.WriteString(`,"committed":` + strconv.FormatBool(g.committed(i)))
	b.WriteString(`,"revealed":` + strconv.FormatBool(g.Revealed[i]))
	b.WriteString(`,"locked":` + quote(g.Commits[i].Locked))
	b.WriteString(`,"missed":` + strconv.Itoa(g.Missed[i]))
	b.WriteString(`,"playedFoot":` + strconv.FormatBool(c.PlayedFoot))
	b.WriteString(`,"playedRun":` + strconv.FormatBool(c.PlayedRun))
	b.WriteString(`,"ranLastTurn":` + strconv.FormatBool(c.RanLastTurn))
	writeWounds(b, c)
	writeGuns(b, c.Guns)
	b.WriteByte('}')
}

// writeWounds writes the aim and wound members of a character.
func writeWounds(b *strings.Builder, c engine.Character) {
	b.WriteString(`,"aim":` + strconv.Itoa(c.Aim))
	aimAt := engine.NoSeat
	if c.Aim > 0 {
		aimAt = c.AimAt
	}
	b.WriteString(`,"aimAt":` + strconv.Itoa(aimAt))
	b.WriteString(`,"aimHex":` + quote(c.AimHex))
	b.WriteString(`,"endurance":` + strconv.Itoa(c.Endurance))
	b.WriteString(`,"serious":` + strconv.Itoa(c.Serious))
	b.WriteString(`,"gunArm":` + strconv.Itoa(c.GunArm))
	b.WriteString(`,"otherArm":` + strconv.Itoa(c.OtherArm))
	b.WriteString(`,"leg":` + strconv.Itoa(c.Leg))
}

// writeTimeoutAt writes the ,"timeoutAt" member: when the turn in progress
// can be claimed, 0 unless the game is planning or revealing.
func writeTimeoutAt(b *strings.Builder, g *Game) {
	timeoutAt := int64(0)
	if g.Phase == PhasePlanning || g.Phase == PhaseRevealing {
		timeoutAt = g.timeoutAt().Unix()
	}
	b.WriteString(`,"timeoutAt":` + strconv.FormatInt(timeoutAt, 10))
}

// writeGround writes the ,"ground":[...] member: the weapons lying in hexes.
func writeGround(b *strings.Builder, ground []engine.GroundGun) {
	b.WriteString(`,"ground":[`)
	for i, gg := range ground {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"id":` + strconv.Itoa(gg.ID))
		b.WriteString(`,"hex":` + quote(gg.Hex))
		writeGuns(b, engine.Guns{gg.Gun})
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

// writeGuns writes the ,"guns":[...] member of a character.
func writeGuns(b *strings.Builder, guns engine.Guns) {
	b.WriteString(`,"guns":[`)
	n := 0
	for _, g := range guns {
		if g.Type == engine.NoGun {
			continue
		}
		if n > 0 {
			b.WriteByte(',')
		}
		n++
		spec := g.Type.Spec()
		b.WriteString(`{"id":` + strconv.Itoa(g.ID))
		b.WriteString(`,"type":` + quote(string(g.Type)))
		b.WriteString(`,"name":` + quote(spec.Name))
		b.WriteString(`,"location":` + quote(g.Location.String()))
		b.WriteString(`,"cocked":` + strconv.FormatBool(g.Cocked))
		b.WriteString(`,"shells":` + strconv.Itoa(g.Shells))
		b.WriteString(`,"capacity":` + strconv.Itoa(spec.Capacity))
		b.WriteString(`,"jammed":` + strconv.FormatBool(g.Jammed))
		b.WriteString(`,"exploded":` + strconv.FormatBool(g.Exploded))
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func writeTurnResult(b *strings.Builder, r *TurnResult) {
	if r == nil {
		b.WriteString("null")
		return
	}
	b.WriteString(`{"turn":` + strconv.Itoa(r.Turn))
	b.WriteString(`,"seed":` + quote(r.Seed))
	b.WriteString(`,"cards":[`)
	for i, n := range r.Cards() {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.Itoa(n))
	}
	b.WriteString(`],"plans":[`)
	for i, p := range r.Plans {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(quote(p))
	}
	b.WriteString(`],"events":[`)
	for i, e := range r.Events() {
		if i > 0 {
			b.WriteByte(',')
		}
		writeEvent(b, e)
	}
	b.WriteString(`],"start":[`)
	for i, c := range r.Start() {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"hex":` + quote(c.Hex))
		b.WriteString(`,"facing":` + strconv.Itoa(int(c.Facing)))
		b.WriteString(`,"down":` + strconv.FormatBool(c.Down))
		b.WriteString(`,"delay":` + strconv.Itoa(c.Delay))
		b.WriteString(`,"status":` + quote(c.Status.String()))
		writeWounds(b, c)
		writeGuns(b, c.Guns)
		b.WriteByte('}')
	}
	b.WriteByte(']')
	writeGround(b, r.Ground())
	b.WriteByte('}')
}

func writeEvent(b *strings.Builder, e engine.Event) {
	b.WriteString(`{"seg":` + strconv.Itoa(e.Seg))
	b.WriteString(`,"p":` + strconv.Itoa(e.Player))
	b.WriteString(`,"kind":` + quote(e.Kind))
	b.WriteString(`,"action":` + quote(string(e.Action)))
	b.WriteString(`,"from":` + quote(e.From))
	b.WriteString(`,"to":` + quote(e.To))
	b.WriteString(`,"facing":` + strconv.Itoa(int(e.Facing)))
	b.WriteString(`,"down":` + strconv.FormatBool(e.Down))
	b.WriteString(`,"n":` + strconv.Itoa(e.N))
	b.WriteString(`,"delay":` + strconv.Itoa(e.Delay))
	b.WriteString(`,"reason":` + quote(e.Reason))
	b.WriteString(`,"card":` + strconv.Itoa(e.Card))
	b.WriteString(`,"result":` + quote(e.Result))
	b.WriteString(`,"endurance":` + strconv.Itoa(e.Endurance))
	b.WriteString(`,"target":` + strconv.Itoa(e.Target))
	b.WriteString(`,"hit":` + quote(e.Hit))
	b.WriteString(`,"range":` + strconv.Itoa(e.Range))
	b.WriteString(`,"gun":` + quote(string(e.Gun)))
	b.WriteString(`,"gunId":` + strconv.Itoa(e.GunID))
	b.WriteString(`,"step":` + strconv.Itoa(e.Step))
	b.WriteString(`,"chart":` + quote(e.Chart))
	b.WriteString(`,"status":` + quote(e.Status))
	b.WriteByte('}')
}

// GamesJSON lists, for an address, the games with a free seat, the games
// being played (live: planning or revealing, for anyone to watch), the
// last endedLimit games finished (ended, for anyone to replay) and the
// games it plays or played, newest first (at most 50 each), with the
// address's registered name ("" if none). live and ended are found among
// the liveScan newest games, a running game being recent: a turn times
// out within days.
//
//	{"name","open":[summary...],"live":[summary...],"ended":[summary...],"mine":[summary...]}
//	summary = {"id","rev","phase","turn","maxTurns","timeout","winner","endReason","vp","stake","pot","payouts","houseCut","createdAt","updatedAt","timeoutAt","lockRound","players":[{"addr","name","char","status","committed","revealed"}]}
//
// lockRound (0 unless planning or revealing) tells the lobby when the
// timelocked plans of a seat committed and not revealed can be opened.
//
// players has one entry per seat, "addr" "" for a seat nobody took yet.
func GamesJSON(addr string) string {
	var b strings.Builder
	b.WriteString(`{"name":` + quote(profiles.Name(address(addr))))
	b.WriteString(`,"open":[`)
	n := 0
	openGames.ReverseIterate("", "", func(_ string, v any) bool {
		if n > 0 {
			b.WriteByte(',')
		}
		writeSummary(&b, v.(*Game))
		n++
		return n >= listLimit
	})
	var live, ended strings.Builder
	nLive, nEnded, scanned := 0, 0, 0
	games.ReverseIterate("", "", func(_ string, v any) bool {
		scanned++
		g := v.(*Game)
		switch {
		case (g.Phase == PhasePlanning || g.Phase == PhaseRevealing) && nLive < listLimit:
			if nLive > 0 {
				live.WriteByte(',')
			}
			writeSummary(&live, g)
			nLive++
		case g.Phase == PhaseFinished && nEnded < endedLimit:
			if nEnded > 0 {
				ended.WriteByte(',')
			}
			writeSummary(&ended, g)
			nEnded++
		}
		return (nLive >= listLimit && nEnded >= endedLimit) || scanned >= liveScan
	})
	b.WriteString(`],"live":[` + live.String() + `],"ended":[` + ended.String() + `],"mine":[`)
	if v := byPlayer.Get(addr); v != nil {
		for i, id := range v.([]string) {
			if i >= listLimit {
				break
			}
			if i > 0 {
				b.WriteByte(',')
			}
			writeSummary(&b, games.Get(id).(*Game))
		}
	}
	b.WriteString("]}")
	return b.String()
}

func writeSummary(b *strings.Builder, g *Game) {
	b.WriteString(`{"id":` + quote(g.ID))
	b.WriteString(`,"rev":` + strconv.Itoa(g.Rev))
	b.WriteString(`,"phase":` + quote(g.Phase.String()))
	b.WriteString(`,"turn":` + strconv.Itoa(g.Turn))
	b.WriteString(`,"maxTurns":` + strconv.Itoa(g.MaxTurns))
	b.WriteString(`,"timeout":` + strconv.FormatInt(int64(g.Timeout/time.Second), 10))
	b.WriteString(`,"winner":` + strconv.Itoa(g.Winner))
	writeVP(b, g)
	writeStakes(b, g)
	b.WriteString(`,"endReason":` + quote(g.EndReason))
	b.WriteString(`,"createdAt":` + strconv.FormatInt(g.CreatedAt.Unix(), 10))
	b.WriteString(`,"updatedAt":` + strconv.FormatInt(g.UpdatedAt.Unix(), 10))
	writeTimeoutAt(b, g)
	lockRound := int64(0)
	if g.Phase == PhasePlanning || g.Phase == PhaseRevealing {
		lockRound = g.lockRound()
	}
	b.WriteString(`,"lockRound":` + strconv.FormatInt(lockRound, 10))
	b.WriteString(`,"players":[`)
	for i, p := range g.Players {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"addr":` + quote(p.Addr.String()) + `,"name":` + quote(profiles.Name(p.Addr)) + `,"char":` + quote(p.Char) +
			`,"status":` + quote(g.State.Chars[i].Status.String()) + `,"committed":` + strconv.FormatBool(g.committed(i)) + `,"revealed":` + strconv.FormatBool(g.Revealed[i]) + `}`)
	}
	b.WriteString("]}")
}

// writeVP writes the victory points of each seat.
func writeVP(b *strings.Builder, g *Game) {
	b.WriteString(`,"vp":[`)
	for i, v := range g.VP {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.Itoa(v))
	}
	b.WriteByte(']')
}

// writeStakes writes the stake, the pot and, once paid, what each seat got.
func writeStakes(b *strings.Builder, g *Game) {
	b.WriteString(`,"stake":` + strconv.FormatInt(g.Stake, 10))
	b.WriteString(`,"pot":` + strconv.FormatInt(g.Pot, 10))
	b.WriteString(`,"payouts":[`)
	for i, v := range g.Payouts {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatInt(v, 10))
	}
	b.WriteString(`],"houseCut":` + strconv.FormatInt(g.HouseCut, 10))
}

// quote encodes s as a JSON string.
func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte("0123456789abcdef"[c>>4])
			b.WriteByte("0123456789abcdef"[c&0xf])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// GameRev is the cheapest way to poll a game for changes.
func GameRev(id string) int { return getGame(id).Rev }
