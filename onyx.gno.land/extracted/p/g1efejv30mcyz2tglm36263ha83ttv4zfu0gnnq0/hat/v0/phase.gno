package hat

// Phase is a step of a draw. Phases only move forward, in the order they are
// declared here, except that any phase before Revealed may end in Voided.
type Phase uint8

const (
	Join     Phase = iota // people join; the roster is open
	Locked                // roster frozen; every phone reveals its seed
	Seal1                 // every phone posts an onion holding a fresh slot key
	Mix1                  // the shufflers peel and shuffle, one turn each
	Check                 // every phone confirms its slot made it through
	Seal2                 // every phone posts an onion holding a slip for its Santa
	Mix2                  // the shufflers peel and shuffle again
	Revealed              // each phone opens the one slip addressed to its slot
	Voided                // the draw was called off, for everyone
)

var phaseNames = [...]string{"Join", "Locked", "Seal1", "Mix1", "Check", "Seal2", "Mix2", "Revealed", "Voided"}

func (p Phase) String() string {
	if int(p) < len(phaseNames) {
		return phaseNames[p]
	}
	return "Unknown"
}

// Terminal reports whether no further phase can follow p in the normal flow.
// A Revealed draw can still be voided until every phone has confirmed its slip.
func (p Phase) Terminal() bool { return p == Revealed || p == Voided }

// next returns the phase that follows p in a draw with the given number of
// rounds. A one-round hat (rounds == 1) goes straight from Check to Revealed.
func (p Phase) next(rounds int) Phase {
	if p == Check && rounds == 1 {
		return Revealed
	}
	if p >= Revealed {
		return p
	}
	return p + 1
}

// CanMove reports whether the state machine allows moving from one phase to
// another in a hat with the given number of rounds (1 or 2).
func CanMove(from, to Phase, rounds int) bool {
	if from == Voided {
		return false
	}
	if to == Voided {
		return true
	}
	return from != Revealed && to == from.next(rounds)
}
