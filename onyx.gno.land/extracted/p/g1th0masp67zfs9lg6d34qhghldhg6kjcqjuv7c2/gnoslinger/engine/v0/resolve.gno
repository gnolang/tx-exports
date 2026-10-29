package engine

import (
	"strings"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/cards/v0"
	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"
)

// Event kinds.
const (
	EvMove         = "move"          // From, To, Facing, Down, Action (Reason "stagger" when thrown by a hit)
	EvTurn         = "turn"          // Facing, Action (Reason "stagger" when thrown by a hit)
	EvFlip         = "flip"          // Down, Action (empty for a DROP penalty)
	EvDelay        = "delay"         // N gained, Reason, Card drawn (0 for crawl), Result penalty, Endurance crossed off, Delay = running total once this card is counted
	EvCancel       = "cancel"        // Action, Reason (To = the obstacle in the way for no_los)
	EvDraw         = "draw"          // Gun moved from From (holster, a hand, or "ground" with N = its ground id) to To (a hand) and cocked, unless jammed (Result "jammed")
	EvLoad         = "load"          // a shell loaded in the gun in both hands, N shells now, uncocked; Result "unjammed" when that completes a jammed gun
	EvCock         = "cock"          // Gun cocked
	EvUncock       = "uncock"        // Gun uncocked
	EvAim          = "aim"           // N = AIM points after aiming, To = the hex they sit on, Target = the seat they follow (-1 for a hex)
	EvLoseAim      = "lose_aim"      // Reason (To = the obstacle in the way for no_los)
	EvNothing      = "nothing"       // a Shoot used to do nothing, or a shot held at a hex nobody stands in (Reason empty_hex, To = the hex) or at a target out of sight (Reason no_los, To = its hex, Target = its seat) or out of the fight (Reason out_of_fight, To = its hex, Target = its seat): keeps the aim
	EvShot         = "shot"          // Card, Target = the seat shot at (whoever stood in the hex named, for a shot at a hex), To = the hex shot at, Hit (final location or Miss), Range, N = aim time, Reason "" | out_of_zone | misfire
	EvThrow        = "throw"         // like a shot: Card, Target, To = the hex thrown at, Hit, Range, N = aim time, Chart, Status, Gun, GunID, Reason "" | out_of_zone; the weapon then lands (EvDropGun, Reason throw)
	EvMalfunction  = "malfunction"   // Card, Result (no_effect, misfire, jams, explodes, no_penalty), Gun, GunID
	EvWildShot     = "wild_shot"     // Gun went off without hitting anything: uncocked, one shell less
	EvWound        = "wound"         // Player hit: Result = penalty kind (Kill, Stun...), N
	EvDirection    = "direction"     // Card drawn as a direction card: To = its HEX line
	EvDropGun      = "drop_gun"      // Gun fell from From (hand) to the hex To, N = its ground id; Reason throw for a thrown weapon landing, gun_move for one let go (10.22)
	EvMoveGun      = "move_gun"      // a gun move (10.22): Gun moved from From (both hands) to To (a hand), as it was
	EvPassOut      = "pass_out"      // end of turn: more delay than endurance two turns in a row
	EvSeriousCheck = "serious_check" // end of showdown: Card, N = DELAY + SERIOUS points (4 kills)
	EvVP           = "vp"            // end of turn: victory points (rule 15), N = points (< 0 for a loss), Reason = the award (VPSurvive...)
	EvRunAway      = "run_away"      // the character moved off the map (15.5): From = the edge hex it left, Facing = the way it went, Action
)

// Delay and cancel reasons.
const (
	ReasonCrawl      = "crawl"        // moving while down (rule 9.2)
	ReasonSprint     = "sprint"       // sprinting draws a delay card (rule 9.23)
	ReasonLeap       = "leap"         // leap/drop draws two delay cards (rule 9.4)
	ReasonOccupied   = "occupied"     // ending a move in an occupied hex (rule 9.24)
	ReasonFence      = "fence"        // moving or staggering across a fence (rule 35.2)
	ReasonObstacle   = "obstacle"     // moving or staggering onto or off an obstacle (rule 36.4)
	ReasonDrop       = "drop"         // a DROP penalty draws three delay cards (rule 14.11)
	ReasonStun       = "stun"         // a STUN draws wound cards (14.11)
	ReasonLight      = "light"        // a LIGHT draws fatigue cards (14.11)
	ReasonSerious    = "serious"      // fatigue cards at the start of the turn (14.12)
	ReasonLeg        = "leg"          // fatigue cards per hex moved upright (14.12)
	ReasonTime       = "time"         // not executed by the end of segment 5 (rule 7.53)
	ReasonNoGun      = "no_gun"       // no gun in the box the action needs (11.3); a gun move of a gun the character no longer has
	ReasonNotInHand  = "not_in_hand"  // a gun move dropping a gun that is not in a hand box (10.22)
	ReasonNotBoth    = "not_both"     // a gun move to a hand of a gun that is not in both hands (10.22)
	ReasonGunDropped = "gun_dropped"  // a gun move dropped the gun the character aims with: its AIM points go
	ReasonHandFull   = "hand_full"    // the destination hand already holds a gun
	ReasonNoRoom     = "no_room"      // the character already carries MaxGuns weapons
	ReasonNotCocked  = "not_cocked"   // shooting an uncocked gun (13.1)
	ReasonEmpty      = "empty"        // shooting a gun without shells (13.1)
	ReasonJammed     = "jammed"       // shooting or cocking a jammed gun not completely reloaded yet (13.31)
	ReasonFull       = "full"         // loading a gun already holding its Ammo limit (10.42)
	ReasonBroken     = "broken"       // using or loading an exploded gun (13.31)
	ReasonNoTarget   = "no_target"    // the character named is out of the fight (12.6), or is the shooter, or no such seat
	ReasonOutOfZone  = "out_of_zone"  // the target is in the blind zone (8.32, 12.41)
	ReasonNoLOS      = "no_los"       // no line of sight to the target, an obstacle in the way by the heights (31): an aim is cancelled, a shot is held, AIM points are lost
	ReasonReveal     = "reveal"       // revealing an action other than Turn or a gun action (12.44)
	ReasonTransfer   = "transfer"     // a new target more than one hex from the markers (12.5)
	ReasonOwnHex     = "own_hex"      // a new target moving the markers into or out of the character's own hex (12.5)
	ReasonNoHex      = "no_hex"       // aiming at a hex that is not on the board
	ReasonShot       = "shot"         // aim spent by a shot (12.43)
	ReasonStagger    = "stagger"      // thrown by a STAGGER penalty
	ReasonMisfire    = "misfire"      // the shot was cancelled by a MALFUNCTION
	ReasonEmptyHex   = "empty_hex"    // a shot at a hex nobody stood in: held (EvNothing)
	ReasonOutOfFight = "out_of_fight" // a shot at a character killed, passed out, surrendered or run away: held (EvNothing)
	ReasonOutOfRange = "out_of_range" // a throw farther than the weapon's wielding factor (17.2)
	ReasonThrow      = "throw"        // aim spent by a throw (16.13); a thrown weapon landing (17.4)
	ReasonGunMove    = "gun_move"     // a gun move dropping the gun in the hex (10.22)
)

// Malfunction results.
const (
	MalfNoEffect  = "no_effect"  // discarded, another card drawn (13.3)
	MalfMisfire   = "misfire"    // the shot is cancelled (13.3)
	MalfNoPenalty = "no_penalty" // second draw was a FIRE: the gun is fine (13.32)
)

// LoadUnjammed is the Result of a load that completes a jammed gun (13.31).
const LoadUnjammed = "unjammed"

// DrawJammed is the Result of a Draw & Cock that moves a jammed gun: it is
// not cocked (13.31).
const DrawJammed = "jammed"

func jammedResult(g Gun) string {
	if g.Jammed {
		return DrawJammed
	}
	return ""
}

// Event is one thing that happened during resolution, in order. Seg is 0
// for turn-start events and EndOfTurn for those after segment 5.
type Event struct {
	Seg       int
	Player    int
	Kind      string
	Action    cards.Code
	From      string
	To        string
	Facing    hex.Dir
	Down      bool
	N         int
	Delay     int
	Reason    string
	Card      int     // the result card drawn (0 when none)
	Result    string  // a card's penalty, a malfunction result or a wound's penalty kind
	Endurance int     // endurance boxes crossed off by a wound or fatigue card
	Target    int     // the seat shot at, for shots
	Hit       string  // the final hit location of a shot (Miss "-")
	Range     int     // the range of a shot, in hexes
	Gun       GunType // the gun's model, for gun events
	GunID     int     // the gun's id, for gun events
	Step      int     // which part of the segment it belongs to (StepShots, StepEnd, StepAction+seat), 0 outside the segments
	Chart     string  // a shot's preliminary hit read on the FIRE card's chart, before Target Status ("" when no chart was read)
	Status    string  // the Target Status letters (StatusMove...) that changed a shot's hit, "" when none did
}

// Steps of a segment, in the order they resolve: the shots (7.52), each
// seat's action in seat order, then the end of the segment (the
// occupied-hex penalty, combat results, aims out of the zone). Events of
// one step happened together; a replay shows the steps one after the
// other. Turn-start and end-of-turn events have no step (0).
const (
	StepShots  = 1
	StepEnd    = 2
	StepAction = 3 // + the seat acting
)

// stamp marks the events with their step.
func stamp(evs []Event, step int) {
	for i := range evs {
		evs[i].Step = step
	}
}

// pending is the combat results a shot inflicts on a seat, applied at the
// end of the segment (14.1), with the shooter for STAGGER's "Long" hex.
type pending struct {
	from int
	pens []Penalty
}

// Resolve plays the plans, one per seat, over the five segments of a turn
// (rules 5.5, 6, 7, 9, 12, 13, 14), deterministic for a given Drawer; the
// state given is left as it is. Choices were committed up front and are
// resolved against each character's live state as the stacks play out.
//
// Each segment, every alive character whose next action is due
// (usedTime + cost + delay <= segment) executes it once, shots first
// (7.52), in seat order. Delay gained during a segment and the results of
// hits take effect from the end of the segment ([H6], 14.1). Actions still
// pending after segment 5 are cancelled.
func Resolve(board *hex.Board, st State, plans []Plan, d Drawer) (State, []Event) {
	st.Chars = CloneChars(st.Chars)
	n := len(st.Chars)
	// A STRENGTH is part of the Throw it is played on top of (20.1).
	combined := make([]Plan, n)
	for p := 0; p < n && p < len(plans); p++ { // a seat without a plan passes
		combined[p] = plans[p].Combine()
	}
	plans = combined
	var (
		used = make([]int, n)
		idx  = make([]int, n)
		evs  []Event
	)
	// Turn start: SERIOUS wounds draw fatigue cards (5.3), on the sheet
	// before segment 1.
	startDelay := make([]int, n)
	for p := range st.Chars {
		c := &st.Chars[p]
		startDelay[p] = c.Delay
		if c.Status != Alive {
			continue
		}
		// Each SERIOUS point draws a fatigue card, put down to the seat whose wound gave it.
		for i := 0; i < c.Serious; i++ {
			c.Delay += drawCard(p, c, 0, ReasonSerious, fatigueLine, pointFrom(c.SeriousFrom, i), d, &evs)
		}
	}
	runningDelay(evs, startDelay)
	// Reveal the first actions (5.4): aim may be lost or moved (12.44, 12.5).
	for p := range st.Chars {
		if st.Chars[p].Status == Alive && len(plans[p]) > 0 {
			reveal(board, p, &st, plans[p][0], 0, &evs)
		}
	}
	due := func(p int, seg int) bool {
		c := &st.Chars[p]
		return c.Status == Alive && idx[p] < len(plans[p]) && used[p]+plans[p][idx[p]].Cost+c.Delay <= seg
	}
	advance := func(p int, seg int) {
		used[p] += plans[p][idx[p]].Cost
		idx[p]++
		if st.Chars[p].Status == Alive && idx[p] < len(plans[p]) {
			reveal(board, p, &st, plans[p][idx[p]], seg, &evs)
		}
	}
	for seg := 1; seg <= Segments; seg++ {
		var (
			gained  = make([]int, n)
			moved   = make([]bool, n)
			shot    = make([]bool, n)
			results = make([][]pending, n)
			first   = len(evs) // events of this segment start here
		)
		// Shots and throws are resolved before the other actions (7.52,
		// 16.14), simultaneously.
		for p := 0; p < n; p++ {
			if !due(p, seg) || !(plans[p][idx[p]].IsShot() || plans[p][idx[p]].IsThrow()) {
				continue
			}
			var (
				target int
				pens   []Penalty
			)
			if plans[p][idx[p]].IsThrow() {
				target, pens = throw(board, p, &st, plans[p][idx[p]], seg, d, &evs)
			} else {
				target, pens = shoot(board, p, &st, plans[p][idx[p]], seg, d, &evs)
			}
			if target >= 0 && len(pens) > 0 {
				results[target] = append(results[target], pending{from: p, pens: pens})
			}
			shot[p] = true
			advance(p, seg)
		}
		stamp(evs[first:], StepShots)
		for p := 0; p < n; p++ {
			if shot[p] || !due(p, seg) {
				continue
			}
			from := len(evs)
			a := plans[p][idx[p]]
			g, executed := execute(board, p, a, &st, seg, d, &evs)
			gained[p] += g
			advance(p, seg)
			if executed && cards.IsMove(a.Code) {
				moved[p] = true
			}
			stamp(evs[from:], StepAction+p)
		}
		end := len(evs)

		// Occupied-hex penalty (9.24): when a mover ends the segment in
		// another character's hex, both draw one delay card (once each).
		for p := 0; p < n; p++ {
			if st.Chars[p].Status != Alive {
				continue
			}
			for o := 0; o < n; o++ {
				if o == p || st.Chars[o].Status != Alive || st.Chars[p].Hex != st.Chars[o].Hex || !(moved[p] || moved[o]) {
					continue
				}
				gained[p] += drawDelay(p, &st.Chars[p], seg, ReasonOccupied, d, &evs)
				break
			}
		}

		// Combat results go into effect at the end of the segment (14.1).
		for p := 0; p < n; p++ {
			for _, r := range results[p] {
				gained[p] += applyPenalties(board, p, &st, r, seg, d, &evs)
			}
		}
		// A target out of the aim zone (12.41) or out of sight (31.1) at the
		// end of the segment loses the aim.
		for p := 0; p < n; p++ {
			c := &st.Chars[p]
			if c.Status != Alive || c.Aim == 0 {
				continue
			}
			var t *Character // the markers follow a character...
			if c.AimAt >= 0 {
				t = st.char(c.AimAt)
				if t == nil {
					loseAim(p, c, seg, ReasonNoTarget, &evs)
					continue
				}
				if t.Status == RanAway { // gone off the map: nothing left to aim at
					loseAim(p, c, seg, ReasonNoTarget, &evs)
					continue
				}
				if t.Status != Alive { // the aim stays on a fallen target (12.6)
					continue
				}
			}
			if !board.InAimZone(c.Hex, c.Facing, aimTarget(c, &st)) {
				loseAim(p, c, seg, ReasonOutOfZone, &evs)
				continue
			}
			if clear, blocker := canSee(board, c, c.AimHex, t); !clear { // ...or sit on a hex
				loseAimAt(p, c, seg, ReasonNoLOS, blocker, &evs)
			}
		}

		stamp(evs[end:], StepEnd)

		// Delay gained this segment takes effect next segment (6.1, [H6]);
		// the events carry the running total as the cards come.
		for p := 0; p < n; p++ {
			startDelay[p] = st.Chars[p].Delay
			if st.Chars[p].Status == Killed {
				continue // the delay gained before the kill is moot
			}
			st.Chars[p].Delay += gained[p]
		}
		runningDelay(evs[first:], startDelay)
	}

	// Cancel any action not executed by the end of segment 5 (7.53).
	for p := 0; p < n; p++ {
		if st.Chars[p].Status != Alive {
			continue
		}
		for i := idx[p]; i < len(plans[p]); i++ {
			evs = append(evs, Event{Seg: EndOfTurn, Player: p, Kind: EvCancel, Action: plans[p][i].Code, Reason: ReasonTime})
		}
	}
	return st, evs
}

// aimTarget is the hex the AIM markers of c sit on: the hex of the
// character they follow, or a hex.
func aimTarget(c *Character, st *State) string {
	if t := st.char(c.AimAt); c.AimAt >= 0 && t != nil {
		return t.Hex
	}
	return c.AimHex
}

// standingIn is the seat of the first alive character but seat p standing
// in hex id, NoSeat when nobody does (two characters may share a hex:
// a shot at the hex finds the first in seat order).
func standingIn(st *State, id string, p int) int {
	for q := range st.Chars {
		if q != p && st.Chars[q].Status == Alive && st.Chars[q].Hex == id {
			return q
		}
	}
	return NoSeat
}

// runningDelay stamps each delay event with the delay points its player
// holds once that card is counted, starting from the given totals.
func runningDelay(evs []Event, start []int) {
	total := append([]int(nil), start...)
	for i := range evs {
		if evs[i].Kind == EvDelay {
			total[evs[i].Player] += evs[i].N
			evs[i].Delay = total[evs[i].Player]
		}
	}
}

// reveal applies rules 12.44, 12.5 and 17.11 when an action becomes the
// next one: the aim is lost unless the action is a Turn, an aim, a shot or
// a throw (which spend it when they go off); cocking, uncocking or doing
// nothing with a gun lose it like any other action. An aim, a shot or a
// throw naming a new target keeps the markers only within one hex of their
// place, and never moves them into or out of the character's own hex (both
// targets in it, or both out of it); a shot or a throw moves them onto its
// target.
func reveal(board *hex.Board, p int, st *State, a Action, seg int, evs *[]Event) {
	for _, m := range a.Moves {
		moveGun(p, st, m, seg, evs)
	}
	c := &st.Chars[p]
	if c.Aim == 0 {
		return
	}
	switch {
	case a.Code == cards.Turn:
	case !cards.TakesTarget(a.Code) || !takesTarget(a.Opt):
		loseAim(p, c, seg, ReasonReveal, evs)
	default:
		// The target named: the markers move onto it within one hex (12.5).
		named := a.Hex
		if t := st.char(a.Target); a.Target >= 0 && t != nil {
			named = t.Hex
		}
		old := aimTarget(c, st)
		same := (a.Target >= 0 && a.Target == c.AimAt) || (a.Target < 0 && c.AimAt < 0 && a.Hex == c.AimHex)
		if board.Distance(old, named) > 1 {
			loseAim(p, c, seg, ReasonTransfer, evs)
		} else if !same && (old == c.Hex) != (named == c.Hex) {
			loseAim(p, c, seg, ReasonOwnHex, evs)
		} else if a.Opt == OptShoot || a.Opt == OptThrow {
			c.AimHex = a.Hex // "" when the shot names a character
			c.AimAt = a.Target
		}
	}
}

// pointFrom is the seat that gave the i-th of a wound's points, counted
// seat by seat through from; NoSeat past them (points nobody is put down
// for).
func pointFrom(from [MaxPlayers]int, i int) int {
	for q, n := range from {
		if i < n {
			return q
		}
		i -= n
	}
	return NoSeat
}

// hasKill tells whether a hit's penalties include a KILL.
func hasKill(pens []Penalty) bool {
	for _, pen := range pens {
		if pen.Kind == Kill {
			return true
		}
	}
	return false
}

func loseAim(p int, c *Character, seg int, reason string, evs *[]Event) {
	loseAimAt(p, c, seg, reason, "", evs)
}

// loseAimAt is loseAim with the hex the event names: the obstacle in the
// way when the target is out of sight.
func loseAimAt(p int, c *Character, seg int, reason, to string, evs *[]Event) {
	if c.Aim == 0 {
		return
	}
	clearAim(c)
	*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvLoseAim, Reason: reason, To: to})
}

// cardLine is which line of a drawn result card is read.
type cardLine int

const (
	delayLine   cardLine = iota // delay card (14.21): DELAY line, no endurance
	fatigueLine                 // fatigue card (14.22): DELAY line, crosses off endurance
	woundLine                   // wound card (14.23): WOUND line, crosses off endurance
)

// drawCard draws one result card for c and reads the chosen line: a number
// is delay points (and endurance boxes for fatigue and wound cards, put
// down to seat by, the enemy whose hit they come from, NoSeat for none); a
// penalty applies as in rule 14.11 (LOSE AIM, WILD SHOT fires every cocked
// gun, DROP turns the character DOWN and draws three more delay cards). One
// delay event is recorded per card drawn. It returns the delay points gained.
func drawCard(p int, c *Character, seg int, reason string, line cardLine, by int, d Drawer, evs *[]Event) (gained int) {
	card := d.Draw()
	res := card.Delay
	if line == woundLine {
		res = card.Wound
	}
	ev := Event{Seg: seg, Player: p, Kind: EvDelay, Reason: reason, Card: card.N, Result: res.String()}
	if res.IsPoints() {
		gained = int(res)
		ev.N = gained
		if line != delayLine {
			ev.Endurance = gained
			lost := gained
			if lost > c.Endurance {
				lost = c.Endurance
			}
			c.Endurance -= lost
			if by >= 0 && by < MaxPlayers {
				c.Hurt[by] += lost
			}
		}
	}
	*evs = append(*evs, ev)
	switch res {
	case LoseAim:
		loseAim(p, c, seg, res.String(), evs)
	case WildShot:
		wildShot(p, c, seg, evs)
		loseAim(p, c, seg, res.String(), evs)
	case Drop:
		gained += drop(p, c, seg, d, evs)
	}
	return gained
}

// drawDelay draws one delay card (14.21).
func drawDelay(p int, c *Character, seg int, reason string, d Drawer, evs *[]Event) int {
	return drawCard(p, c, seg, reason, delayLine, NoSeat, d, evs)
}

// drop is the DROP penalty (14.11): an upright character turns DOWN, draws
// three delay cards and loses its aim; no effect when already DOWN.
func drop(p int, c *Character, seg int, d Drawer, evs *[]Event) (gained int) {
	if c.Down {
		return 0
	}
	c.Down = true
	c.Dropped = true
	*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvFlip, Down: true})
	for i := 0; i < 3; i++ {
		gained += drawDelay(p, c, seg, ReasonDrop, d, evs)
	}
	loseAim(p, c, seg, ReasonDrop, evs)
	return gained
}

// wildShot fires every cocked gun of c without effect (rule 14.11).
func wildShot(p int, c *Character, seg int, evs *[]Event) {
	for i := range c.Guns {
		if c.Guns[i].Type != NoGun && c.Guns[i].Cocked {
			fireHarmlessly(p, &c.Guns[i], seg, evs)
		}
	}
}

// fireHarmlessly is one gun going off without hitting anything: uncocked,
// one shell less.
func fireHarmlessly(p int, g *Gun, seg int, evs *[]Event) {
	g.Cocked = false
	if g.Shells > 0 {
		g.Shells--
	}
	*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvWildShot, From: g.Location.String(), Gun: g.Type, GunID: g.ID})
}

// shoot resolves a shot (13): the gun must be cocked, loaded and in a box it
// fires from, else the action is cancelled; the target is hit only inside
// the aim zone, a shot out of it still draws its card and misses (11.32,
// 13.1, 13.2). A MALFUNCTION with no effect is replaced; a
// misfire cancels the shot and a second draw may jam or blow up the gun.
// The shooter then uncocks, spends a shell and loses the aim (13.9). A shot
// at a hex nobody stands in when it comes up, at a target out of sight
// (31), or at a character out of the fight (killed or passed out, 12.6,
// 14.6; surrendered or run away), is held, as a Shoot doing nothing: no card, no shell, the gun stays
// cocked and the aim is kept. It returns the seat shot at (NoSeat when
// nobody was) and the IMPACT TABLE results of a hit, inflicted at the end
// of the segment.
func shoot(board *hex.Board, p int, st *State, a Action, seg int, d Drawer, evs *[]Event) (int, []Penalty) {
	c := &st.Chars[p]
	cancelAt := func(reason, to string) []Penalty {
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvCancel, Action: a.Code, Reason: reason, To: to})
		return nil
	}
	cancel := func(reason string) []Penalty { return cancelAt(reason, "") }
	// The target: the character named, or whoever stands in the hex named
	// when the shot comes up; nobody there, the shot is held.
	target := a.Target
	at := a.Hex
	if target < 0 {
		if !board.Has(at) {
			return NoSeat, cancel(ReasonNoHex)
		}
		target = standingIn(st, at, p)
		if target < 0 {
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvNothing, Action: a.Code, To: at, Reason: ReasonEmptyHex})
			return NoSeat, nil
		}
	}
	t := st.char(target)
	if t != nil {
		at = t.Hex
	}
	// A character named who fell before the shot came up can no longer be
	// shot at (12.6, 14.6): the player would have named another target, or
	// done nothing (11.3), when revealing it; a plan fixed at the start of
	// the turn cannot, so the shot is held.
	if t != nil && target != p && t.Status != Alive {
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvNothing, Action: a.Code, To: at, Target: target, Reason: ReasonOutOfFight})
		return NoSeat, nil
	}
	// The target, a character either way by now, out of sight (31) holds
	// the shot like an empty hex: nothing fires, the aim stays where it is.
	if t != nil && t.Status == Alive && target != p {
		if clear, _ := canSee(board, c, at, t); !clear {
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvNothing, Action: a.Code, To: at, Target: target, Reason: ReasonNoLOS})
			return target, nil
		}
	}
	slot := c.Guns.Firing()
	if slot < 0 {
		return target, cancel(ReasonNoGun)
	}
	g := &c.Guns[slot]
	switch {
	case g.Exploded:
		return target, cancel(ReasonBroken)
	case g.Jammed:
		return target, cancel(ReasonJammed)
	case g.Shells == 0:
		return target, cancel(ReasonEmpty)
	case !g.Cocked:
		return target, cancel(ReasonNotCocked)
	case t == nil || target == p || t.Status != Alive:
		return target, cancel(ReasonNoTarget)
	}
	spec := g.Type.Spec()
	aim := a.AimTime(spec.OneHanded) + c.Aim
	if g.Location == GunHand || g.Location == BothHands {
		aim -= c.GunArm
	}
	if g.Location == OtherHand || g.Location == BothHands {
		aim -= c.OtherArm
	}
	rng := board.Distance(c.Hex, at)
	// Out of the aim zone the shot automatically misses, but the card is
	// drawn all the same (11.32, 13.1, 13.2).
	inZone := board.InAimZone(c.Hex, c.Facing, at)

	// Draw (13.2): a MALFUNCTION with no effect is replaced; a misfire
	// cancels the shot and draws again for the gun (13.3, 13.31).
	var card ResultCard
	var malfs []Event // logged after the shot
	misfire := false
	for tries := 0; tries < DeckSize; tries++ {
		card = d.Draw()
		if card.IsFire() {
			break
		}
		if !card.Malf.Handloaded { // the Colt 45 takes handloaded shells (26.2)
			malfs = append(malfs, Event{Seg: seg, Player: p, Kind: EvMalfunction, Card: card.N, Result: MalfNoEffect, Gun: g.Type, GunID: g.ID})
			continue
		}
		misfire = true
		malfs = append(malfs, Event{Seg: seg, Player: p, Kind: EvMalfunction, Card: card.N, Result: MalfMisfire, Gun: g.Type, GunID: g.ID})
		second := d.Draw()
		result := MalfNoPenalty
		if !second.IsFire() {
			result = second.Malf.Second
			if result == GunJams {
				g.Shells = 0
				g.Jammed = true
			} else {
				g.Exploded = true
			}
		}
		malfs = append(malfs, Event{Seg: seg, Player: p, Kind: EvMalfunction, Card: second.N, Result: result, Gun: g.Type, GunID: g.ID})
		break
	}
	hit := Miss
	ev := Event{Seg: seg, Player: p, Kind: EvShot, Action: a.Code, Card: card.N, Target: target, To: at, Range: rng, N: aim, Gun: g.Type, GunID: g.ID}
	switch {
	case misfire:
		ev.Reason = ReasonMisfire
	case !inZone:
		ev.Reason = ReasonOutOfZone
	default:
		prelim := card.Fire.Lookup(aim, rng)
		ev.Chart = string(prelim)
		hit, ev.Status = targetStatus(card, prelim, t)
		if hit == Bullseye { // the shooter picks the location (13.7): the deadliest
			hit = VitalHit
		}
	}
	ev.Hit = string(hit)
	// The shot first, then the MALFUNCTION cards it drew.
	*evs = append(*evs, ev)
	*evs = append(*evs, malfs...)

	// After the shot (13.9), even on a misfire.
	g.Cocked = false
	if g.Shells > 0 {
		g.Shells--
	}
	loseAim(p, c, seg, ReasonShot, evs)
	if hit == Miss {
		return target, nil
	}
	return target, Impact(spec.Impact, hit)
}

// throw resolves a THROW (17): the weapon in the proper box (one-handed in
// the gun hand or both hands, 16.2) is thrown at the target named, a
// character or whoever stands in the hex named when it comes up, held like
// a shot when there is nobody to hit (an empty hex, a target out of sight
// or out of the fight: nothing thrown, the aim kept). Bare hands cannot
// throw, and a target farther than the weapon's wielding factor (plus
// STRENGTH, 20.22) cannot be thrown at (17.2): both cancel it. A hit card
// is drawn, MALFUNCTION cards ignored (17.3); aim time and range read the
// hit chart, Target Status applies, a bullseye goes where it hurts most,
// and a target out of the aim zone is missed (17.12). The weapon lands in
// the target's hex on a hit, else in the hex next to it a direction card
// names (17.4): from the target's facing for a character named, towards
// the thrower being ahead for a hex named; "long" carries on the thrower's
// line, "same" and a hex off the map leave it in the target's hex. The
// thrower then loses its aim (16.13). It returns the seat thrown at and
// the STRIKING TABLE results of a hit, with STRENGTH's damage (20.21),
// inflicted at the end of the segment.
func throw(board *hex.Board, p int, st *State, a Action, seg int, d Drawer, evs *[]Event) (int, []Penalty) {
	c := &st.Chars[p]
	cancel := func(reason string) []Penalty {
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvCancel, Action: a.Code, Reason: reason})
		return nil
	}
	target := a.Target
	at := a.Hex
	if target < 0 {
		if !board.Has(at) {
			return NoSeat, cancel(ReasonNoHex)
		}
		target = standingIn(st, at, p)
		if target < 0 {
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvNothing, Action: a.Code, To: at, Reason: ReasonEmptyHex})
			return NoSeat, nil
		}
	}
	t := st.char(target)
	if t == nil || target == p {
		return NoSeat, cancel(ReasonNoTarget)
	}
	at = t.Hex
	if t.Status != Alive {
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvNothing, Action: a.Code, To: at, Target: target, Reason: ReasonOutOfFight})
		return NoSeat, nil
	}
	if clear, _ := canSee(board, c, at, t); !clear {
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvNothing, Action: a.Code, To: at, Target: target, Reason: ReasonNoLOS})
		return target, nil
	}
	slot := c.Guns.Firing()
	if slot < 0 {
		return target, cancel(ReasonNoGun)
	}
	g := c.Guns[slot]
	spec := g.Type.Spec()
	rng := board.Distance(c.Hex, at)
	if rng > spec.Wielding+a.Wield {
		return target, cancel(ReasonOutOfRange)
	}
	aim := a.AimTime(spec.OneHanded) + c.Aim
	if g.Location == GunHand || g.Location == BothHands {
		aim -= c.GunArm
	}
	if g.Location == OtherHand || g.Location == BothHands {
		aim -= c.OtherArm
	}
	inZone := board.InAimZone(c.Hex, c.Facing, at)
	var card ResultCard
	for tries := 0; tries < DeckSize; tries++ {
		if card = d.Draw(); card.IsFire() {
			break
		}
	}
	hit := Miss
	ev := Event{Seg: seg, Player: p, Kind: EvThrow, Action: a.Code, Card: card.N, Target: target, To: at, Range: rng, N: aim, Gun: g.Type, GunID: g.ID}
	if !inZone {
		ev.Reason = ReasonOutOfZone
	} else if card.IsFire() {
		prelim := card.Fire.Lookup(aim, rng)
		ev.Chart = string(prelim)
		hit, ev.Status = targetStatus(card, prelim, t)
		if hit == Bullseye { // the thrower's choice
			hit = StrikingBullseye(spec.Striking)
		}
	}
	ev.Hit = string(hit)
	*evs = append(*evs, ev)
	lands := at
	if hit == Miss {
		dirCard := d.Draw()
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvDirection, Card: dirCard.N, To: string(dirCard.Hex)})
		if dir, ok := landing(board, c, t, a.Target >= 0, dirCard.Hex); ok {
			if to, ok := board.Neighbor(at, dir); ok {
				lands = to
			}
		}
	}
	putDown(p, c, slot, lands, ReasonThrow, seg, st, evs)
	loseAim(p, c, seg, ReasonThrow, evs)
	if hit == Miss {
		return target, nil
	}
	return target, Strengthen(Striking(spec.Striking, hit), a.Damage)
}

// landing turns the direction card drawn for a missed throw into the
// direction from the target to the hex where the weapon lands (17.4):
// relative to the facing of a character named, or to the direction
// towards the thrower for a hex named; "long" carries on the thrower's
// line, "same" names no direction.
func landing(board *hex.Board, thrower, t *Character, named bool, h hex.Rel) (hex.Dir, bool) {
	if named || h == hex.Same || h == hex.Long {
		return directionOf(board, t, thrower, h)
	}
	back := (board.LongDir(thrower.Hex, t.Hex, thrower.Facing) + 3) % 6
	return hex.Resolve(back, h), true
}

// targetStatus applies the card's Target Status entries to a preliminary
// hit (13.6): for Move and Run, a bullseye becomes the card's lesser hit
// and any other hit a miss; for Down, any hit but a bullseye misses. Head
// counters are not played. It also returns the letters of the entries
// that changed the hit.
func targetStatus(card ResultCard, hit HitLoc, t *Character) (HitLoc, string) {
	if hit == Miss {
		return Miss, ""
	}
	applied := ""
	lesser := card.Fire.Lesser()
	listed := func(s byte) bool { return strings.IndexByte(card.Status, s) >= 0 }
	for _, s := range []struct {
		letter byte
		on     bool
	}{{StatusMove, t.PlayedFoot || t.Dropped}, {StatusRun, t.PlayedRun}} {
		if !listed(s.letter) || !s.on {
			continue
		}
		applied += string(s.letter)
		if hit != Bullseye {
			return Miss, applied
		}
		hit = lesser
	}
	if listed(StatusDown) && t.Down && hit != Bullseye {
		return Miss, applied + string(StatusDown)
	}
	return hit, applied
}

// applyPenalties inflicts the results of a hit on seat p (14.11, 14.12),
// stopping once the character is out of the fight; the shooter is put down
// as the one who did it (15.2, 15.3). It returns the delay points gained.
func applyPenalties(board *hex.Board, p int, st *State, r pending, seg int, d Drawer, evs *[]Event) (gained int) {
	c := &st.Chars[p]
	// Killed by an earlier shooter's KILL of this same segment (a character
	// already out cannot be shot): this KILL lands simultaneously, they
	// share the kill (15.2).
	if c.Status == Killed && hasKill(r.pens) {
		c.Killers[r.from] = true
	}
	for _, pen := range r.pens {
		if c.Status != Alive {
			break
		}
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvWound, Result: string(pen.Kind), N: pen.N})
		switch pen.Kind {
		case Kill:
			kill(c, seat(r.from))
			dropAllGuns(p, c, seg, st, evs)
		case Stun:
			for i := 0; i < pen.N; i++ {
				gained += drawCard(p, c, seg, ReasonStun, woundLine, r.from, d, evs)
			}
			loseAim(p, c, seg, string(Stun), evs)
		case Stagger:
			gained += stagger(board, p, c, &st.Chars[r.from], seg, d, evs)
		case Serious:
			c.Serious += pen.N
			c.SeriousFrom[r.from] += pen.N
		case DropGunHand:
			dropHand(p, c, GunHand, OtherHand, seg, st, evs)
			loseAim(p, c, seg, string(DropGunHand), evs)
		case DropOtherHand:
			dropHand(p, c, OtherHand, GunHand, seg, st, evs)
			loseAim(p, c, seg, string(DropOtherHand), evs)
		case GunArm:
			c.GunArm += pen.N
		case OtherArm:
			c.OtherArm += pen.N
		case LegWound:
			c.Leg += pen.N
			c.LegFrom[r.from] += pen.N
		case Light:
			for i := 0; i < pen.N; i++ {
				gained += drawCard(p, c, seg, ReasonLight, fatigueLine, r.from, d, evs)
			}
		case LoseAimHit:
			loseAim(p, c, seg, string(LoseAimHit), evs)
		}
	}
	return gained
}

// stagger is the STAGGER penalty (14.11): an upright character is thrown to
// the hex named by a first direction card, turns as named by a second one,
// and drops. A hex off the board keeps it in place.
func stagger(board *hex.Board, p int, c *Character, shooter *Character, seg int, d Drawer, evs *[]Event) (gained int) {
	if c.Down {
		return 0
	}
	first, second := d.Draw(), d.Draw()
	*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvDirection, Card: first.N, To: string(first.Hex)})
	*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvDirection, Card: second.N, To: string(second.Hex)})
	if dir, ok := directionOf(board, c, shooter, first.Hex); ok {
		if to, ok := board.Neighbor(c.Hex, dir); ok {
			from := c.Hex
			c.Hex = to
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvMove, From: from, To: to, Facing: c.Facing, Down: c.Down, Reason: ReasonStagger})
			gained += terrain(board, p, c, from, dir, seg, d, evs)
		}
	}
	if dir, ok := directionOf(board, c, shooter, second.Hex); ok && dir != c.Facing {
		c.Facing = dir
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvTurn, Facing: c.Facing, Reason: ReasonStagger})
	}
	return gained + drop(p, c, seg, d, evs)
}

// terrain is the penalty of the ground crossed by a move or a stagger from
// the hex from in direction dir, to c's hex: two delay cards across a fence
// (35.2), two more onto or off an obstacle (36.4; none from one obstacle
// hex to another).
func terrain(board *hex.Board, p int, c *Character, from string, dir hex.Dir, seg int, d Drawer, evs *[]Event) (gained int) {
	if board.Fenced(from, dir) {
		for i := 0; i < 2; i++ {
			gained += drawDelay(p, c, seg, ReasonFence, d, evs)
		}
	}
	if board.Obstacle(from) != board.Obstacle(c.Hex) {
		for i := 0; i < 2; i++ {
			gained += drawDelay(p, c, seg, ReasonObstacle, d, evs)
		}
	}
	return gained
}

// directionOf turns a direction card's HEX line into an absolute direction
// from the target c (14.3): relative lines are taken from its facing,
// "long" continues the shooter's line, "same" names no direction.
func directionOf(board *hex.Board, c *Character, shooter *Character, h hex.Rel) (hex.Dir, bool) {
	switch h {
	case hex.Same:
		return 0, false
	case hex.Long:
		return board.LongDir(shooter.Hex, c.Hex, shooter.Facing), true
	}
	return hex.Resolve(c.Facing, h), true
}

// dropHand is the GUN HAND / OTHER HAND penalty (14.11): the weapon in that
// hand falls in the hex (a cocked gun going off), and a weapon in both
// hands moves to the other hand.
func dropHand(p int, c *Character, hand, other GunLocation, seg int, st *State, evs *[]Event) {
	if i := c.Guns.At(hand); i >= 0 {
		dropGun(p, c, i, true, "", seg, st, evs)
	}
	if i := c.Guns.At(BothHands); i >= 0 {
		c.Guns[i].Location = other
	}
}

// ActionGunMove names a gun move in its cancel event.
const ActionGunMove cards.Code = "gun_move"

// moveGun does a gun move as its action is revealed (10.22): the gun in
// BOTH HANDS to one hand, as it is, or a gun in a hand box dropped in the
// hex (a cocked one going off harmlessly). Dropping the gun it would fire
// (gun hand or both hands) loses the aim, the points spent aiming it (as a
// GUN HAND wound does, 12.42). A move the gun no longer allows (gone, not
// in a hand, not in both hands) is cancelled.
func moveGun(p int, st *State, m GunMove, seg int, evs *[]Event) {
	c := &st.Chars[p]
	cancel := func(reason string) {
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvCancel, Action: ActionGunMove, Reason: reason, GunID: m.Gun})
	}
	i := c.Guns.Find(m.Gun)
	if i < 0 {
		cancel(ReasonNoGun)
		return
	}
	g := &c.Guns[i]
	if m.To == HandGround {
		if g.Location == Holstered {
			cancel(ReasonNotInHand)
			return
		}
		aimed := g.Location == GunHand || g.Location == BothHands
		dropGun(p, c, i, true, ReasonGunMove, seg, st, evs)
		if aimed && c.Aim > 0 {
			loseAim(p, c, seg, ReasonGunDropped, evs)
		}
		return
	}
	if g.Location != BothHands {
		cancel(ReasonNotBoth)
		return
	}
	// A gun in BOTH HANDS leaves no hand to another gun: the hand is free.
	to, _ := HandLocation(m.To)
	*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvMoveGun, From: g.Location.String(), To: to.String(), Gun: g.Type, GunID: g.ID})
	g.Location = to
}

// dropGun lets the gun in slot i fall in the character's hex, where it lies
// unowned with a fresh ground id; fire makes a cocked gun go off as it
// falls (a released or knocked-out gun, 10.22, 14.11); reason goes on the
// drop event, ReasonGunMove for a gun let go.
func dropGun(p int, c *Character, i int, fire bool, reason string, seg int, st *State, evs *[]Event) {
	if fire && c.Guns[i].Cocked {
		fireHarmlessly(p, &c.Guns[i], seg, evs)
	}
	putDown(p, c, i, c.Hex, reason, seg, st, evs)
}

// putDown takes the gun in slot i off c's sheet and lays it in hex at,
// unowned with a fresh ground id, as it is.
func putDown(p int, c *Character, i int, at, reason string, seg int, st *State, evs *[]Event) {
	g := &c.Guns[i]
	dropped := *g
	dropped.Location = Holstered
	st.GroundSeq++
	st.Ground = append(st.Ground, GroundGun{ID: st.GroundSeq, Hex: at, Gun: dropped})
	*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvDropGun, From: g.Location.String(), To: at, Gun: g.Type, GunID: g.ID, N: st.GroundSeq, Reason: reason})
	*g = Gun{}
}

// dropAllGuns is what happens to the weapons of a character killed or
// passed out (14.6): they all fall in the hex as they are, where anyone can
// take them; nothing goes off.
func dropAllGuns(p int, c *Character, seg int, st *State, evs *[]Event) {
	for i := range c.Guns {
		if c.Guns[i].Type != NoGun {
			dropGun(p, c, i, false, "", seg, st, evs)
		}
	}
}

// execute runs one action other than a shot, mutating seat p's character
// (and st for the guns on the ground). It returns the delay points gained
// and whether the action took effect.
func execute(board *hex.Board, p int, a Action, st *State, seg int, d Drawer, evs *[]Event) (gained int, executed bool) {
	c := &st.Chars[p]
	cancelAt := func(reason, to string) (int, bool) {
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvCancel, Action: a.Code, Reason: reason, To: to})
		return gained, false
	}
	cancel := func(reason string) (int, bool) { return cancelAt(reason, "") }
	// move takes the character one hex in dir; off the map it runs away
	// (15.5): it leaves the showdown, guns and all, and the move counts as
	// done.
	move := func(dir hex.Dir) bool {
		to, ok := board.Neighbor(c.Hex, dir)
		if !ok {
			c.Status = RanAway
			clearAim(c)
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvRunAway, Action: a.Code, From: c.Hex, Facing: dir})
			return true
		}
		from := c.Hex
		c.Hex = to
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvMove, Action: a.Code, From: from, To: to, Facing: c.Facing, Down: c.Down})
		if c.Down { // crawl penalty (9.2): a fixed 2 delay, no card
			gained += 2
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvDelay, N: 2, Reason: ReasonCrawl})
		} else {
			for i := 0; i < c.Leg; i++ { // LEG wound (14.12), each card put down to the seat whose wound gave it
				gained += drawCard(p, c, seg, ReasonLeg, fatigueLine, pointFrom(c.LegFrom, i), d, evs)
			}
		}
		gained += terrain(board, p, c, from, dir, seg, d, evs)
		return true
	}

	switch a.Code {
	case cards.Advance, cards.Run, cards.BackUp:
		ok := move(hex.Resolve(c.Facing, a.Dir))
		return gained, ok
	case cards.Sprint:
		if !move(c.Facing) || c.Status != Alive { // straight ahead (9.23); gone off the map, nothing more
			return gained, true
		}
		gained += drawDelay(p, c, seg, ReasonSprint, d, evs)
		return gained, true
	case cards.Turn, cards.SpinAround:
		c.Facing = hex.Resolve(c.Facing, a.Dir)
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvTurn, Action: a.Code, Facing: c.Facing})
		return 0, true
	case cards.GetUpDown:
		c.Down = !c.Down
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvFlip, Action: a.Code, Down: c.Down})
		return 0, true
	case cards.LeapDrop:
		c.Down = !c.Down
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvFlip, Action: a.Code, Down: c.Down})
		// Two delay cards (9.4).
		gained += drawDelay(p, c, seg, ReasonLeap, d, evs)
		gained += drawDelay(p, c, seg, ReasonLeap, d, evs)
		return gained, true
	case cards.DrawAndCock:
		dest, ok := HandLocation(a.Hand)
		if !ok {
			return cancel(ReasonNoGun)
		}
		if a.Ground > 0 {
			// Pick a weapon up from the hex into the hand and cock it (11.1,
			// 11.11): it gets a fresh id on this character's sheet.
			gi := -1
			for i, gg := range st.Ground {
				if gg.ID == a.Ground && gg.Hex == c.Hex {
					gi = i
				}
			}
			if gi < 0 {
				return cancel(ReasonNoGun)
			}
			if c.Guns.At(dest) >= 0 {
				return cancel(ReasonHandFull)
			}
			slot := c.Guns.Free()
			if slot < 0 {
				return cancel(ReasonNoRoom)
			}
			g := st.Ground[gi].Gun
			g.ID = c.Guns.NextID()
			g.Location = dest
			g.Cocked = !g.Jammed // a jammed gun cannot be cocked until completely reloaded (13.31)
			c.Guns[slot] = g
			st.Ground = append(st.Ground[:gi:gi], st.Ground[gi+1:]...)
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvDraw, Action: a.Code, From: "ground", To: dest.String(), Gun: g.Type, GunID: g.ID, N: a.Ground, Result: jammedResult(g)})
			return 0, true
		}
		// Move the chosen gun from its box (a holster, or a hand) to the
		// one named and cock it (11.1).
		slot := c.Guns.Find(a.Gun)
		if slot < 0 || c.Guns[slot].Location == dest {
			return cancel(ReasonNoGun)
		}
		if c.Guns.Blocked(dest, slot) {
			return cancel(ReasonHandFull)
		}
		g := &c.Guns[slot]
		from := g.Location
		g.Location = dest
		g.Cocked = !g.Jammed // a jammed gun cannot be cocked until completely reloaded (13.31)
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvDraw, Action: a.Code, From: from.String(), To: dest.String(), Gun: g.Type, GunID: g.ID, Result: jammedResult(*g)})
		return 0, true
	case cards.Load:
		// One shell into the gun in BOTH HANDS (11.2, 27.2), which uncocks
		// it; a jammed gun fires again once completely reloaded (13.31).
		slot := c.Guns.At(BothHands)
		if slot < 0 {
			return cancel(ReasonNoGun)
		}
		g := &c.Guns[slot]
		if g.Exploded {
			return cancel(ReasonBroken)
		}
		capacity := g.Type.Spec().Capacity
		if g.Shells >= capacity {
			return cancel(ReasonFull)
		}
		g.Shells++
		g.Cocked = false
		ev := Event{Seg: seg, Player: p, Kind: EvLoad, Action: a.Code, N: g.Shells, Gun: g.Type, GunID: g.ID}
		if g.Jammed && g.Shells == capacity {
			g.Jammed = false
			ev.Result = LoadUnjammed
		}
		*evs = append(*evs, ev)
		return 0, true
	case cards.Throw: // a throw resolves with the shots; this one does nothing (17.1)
		*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvNothing, Action: a.Code})
		return 0, true
	case cards.CockAimShoot, cards.Shoot:
		if a.Opt == OptNothing {
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvNothing, Action: a.Code})
			return 0, true
		}
		slot := c.Guns.Firing() // a gun in the proper box (11.3)
		if slot < 0 {
			return cancel(ReasonNoGun)
		}
		g := &c.Guns[slot]
		if g.Exploded { // useless for the rest of the game (13.31)
			return cancel(ReasonBroken)
		}
		switch a.Opt {
		case OptCock:
			if g.Jammed { // not before it is completely reloaded (13.31)
				return cancel(ReasonJammed)
			}
			g.Cocked = true
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvCock, Action: a.Code, Gun: g.Type, GunID: g.ID})
		case OptUncock:
			g.Cocked = false
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvUncock, Action: a.Code, Gun: g.Type, GunID: g.ID})
		case OptAim:
			// Two AIM points (12.1, 12.2) on the target named: a character,
			// wherever it is, or a hex; either must be in the aim zone.
			hexAt := a.Hex
			var at *Character
			if a.Target >= 0 {
				at = st.char(a.Target)
				if at == nil || a.Target == p || at.Status != Alive {
					return cancel(ReasonNoTarget)
				}
				hexAt = at.Hex
			} else if !board.Has(a.Hex) {
				return cancel(ReasonNoHex)
			}
			if !board.InAimZone(c.Hex, c.Facing, hexAt) {
				return cancel(ReasonOutOfZone)
			}
			// ...and in sight (31.1): a target behind the trough cannot be aimed at.
			if clear, blocker := canSee(board, c, hexAt, at); !clear {
				return cancelAt(ReasonNoLOS, blocker)
			}
			c.Aim += 2
			if c.Aim > MaxAim {
				c.Aim = MaxAim
			}
			c.AimHex = a.Hex // "" for a character: the markers follow it
			c.AimAt = a.Target
			*evs = append(*evs, Event{Seg: seg, Player: p, Kind: EvAim, Action: a.Code, To: hexAt, Target: a.Target, N: c.Aim})
		}
		return 0, true
	}
	// Not implemented yet (loading, throwing, brawling): Validate rejects these upfront.
	return cancel("unsupported")
}
