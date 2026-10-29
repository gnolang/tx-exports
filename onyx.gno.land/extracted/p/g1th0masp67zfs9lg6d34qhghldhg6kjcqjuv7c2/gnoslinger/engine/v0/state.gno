// Package engine is the pure, deterministic rules engine of a gunfight of
// two to four characters: plan parsing and validation, and the 5-segment
// resolution of a turn. It has no chain dependency so it can be unit-tested
// with gno test.
package engine

import "gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"

const (
	// MaxActionPoints is the time points a plan may spend in a turn (rule 7.3).
	MaxActionPoints = 5
	// Segments is the number of segments in a turn (rule 4.1).
	Segments = 5
	// EndOfTurn is the Seg of events recorded after segment 5 (cancelled
	// actions, passing out, the end-of-showdown check); turn-start events
	// (SERIOUS fatigue, aim lost on the first reveal) have Seg 0.
	EndOfTurn = Segments + 1
	// MinPlayers and MaxPlayers bound the seats of a game: the showdown's
	// characters (Setups) fill the seats in order, each a side of its own.
	MinPlayers = 2
	MaxPlayers = 4
)

// Status is the participation state of a character.
type Status int

const (
	// Alive characters plan and act.
	Alive Status = iota
	// Out characters (surrendered, or out of time) are skipped by Resolve.
	Out
	// Killed characters are out of the game (14.6).
	Killed
	// PassedOut characters carried more delay than endurance for two turns (14.2).
	PassedOut
	// RanAway characters moved off the map (15.5): out of the showdown,
	// their hex the edge hex they left from.
	RanAway
)

// String returns the status name used in JSON views.
func (s Status) String() string {
	switch s {
	case Alive:
		return "alive"
	case Out:
		return "out"
	case Killed:
		return "killed"
	case PassedOut:
		return "passed_out"
	case RanAway:
		return "ran_away"
	}
	return "?"
}

// StartEndurance is the endurance boxes a character starts with (14.2).
const StartEndurance = 20

// MaxAim is the most AIM points a character can hold on a target (12.3).
const MaxAim = 8

// NoSeat is the seat value for "nobody": AIM markers on a hex, a wound or a
// death nobody inflicted.
const NoSeat = -1

// Character is the mutable state of one gunslinger.
type Character struct {
	Hex    string
	Facing hex.Dir
	Down   bool
	Delay  int // delay points on the sheet (rule 6)
	Status Status
	// PlayedFoot and PlayedRun record whether the current turn's plan holds
	// a foot action / a Run, whether or not it executes ([H12], rules 13.61-62).
	PlayedFoot bool
	PlayedRun  bool
	// RanLastTurn is PlayedRun carried over from the previous turn: Sprint
	// needs a Run on the previous turn as well (rule 9.23, "build up speed").
	RanLastTurn bool
	// Dropped records a DROP penalty this turn ("Move" target status, 13.61).
	Dropped bool
	// Guns carried (section 10).
	Guns Guns
	// Aim is the AIM points on the target (12.2). AimAt is the seat of the
	// character the markers follow, wherever it goes (12.3), NoSeat when
	// they sit on the hex AimHex. Both are meaningless while Aim is 0.
	Aim    int
	AimAt  int
	AimHex string
	// Endurance is the boxes left on the sheet (14.2); wound and fatigue
	// cards cross them off.
	Endurance int
	// Exhausted counts the consecutive turn ends with more delay than
	// endurance; two in a row pass the character out (14.2).
	Exhausted int
	// Permanent wounds (14.12): fatigue cards per turn, aim time penalties
	// per hand, fatigue cards per hex moved upright.
	Serious  int
	GunArm   int
	OtherArm int
	Leg      int
	// Who did it, for the victory points (15.2, 15.21, 15.3), by seat: the
	// seats credited with the kill (several when their KILLs landed in the
	// same segment, or tied for the most SERIOUS points), the SERIOUS and
	// LEG points each seat's wounds gave (the fatigue those wounds cost
	// later is put down to it), and the endurance boxes each seat's hits
	// crossed off.
	Killers     [MaxPlayers]bool
	SeriousFrom [MaxPlayers]int
	LegFrom     [MaxPlayers]int
	Hurt        [MaxPlayers]int
}

// GroundGun is a weapon lying in a hex (10.21). ID identifies it on the
// ground for the whole game (plans refer to it as "g<ID>"); the gun's own
// ID was its previous owner's and is reassigned when picked up.
type GroundGun struct {
	ID  int
	Hex string
	Gun Gun
}

// State is the whole game state the engine acts on: one character per
// seat, in seat order.
type State struct {
	Chars     []Character
	Ground    []GroundGun
	GroundSeq int // last ground id handed out
}

// NewState is a showdown of n characters before anyone set up: each
// upright with its starting guns and endurance, standing nowhere yet (Hex
// "") until SetUp gives it its hex and facing ([H3], setup.gno).
func NewState(n int) State {
	chars := make([]Character, n)
	for i := range chars {
		chars[i] = newCharacter()
	}
	return State{Chars: chars}
}

// newCharacter is a character's sheet at the start of a showdown.
func newCharacter() Character {
	return Character{Guns: startingGuns(), Endurance: StartEndurance, AimAt: NoSeat}
}

// char is the character of a seat, nil for a seat the state does not have.
func (s *State) char(seat int) *Character {
	if seat < 0 || seat >= len(s.Chars) {
		return nil
	}
	return &s.Chars[seat]
}

// CloneChars copies the characters field by field. A plain copy of the
// slice is not enough on a node: a character written earlier in the same
// transaction stays shared with the live state, so a turn's stored start
// would show its end position.
func CloneChars(cs []Character) []Character {
	out := make([]Character, len(cs))
	for i, c := range cs {
		out[i] = Character{
			Hex:         c.Hex,
			Facing:      c.Facing,
			Down:        c.Down,
			Delay:       c.Delay,
			Status:      c.Status,
			PlayedFoot:  c.PlayedFoot,
			PlayedRun:   c.PlayedRun,
			RanLastTurn: c.RanLastTurn,
			Dropped:     c.Dropped,
			Aim:         c.Aim,
			AimAt:       c.AimAt,
			AimHex:      c.AimHex,
			Endurance:   c.Endurance,
			Exhausted:   c.Exhausted,
			Serious:     c.Serious,
			GunArm:      c.GunArm,
			OtherArm:    c.OtherArm,
			Leg:         c.Leg,
			Killers:     c.Killers,
			SeriousFrom: c.SeriousFrom,
			LegFrom:     c.LegFrom,
			Hurt:        c.Hurt,
		}
		for j, g := range c.Guns {
			out[i].Guns[j] = Gun{ID: g.ID, Type: g.Type, Location: g.Location, Cocked: g.Cocked, Shells: g.Shells, Jammed: g.Jammed, Exploded: g.Exploded}
		}
	}
	return out
}

// Budget is the time points seat p may plan this turn: the carried delay
// counts against the 5 points ([H5], rule 7.3).
func (s State) Budget(p int) int {
	b := MaxActionPoints - s.Chars[p].Delay
	if b < 0 {
		return 0
	}
	return b
}

// AliveCount counts the characters still in the fight.
func AliveCount(s State) int {
	n := 0
	for _, c := range s.Chars {
		if c.Status == Alive {
			n++
		}
	}
	return n
}

// EndTurn is the end-of-turn upkeep (rule 5.6): half of the delay points
// are removed, rounded up, the per-turn flags are cleared, and a character
// left with more delay than endurance for the second turn in a row passes
// out (14.2; checked after the halving). The state given is left as it is.
func EndTurn(s State) (State, []Event) {
	s.Chars = CloneChars(s.Chars)
	var evs []Event
	for p := range s.Chars {
		c := &s.Chars[p]
		c.Delay -= (c.Delay + 1) / 2
		c.RanLastTurn = c.PlayedRun
		c.PlayedFoot = false
		c.PlayedRun = false
		c.Dropped = false
		if c.Status != Alive {
			continue
		}
		if c.Delay > c.Endurance {
			c.Exhausted++
		} else {
			c.Exhausted = 0
		}
		if c.Exhausted >= 2 {
			c.Status = PassedOut
			c.Down = true
			clearAim(c)
			evs = append(evs, Event{Seg: EndOfTurn, Player: p, Kind: EvPassOut, Down: true})
			dropAllGuns(p, c, EndOfTurn, &s, &evs)
		}
	}
	return s, evs
}

// EndShowdown is the end-of-game check (14.5): every character with SERIOUS
// wounds draws a result card and is killed when its DELAY number plus the
// wound points reaches four; the enemy who gave the most SERIOUS points
// gets the kill, enemies tied for the most share it (15.21). The state
// given is left as it is.
func EndShowdown(s State, d Drawer) (State, []Event) {
	s.Chars = CloneChars(s.Chars)
	var evs []Event
	for p := range s.Chars {
		c := &s.Chars[p]
		if c.Status != Alive || c.Serious == 0 {
			continue
		}
		card := d.Draw()
		n := 0
		if card.Delay.IsPoints() {
			n = int(card.Delay)
		}
		evs = append(evs, Event{Seg: EndOfTurn, Player: p, Kind: EvSeriousCheck, Card: card.N, N: n + c.Serious})
		if n+c.Serious >= 4 {
			kill(c, mostSeats(c.SeriousFrom))
			evs = append(evs, Event{Seg: EndOfTurn, Player: p, Kind: EvWound, Result: string(Kill)})
			dropAllGuns(p, c, EndOfTurn, &s, &evs)
		}
	}
	return s, evs
}

// kill takes a character out of the game (14.6), killed by the seats
// marked in by (none when nobody's hit did it): down, no delay marker, no
// endurance left.
func kill(c *Character, by [MaxPlayers]bool) {
	c.Status = Killed
	c.Down = true
	clearAim(c)
	c.Delay = 0
	c.Endurance = 0
	c.Killers = by
}

// seat marks one seat, none for NoSeat.
func seat(p int) (out [MaxPlayers]bool) {
	if p >= 0 && p < MaxPlayers {
		out[p] = true
	}
	return out
}

// mostSeats marks the seats with the most points, every one of them on a
// tie; none when nobody has any.
func mostSeats(pts [MaxPlayers]int) (out [MaxPlayers]bool) {
	most := 0
	for _, n := range pts {
		if n > most {
			most = n
		}
	}
	if most == 0 {
		return out
	}
	for q, n := range pts {
		out[q] = n == most
	}
	return out
}

// clearAim takes the AIM markers off the sheet.
func clearAim(c *Character) {
	c.Aim = 0
	c.AimAt = NoSeat
	c.AimHex = ""
}
