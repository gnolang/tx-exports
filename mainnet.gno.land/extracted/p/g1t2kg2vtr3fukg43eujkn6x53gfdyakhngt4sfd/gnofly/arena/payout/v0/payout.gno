package payout

import "errors"

// Death is one life lost in a round: Victim was shot down by Killer, or by
// nobody (a crash, a disconnect). A pilot dies up to Game.Lives times and is
// out after the last one.
type Death struct {
	Victim address
	Killer address // "" when nobody shot the victim down
}

// Game is what a rule needs to know about the arena a round was played in.
type Game struct {
	Stake      int64 // ugnot, what each player paid
	Lives      int64 // deaths a player can take, the last one puts them out
	KillTarget int64 // kills that end the round, 0 for the clock only
	FeeBps     int64 // the house's share, in basis points
}

// Payout is an amount of ugnot to send to an address.
type Payout struct {
	Address address
	Amount  int64 // ugnot
}

// Result is what a rule decides: who gets what, and the house's cut.
type Result struct {
	Payouts []Payout // in the order of the players, players paid nothing left out
	Fee     int64
}

// Rule turns what happened in a round into who gets what.
type Rule interface {
	Mode() string
	Settle(g Game, players []address, deaths []Death) (Result, error)
}

// The modes of the rules shipped with the package.
const (
	ModeBattleRoyale = "battle-royale"
	ModeDeathmatch   = "deathmatch"
)

// Bounds every rule enforces.
const (
	MinPlayers    = 2
	MaxPlayers    = 8
	MinLives      = 1
	MaxLives      = 3
	MaxKillTarget = 20
	MinStake      = 1             // ugnot
	MaxStake      = 1000000000000 // ugnot, 1e12
	BpsScale      = 10000         // basis points in a whole
	MaxFeeBps     = 5000          // the fee never takes more than half
	MaxDeaths     = MaxPlayers * MaxLives
)

var (
	ErrStake           = errors.New("payout: stake must be between 1 and 1000000000000 ugnot")
	ErrLives           = errors.New("payout: lives must be between 1 and 3")
	ErrKillTarget      = errors.New("payout: the kill target must be between 0 and 20")
	ErrFee             = errors.New("payout: the fee must be between 0 and 5000 bps")
	ErrTooFewPlayers   = errors.New("payout: at least 2 players are required")
	ErrTooManyPlayers  = errors.New("payout: at most 8 players are allowed")
	ErrEmptyPlayer     = errors.New("payout: a player has no address")
	ErrDuplicatePlayer = errors.New("payout: a player is listed twice")
	ErrUnknownVictim   = errors.New("payout: a victim is not a player of the round")
	ErrDeadTooOften    = errors.New("payout: a player died more often than they have lives")
	ErrUnknownKiller   = errors.New("payout: a killer is not a player of the round")
	ErrSelfKill        = errors.New("payout: a player cannot be their own killer")
	ErrTooManyDeaths   = errors.New("payout: more deaths than lives in the round")

	ErrNoPlayers     = errors.New("payout: players must list at least one address")
	ErrPlayersFormat = errors.New("payout: players must be comma-separated addresses")
	ErrDeathsFormat  = errors.New(`payout: deaths must be "victim:killer" entries separated by ";"`)
)

// Lookup returns the rule of a mode, or nil for a mode nobody knows.
func Lookup(mode string) Rule {
	switch mode {
	case ModeBattleRoyale:
		return BattleRoyale{}
	case ModeDeathmatch:
		return Deathmatch{}
	}
	return nil
}

// Modes lists the modes of the shipped rules. The slice is a fresh copy.
func Modes() []string {
	return []string{ModeBattleRoyale, ModeDeathmatch}
}

// tally is what happened in a round, per player.
type tally struct {
	deaths  []int64 // lives each player lost
	kills   []int64 // deaths credited to each player
	lastOut int     // the player whose last life went last, -1 when nobody is out
	first   int     // the first player to reach the kill target, -1 when nobody did
}

// out reports whether player i lost every life.
func (t tally) out(i int, lives int64) bool {
	return t.deaths[i] >= lives
}

// check enforces what every rule requires, and counts deaths and kills.
//
// A killer may be out already: a bullet still in flight. A dead pilot cannot
// die again, though: a victim takes at most Lives deaths.
func check(g Game, players []address, deaths []Death) (tally, error) {
	if g.Stake < MinStake || g.Stake > MaxStake {
		return tally{}, ErrStake
	}
	if g.Lives < MinLives || g.Lives > MaxLives {
		return tally{}, ErrLives
	}
	if g.KillTarget < 0 || g.KillTarget > MaxKillTarget {
		return tally{}, ErrKillTarget
	}
	if g.FeeBps < 0 || g.FeeBps > MaxFeeBps {
		return tally{}, ErrFee
	}
	n := len(players)
	if n < MinPlayers {
		return tally{}, ErrTooFewPlayers
	}
	if n > MaxPlayers {
		return tally{}, ErrTooManyPlayers
	}
	for i, p := range players {
		if p == "" {
			return tally{}, ErrEmptyPlayer
		}
		if indexOf(players[:i], p) >= 0 {
			return tally{}, ErrDuplicatePlayer
		}
	}
	if int64(len(deaths)) > int64(n)*g.Lives {
		return tally{}, ErrTooManyDeaths
	}

	t := tally{deaths: make([]int64, n), kills: make([]int64, n), lastOut: -1, first: -1}
	for _, d := range deaths {
		victim := indexOf(players, d.Victim)
		if victim < 0 {
			return tally{}, ErrUnknownVictim
		}
		if t.out(victim, g.Lives) {
			return tally{}, ErrDeadTooOften
		}
		if d.Killer != "" {
			if d.Killer == d.Victim {
				return tally{}, ErrSelfKill
			}
			killer := indexOf(players, d.Killer)
			if killer < 0 {
				return tally{}, ErrUnknownKiller
			}
			t.kills[killer]++
			if g.KillTarget > 0 && t.first < 0 && t.kills[killer] >= g.KillTarget {
				t.first = killer
			}
		}
		t.deaths[victim]++
		if t.out(victim, g.Lives) {
			t.lastOut = victim
		}
	}
	return t, nil
}

func indexOf(list []address, addr address) int {
	for i, a := range list {
		if a == addr {
			return i
		}
	}
	return -1
}

// afterFee returns what is left of amount once the fee is taken.
func afterFee(amount, feeBps int64) int64 {
	return amount * (BpsScale - feeBps) / BpsScale
}
