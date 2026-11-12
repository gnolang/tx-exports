package holdem

import "errors"

// Streets.
const (
	Preflop = iota
	Flop
	Turn
	River
)

// Player is one hand player's betting state.
type Player struct {
	Stack       int64 // chips behind
	StreetBet   int64 // chips put in on the current street
	Contributed int64 // chips put in during the whole hand
	Folded      bool
	AllIn       bool
	Acted       bool  // acted since the bet last increased
	LastActBet  int64 // current bet right after this player's last action this street, -1 if none
}

// Betting is the no-limit betting state of one hand. Players are indexed from
// the small blind (heads-up: index 0 is the button and small blind).
type Betting struct {
	Players    []*Player
	SmallBlind int64
	BigBlind   int64
	Street     int
	CurrentBet int64 // highest street bet
	MinRaise   int64 // size of the last full bet or raise on this street
	Turn       int   // index to act, -1 when the street needs no more action
}

// NewBetting posts the blinds and sets the first player to act preflop.
func NewBetting(stacks []int64, smallBlind, bigBlind int64) *Betting {
	n := len(stacks)
	if n < 2 {
		panic("need at least 2 players")
	}
	if smallBlind <= 0 || bigBlind < smallBlind {
		panic("invalid blinds")
	}
	b := &Betting{SmallBlind: smallBlind, BigBlind: bigBlind, Street: Preflop, MinRaise: bigBlind}
	for _, s := range stacks {
		if s <= 0 {
			panic("player without chips")
		}
		b.Players = append(b.Players, &Player{Stack: s, LastActBet: -1})
	}
	b.post(0, smallBlind)
	b.post(1, bigBlind)
	b.CurrentBet = b.Players[0].StreetBet
	if b.Players[1].StreetBet > b.CurrentBet {
		b.CurrentBet = b.Players[1].StreetBet
	}
	if b.CurrentBet < bigBlind {
		b.CurrentBet = bigBlind
	}
	first := 2 % n
	if n == 2 {
		first = 0
	}
	b.Turn = b.nextToAct(first)
	return b
}

func (b *Betting) post(i int, amount int64) {
	p := b.Players[i]
	if amount > p.Stack {
		amount = p.Stack
	}
	p.Stack -= amount
	p.StreetBet += amount
	p.Contributed += amount
	if p.Stack == 0 {
		p.AllIn = true
	}
}

// Live returns the number of players who have not folded.
func (b *Betting) Live() int {
	n := 0
	for _, p := range b.Players {
		if !p.Folded {
			n++
		}
	}
	return n
}

func (b *Betting) canAct(p *Player) bool {
	return !p.Folded && !p.AllIn
}

func (b *Betting) needsAction(p *Player) bool {
	return b.canAct(p) && (!p.Acted || p.StreetBet < b.CurrentBet)
}

// nextToAct returns the first player from index `from` (inclusive, clockwise)
// who still has to act, or -1 when the street is complete.
func (b *Betting) nextToAct(from int) int {
	if b.Live() <= 1 {
		return -1
	}
	actors := 0
	for _, p := range b.Players {
		if b.canAct(p) {
			actors++
		}
	}
	n := len(b.Players)
	for k := 0; k < n; k++ {
		i := (from + k) % n
		p := b.Players[i]
		if !b.needsAction(p) {
			continue
		}
		// A lone player who can still act and has matched the bet has nobody
		// to bet against.
		if actors == 1 && p.StreetBet >= b.CurrentBet {
			continue
		}
		return i
	}
	return -1
}

// StreetComplete reports whether nobody has to act on this street.
func (b *Betting) StreetComplete() bool {
	return b.Turn < 0
}

// Closed reports whether no further betting is possible in the hand: one live
// player left, or the street is complete and at most one live player still
// has chips.
func (b *Betting) Closed() bool {
	if b.Live() <= 1 {
		return true
	}
	if b.Turn >= 0 {
		return false
	}
	actors := 0
	for _, p := range b.Players {
		if b.canAct(p) {
			actors++
		}
	}
	return actors <= 1
}

// CanCheck reports whether player i may check.
func (b *Betting) CanCheck(i int) bool {
	return b.Players[i].StreetBet == b.CurrentBet
}

// CanRaise reports whether player i may bet or raise: they have chips beyond a
// call, and either have not acted on this street or face at least a full
// raise since they last acted (a short all-in does not reopen the betting).
func (b *Betting) CanRaise(i int) bool {
	p := b.Players[i]
	if p.StreetBet+p.Stack <= b.CurrentBet {
		return false
	}
	return p.LastActBet < 0 || b.CurrentBet-p.LastActBet >= b.MinRaise
}

// MinRaiseTo returns the smallest legal total street bet for a non all-in
// bet or raise.
func (b *Betting) MinRaiseTo() int64 {
	return b.CurrentBet + b.MinRaise
}

// Act applies an action by player i. For "raise", amount is the player's total
// street bet after the action; it also opens the betting when nobody has bet.
func (b *Betting) Act(i int, action string, amount int64) error {
	if b.Turn < 0 || i != b.Turn {
		return errors.New("not this player's turn")
	}
	p := b.Players[i]
	raised := false
	switch action {
	case "fold":
		p.Folded = true
	case "check":
		if !b.CanCheck(i) {
			return errors.New("cannot check facing a bet")
		}
	case "call":
		if p.StreetBet >= b.CurrentBet {
			return errors.New("nothing to call")
		}
		b.post(i, b.CurrentBet-p.StreetBet)
	case "raise":
		if amount <= b.CurrentBet {
			return errors.New("raise must exceed the current bet")
		}
		max := p.StreetBet + p.Stack
		if amount > max {
			return errors.New("raise exceeds stack")
		}
		if !b.CanRaise(i) {
			return errors.New("betting is not reopened for this player")
		}
		allIn := amount == max
		if !allIn && amount < b.CurrentBet+b.MinRaise {
			return errors.New("raise below minimum")
		}
		if amount-b.CurrentBet >= b.MinRaise {
			b.MinRaise = amount - b.CurrentBet
		}
		b.post(i, amount-p.StreetBet)
		b.CurrentBet = amount
		raised = true
	default:
		return errors.New("unknown action")
	}
	p.Acted = true
	p.LastActBet = b.CurrentBet
	if raised {
		for k, q := range b.Players {
			if k != i && b.canAct(q) {
				q.Acted = false
			}
		}
	}
	b.Turn = b.nextToAct((i + 1) % len(b.Players))
	return nil
}

// NextStreet resets street state and sets the first player to act. It must
// only be called when the current street is complete and betting not closed.
func (b *Betting) NextStreet() {
	if b.Street >= River {
		panic("no street after the river")
	}
	b.Street++
	b.CurrentBet = 0
	b.MinRaise = b.BigBlind
	for _, p := range b.Players {
		p.StreetBet = 0
		p.Acted = false
		p.LastActBet = -1
	}
	first := 0
	if len(b.Players) == 2 {
		first = 1
	}
	b.Turn = b.nextToAct(first)
}

// Pot returns the total contributed by all players.
func (b *Betting) Pot() int64 {
	t := int64(0)
	for _, p := range b.Players {
		t += p.Contributed
	}
	return t
}
