// Package shootout holds the state types of gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shots:
// games, challengers' sessions and their kicks.
//
// They live in a package rather than in the realm because gno only lets a
// realm's own code allocate the types that realm declares, and the game's
// rules engine runs in a separate, upgradeable implementation realm. Declared
// here, both realms can build and read them, and like the realm's storage
// they never change once deployed.
package shootout

import "gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/v0"

// GameStatus is where a game is in its life.
type GameStatus uint8

const (
	GameOpen      GameStatus = iota + 1 // waiting for a challenger
	GamePlaying                         // a challenger is playing a shootout
	GameWon                             // a challenger won the pot; closed
	GameCancelled                       // the creator withdrew it before anyone played; closed
)

func (s GameStatus) String() string {
	switch s {
	case GameOpen:
		return "open"
	case GamePlaying:
		return "playing"
	case GameWon:
		return "won"
	case GameCancelled:
		return "cancelled"
	}
	return "unknown"
}

// Game is a pot and the constants it is played for.
type Game struct {
	ID            uint64
	Creator       address
	Config        penalty.Config
	EntryFee      int64 // ugnot a challenger pays into the pot to play
	TimeoutBlocks int64 // a challenger idle this long may be forfeited by anyone
	Pot           int64 // ugnot
	Status        GameStatus
	Sessions      int // challengers so far; while playing, the live session is number Sessions
	Winner        address
	CreatedHeight int64
	ClosedHeight  int64
}

// SessionStatus is how a challenger's shootout stands.
type SessionStatus uint8

const (
	SessionPlaying SessionStatus = iota + 1
	SessionWon
	SessionLost
	SessionForfeited
)

func (s SessionStatus) String() string {
	switch s {
	case SessionPlaying:
		return "playing"
	case SessionWon:
		return "won"
	case SessionLost:
		return "lost"
	case SessionForfeited:
		return "forfeited"
	}
	return "unknown"
}

// Kick is one kick of a shootout, with everything needed to re-run it:
// penalty.SimulateShot(Shot, Plan, game.Config) == Result. Seed is the
// 32 bytes that completed it, derived from the block it was played in.
type Kick struct {
	Round  int
	Kicker penalty.Side
	Shot   penalty.ShotParams
	Plan   penalty.KeeperPlan
	Seed   penalty.Seed
	Result penalty.Result
	Height int64 // block the kick was played in
	Time   int64 // its block time, unix nanoseconds (the seed's source)
}

// Session is one challenger's shootout against the chain.
type Session struct {
	GameID           uint64
	No               int
	Player           address
	Paid             int64
	Score            penalty.Shootout
	Kicks            []Kick
	Status           SessionStatus
	JoinHeight       int64
	LastActionHeight int64
	EndHeight        int64
}

// Next says what the session is waiting for: "shoot", "keep", or "none" once
// it is over.
func (s Session) Next() string {
	if s.Status != SessionPlaying {
		return "none"
	}
	if s.Score.Next() == penalty.SidePlayer {
		return "shoot"
	}
	return "keep"
}
