package penalty

// Side is who takes a kick.
type Side uint8

const (
	SidePlayer Side = iota + 1
	SideChain
)

func (s Side) String() string {
	switch s {
	case SidePlayer:
		return "player"
	case SideChain:
		return "chain"
	}
	return "none"
}

// Other returns the opposing side.
func (s Side) Other() Side {
	if s == SidePlayer {
		return SideChain
	}
	return SidePlayer
}

// RegulationKicks is how many kicks each side takes before sudden death.
const RegulationKicks = 5

// Shootout is the score of a penalty shootout in which the player always
// kicks first in each round:
//
//   - each side takes RegulationKicks kicks, alternating;
//   - it ends early as soon as one side cannot be caught with the kicks the
//     other has left;
//   - level after regulation, it goes to sudden death: rounds of one kick
//     each, decided when one side scores and the other does not.
type Shootout struct {
	PlayerKicks int
	PlayerGoals int
	ChainKicks  int
	ChainGoals  int
}

// Next returns who kicks next (SidePlayer at the start of every round).
func (s Shootout) Next() Side {
	if s.PlayerKicks == s.ChainKicks {
		return SidePlayer
	}
	return SideChain
}

// Round is the 1-based number of the round in progress.
func (s Shootout) Round() int { return s.ChainKicks + 1 }

// SuddenDeath reports whether regulation is over.
func (s Shootout) SuddenDeath() bool { return s.ChainKicks >= RegulationKicks }

// Record adds a kick for side. It panics if side is out of turn or the
// shootout is already decided.
func (s *Shootout) Record(side Side, scored bool) {
	if s.Winner() != 0 {
		panic("penalty: the shootout is already decided")
	}
	if side != s.Next() {
		panic("penalty: " + side.String() + " is kicking out of turn")
	}
	g := 0
	if scored {
		g = 1
	}
	if side == SidePlayer {
		s.PlayerKicks++
		s.PlayerGoals += g
	} else {
		s.ChainKicks++
		s.ChainGoals += g
	}
}

// Winner returns the side that has won, or 0 while undecided.
func (s Shootout) Winner() Side {
	if s.PlayerKicks <= RegulationKicks && s.ChainKicks <= RegulationKicks {
		playerLeft := RegulationKicks - s.PlayerKicks
		chainLeft := RegulationKicks - s.ChainKicks
		if s.PlayerGoals > s.ChainGoals+chainLeft {
			return SidePlayer
		}
		if s.ChainGoals > s.PlayerGoals+playerLeft {
			return SideChain
		}
		return 0
	}
	// Sudden death: decided only once both have kicked in the round.
	if s.PlayerKicks == s.ChainKicks && s.PlayerGoals != s.ChainGoals {
		if s.PlayerGoals > s.ChainGoals {
			return SidePlayer
		}
		return SideChain
	}
	return 0
}
