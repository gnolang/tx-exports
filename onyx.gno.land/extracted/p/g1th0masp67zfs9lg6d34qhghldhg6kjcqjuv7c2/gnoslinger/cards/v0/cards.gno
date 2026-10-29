// Package cards holds the static definition of the 12 action cards, each with
// a front and a back side (24 actions), as printed in the 1982 game.
package cards

// Code identifies the action printed on one side of a card.
type Code string

const (
	Advance      Code = "advance"
	BackUp       Code = "back_up"
	Run          Code = "run"
	SpinAround   Code = "spin_around"
	Sprint       Code = "sprint"
	Turn         Code = "turn"
	LeapDrop     Code = "leap_drop"
	CockAimShoot Code = "cock_aim_shoot"
	GetUpDown    Code = "get_up_down"
	Throw        Code = "throw"
	Shoot        Code = "shoot"
	Strength     Code = "strength"
	Load         Code = "load"
	HeadOutBack  Code = "head_out_back"
	DrawAndCock  Code = "draw_and_cock"
	Jab          Code = "jab"
	Duck         Code = "duck"
	Swing        Code = "swing"
	Block        Code = "block"
	Belt         Code = "belt"
	Guard        Code = "guard"
)

// Kind is the card category (rule 5.2).
type Kind int

const (
	KindFoot Kind = iota
	KindHand
	KindAttack
	KindDefense
	KindStrength
)

// Choice is what the player must decide when selecting a side.
type Choice int

const (
	ChoiceNone Choice = iota
	ChoiceMoveAhead
	ChoiceMoveBack
	ChoiceTurnAhead
	ChoiceTurnBack
	ChoiceTargetRanged
	ChoiceTargetMelee
	ChoiceTargetDefend
	// ChoiceGun picks one of the character's holstered guns (Draw & Cock).
	ChoiceGun
)

// NeedsRel reports whether the choice is a relative direction (move or turn).
func (c Choice) NeedsRel() bool { return c.IsAheadRel() || c.IsBackRel() }

// IsAheadRel reports whether the choice is one of the three forward directions.
func (c Choice) IsAheadRel() bool { return c == ChoiceMoveAhead || c == ChoiceTurnAhead }

// IsBackRel reports whether the choice is one of the three backward directions.
func (c Choice) IsBackRel() bool { return c == ChoiceMoveBack || c == ChoiceTurnBack }

// NeedsGun reports whether the choice is a gun slot.
func (c Choice) NeedsGun() bool { return c == ChoiceGun }

// Side is one face of a card.
type Side struct {
	Code   Code
	Name   string
	Kind   Kind
	Cost   int // time points: the sequences the action takes
	Choice Choice
}

// Card is one physical card; its two sides cannot both be played in a turn.
type Card struct {
	Number int
	Front  Side
	Back   Side
}

// Side selectors as used in the plan string.
const (
	FrontSide byte = 'f'
	BackSide  byte = 'b'
)

// Cards is the deck, indexed by Number-1.
var Cards = [12]Card{
	{1, Side{Advance, "Advance", KindFoot, 2, ChoiceMoveAhead}, Side{BackUp, "Back Up", KindFoot, 3, ChoiceMoveBack}},
	{2, Side{Run, "Run", KindFoot, 1, ChoiceMoveAhead}, Side{SpinAround, "Spin Around", KindFoot, 2, ChoiceTurnBack}},
	{3, Side{Sprint, "Sprint", KindFoot, 1, ChoiceNone}, Side{Turn, "Turn", KindFoot, 1, ChoiceTurnAhead}},
	{4, Side{Sprint, "Sprint", KindFoot, 1, ChoiceNone}, Side{LeapDrop, "Leap/Drop", KindFoot, 1, ChoiceNone}},
	{5, Side{CockAimShoot, "Cock/Aim/Shoot", KindHand, 2, ChoiceTargetRanged}, Side{GetUpDown, "Get Up/Down", KindFoot, 3, ChoiceNone}},
	{6, Side{CockAimShoot, "Cock/Aim/Shoot", KindHand, 2, ChoiceTargetRanged}, Side{Throw, "Throw", KindHand, 2, ChoiceTargetRanged}},
	{7, Side{Shoot, "Shoot", KindHand, 1, ChoiceTargetRanged}, Side{Strength, "Strength", KindStrength, 2, ChoiceNone}},
	{8, Side{Load, "Load", KindHand, 3, ChoiceNone}, Side{HeadOutBack, "Head Out/Back", KindFoot, 2, ChoiceNone}},
	{9, Side{DrawAndCock, "Draw & Cock", KindHand, 3, ChoiceGun}, Side{HeadOutBack, "Head Out/Back", KindFoot, 2, ChoiceNone}},
	{10, Side{Jab, "Jab", KindAttack, 2, ChoiceTargetMelee}, Side{Duck, "Duck", KindDefense, 1, ChoiceTargetDefend}},
	{11, Side{Swing, "Swing", KindAttack, 3, ChoiceTargetMelee}, Side{Block, "Block", KindDefense, 2, ChoiceTargetDefend}},
	{12, Side{Belt, "Belt", KindAttack, 3, ChoiceTargetMelee}, Side{Guard, "Guard", KindDefense, 2, ChoiceTargetDefend}},
}

// Lookup returns the side of card number (1-12) selected by 'f' or 'b'.
func Lookup(number int, side byte) (Side, bool) {
	if number < 1 || number > len(Cards) {
		return Side{}, false
	}
	switch side {
	case FrontSide:
		return Cards[number-1].Front, true
	case BackSide:
		return Cards[number-1].Back, true
	}
	return Side{}, false
}

// Enabled reports whether the action is implemented by the engine: the foot
// actions, Draw & Cock, Cock/Aim/Shoot, Shoot, Load, Throw and Strength;
// brawling comes later.
func Enabled(c Code) bool {
	switch c {
	case Advance, BackUp, Run, SpinAround, Sprint, Turn, LeapDrop, GetUpDown, DrawAndCock, CockAimShoot, Shoot, Load, Throw, Strength:
		return true
	}
	return false
}

// IsShooting reports whether the action is played with a gun in hand: it
// takes a shoot option (cock, uncock, aim, shoot, nothing) and names the
// target (rules 11.3, 11.31).
func IsShooting(c Code) bool { return c == CockAimShoot || c == Shoot }

// TakesTarget reports whether the action may name a target, a hex or a
// character: the gun actions and Throw (11.31, 17.11).
func TakesTarget(c Code) bool { return IsShooting(c) || c == Throw }

// IsMove reports whether the action moves the character to another hex.
func IsMove(c Code) bool {
	return c == Advance || c == Run || c == BackUp || c == Sprint
}
