package engine

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/cards/v0"
	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"
)

const (
	// MaxPlanEntries bounds the number of actions in a plan; five 1-point
	// actions already fill the budget.
	MaxPlanEntries = MaxActionPoints
	// MaxPlanLen bounds the plan string length.
	MaxPlanLen = 128
)

// Action is one card side chosen for the turn, with its committed choice.
type Action struct {
	Card   int
	Side   byte // cards.FrontSide or cards.BackSide
	Code   cards.Code
	Cost   int
	Dir    hex.Rel // committed relative direction, "" when the side takes none
	Gun    int     // id of the character's gun for a gun choice (Draw & Cock), 0 when none
	Ground int     // id of the gun on the ground to pick up (Draw & Cock, "g<id>"), 0 when none
	Hand   int     // destination hand code for a gun choice (HandGun...), -1 when the side takes none
	Opt    string  // option of Cock/Aim/Shoot, Shoot and Throw (OptCock...) or Strength (OptDamage, OptWield), "" when the side takes none
	Hex    string  // the hex named by an aim, a shot or a throw at a hex
	Target int     // the seat named by an aim, a shot or a throw at a character; -1 otherwise
	// Wield and Damage are what the STRENGTHs played on top of a Throw add
	// to the weapon's wielding factor and to the penalties (20.2), set by
	// Combine.
	Wield  int
	Damage int
	// Moves are the gun moves done when the action is revealed (10.22),
	// written before it in the plan string.
	Moves []GunMove
}

// GunMove is what a character may do with its guns, for free, each time it
// reveals an action (10.22): move the gun in BOTH HANDS to one hand, or drop
// a gun from a hand box into its hex. The other hand, like Draw & Cock's,
// comes with a second gun: Validate refuses it for now. Its plan string entry, "h<gun id>:<to>",
// comes before the action it goes with: To is HandGun (0) or HandOther (1),
// or "g" (HandGround) to drop it ("h1:g,1f:ahead": drop the Colt as the
// Advance is revealed). Whether the gun is there, where the move needs
// it, is checked when it is done: it may be one picked up earlier in the
// plan.
type GunMove struct {
	Gun int // id of the gun on the character's sheet
	To  int // HandGun, HandOther or HandGround
}

// String is the move's plan string entry.
func (m GunMove) String() string {
	to := strconv.Itoa(m.To)
	if m.To == HandGround {
		to = "g"
	}
	return "h" + strconv.Itoa(m.Gun) + ":" + to
}

// Shoot options: what a Cock/Aim/Shoot does (11.3), or a Shoot (shoot or
// nothing). Aiming and shooting name their target (11.31): a hex of the
// aim zone ("5f:aim:A-F6", "7f:shoot:A-F6") or a character by seat
// ("5f:aim:@1", "7f:shoot:@1"). A shot at a hex hits the character standing
// there when it goes off, and is wasted otherwise.
const (
	OptCock    = "cock"
	OptUncock  = "uncock"
	OptAim     = "aim"
	OptShoot   = "shoot"
	OptNothing = "nothing"
	// OptThrow is what a Throw does instead of nothing (17.1), naming its
	// target like a shot ("6b:throw:@1"; a bare "6b" does nothing).
	OptThrow = "throw"
)

// Strength options (20.2): a STRENGTH adds to the penalties ("7b:damage",
// also a bare "7b", what a STRENGTH does when its use is not stated) or
// to the wielding factor ("7b:wield") of the Throw it is played on top of.
const (
	OptDamage = "damage"
	OptWield  = "wield"
)

// Card 7's STRENGTH adds 4 to the wielding factor or 2 to the penalties.
const (
	StrengthWield  = 4
	StrengthDamage = 2
)

// IsShot reports whether the action fires the gun.
func (a Action) IsShot() bool { return cards.IsShooting(a.Code) && a.Opt == OptShoot }

// IsThrow reports whether the action throws the weapon in hand (17.1).
func (a Action) IsThrow() bool { return a.Code == cards.Throw && a.Opt == OptThrow }

// AimTime is the aim time printed on a shooting action or a Throw for a
// one- or two-handed weapon (13.52, 17.3).
func (a Action) AimTime(oneHanded bool) int {
	switch a.Code {
	case cards.Throw:
		if oneHanded {
			return 2
		}
		return 1
	case cards.CockAimShoot:
		if oneHanded {
			return 2
		}
		return 1
	case cards.Shoot:
		if oneHanded {
			return 1
		}
		return 0
	}
	return 0
}

// validHex is a loose check of a hex id in a plan string ("A-F6", "A-I11*"
// for a half-hex); the board decides whether it exists.
func validHex(h string) bool {
	if len(h) < 3 || len(h) > 8 {
		return false
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		if !(c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '*') {
			return false
		}
	}
	return true
}

func validOpt(code cards.Code, opt string) bool {
	switch code {
	case cards.CockAimShoot:
		return opt == OptCock || opt == OptUncock || opt == OptAim || opt == OptShoot
	case cards.Shoot:
		return opt == OptShoot || opt == OptNothing
	case cards.Throw:
		return opt == OptThrow || opt == OptNothing
	case cards.Strength:
		return opt == OptDamage || opt == OptWield
	}
	return false
}

// takesTarget reports whether the option names a target.
func takesTarget(opt string) bool { return opt == OptAim || opt == OptShoot || opt == OptThrow }

// Plan is the ordered stack of actions a player committed for the turn.
//
// Its string form, used as the transaction argument, is a comma-separated
// list of entries "<card><f|b>[:<choice>]", the choice being a relative
// direction for move and turn cards ("1f:ahead_left"), for Draw & Cock a
// gun and the hand it goes to ("9f:1:0": the character's gun 1 to the gun
// hand, "9f:g2:0": the gun lying in its hex with ground id 2; hand codes: 0
// gun hand, 1 other hand, 2 both hands), or for Cock/Aim/Shoot and
// Shoot the option ("5f:aim:A-F6", "7f:shoot:@1"; a bare "7f" does
// nothing), for Throw the same ("6b:throw:@1", a bare "6b" does nothing),
// for Strength its use ("7b:damage", "7b:wield"), e.g.
// "1f:ahead_left,2f:ahead,3f"; gun moves ("h1:g", GunMove) come before the
// action they go with and do not count as actions. An empty string is a
// pass.
type Plan []Action

// ParsePlan parses the plan string. It checks the syntax and that every card
// side exists; Validate checks the game rules.
func ParsePlan(s string) (Plan, error) {
	if s == "" {
		return Plan{}, nil
	}
	if len(s) > MaxPlanLen {
		return nil, errors.New("plan is too long")
	}
	entries := strings.Split(s, ",")
	plan := make(Plan, 0, len(entries))
	var moves []GunMove
	for _, e := range entries {
		if strings.HasPrefix(e, "h") {
			m, err := parseMove(e)
			if err != nil {
				return nil, err
			}
			if len(moves) >= MaxGuns {
				return nil, errors.New("too many gun moves before an action")
			}
			moves = append(moves, m)
			continue
		}
		a, err := parseEntry(e)
		if err != nil {
			return nil, err
		}
		a.Moves, moves = moves, nil
		plan = append(plan, a)
		if len(plan) > MaxPlanEntries {
			return nil, errors.New("too many actions in plan")
		}
	}
	if len(moves) > 0 {
		return nil, errors.New("a gun move goes before an action: it is done when that action comes up")
	}
	return plan, nil
}

// parseMove parses a gun move entry, "h<gun id>:<0|1|g>".
func parseMove(e string) (GunMove, error) {
	parts := strings.Split(e[1:], ":")
	if len(parts) != 2 {
		return GunMove{}, errors.New("gun move must be h<gun id>:<to> in " + strconv.Quote(e))
	}
	id, err := strconv.Atoi(parts[0])
	if err != nil || id < 1 {
		return GunMove{}, errors.New("invalid gun id in " + strconv.Quote(e))
	}
	switch parts[1] {
	case "0":
		return GunMove{Gun: id, To: HandGun}, nil
	case "1":
		return GunMove{Gun: id, To: HandOther}, nil
	case "g":
		return GunMove{Gun: id, To: HandGround}, nil
	}
	return GunMove{}, errors.New("a gun moves to 0 (gun hand), 1 (other hand) or g (the ground) in " + strconv.Quote(e))
}

func parseEntry(e string) (Action, error) {
	if e == "" {
		return Action{}, errors.New("empty action in plan")
	}
	choice := ""
	if i := strings.IndexByte(e, ':'); i >= 0 {
		e, choice = e[:i], e[i+1:]
		if choice == "" {
			return Action{}, errors.New("missing choice in " + strconv.Quote(e+":"))
		}
	}
	if len(e) < 2 {
		return Action{}, errors.New("invalid action " + strconv.Quote(e))
	}
	side := e[len(e)-1]
	num, err := strconv.Atoi(e[:len(e)-1])
	if err != nil || (side != cards.FrontSide && side != cards.BackSide) {
		return Action{}, errors.New("invalid action " + strconv.Quote(e))
	}
	def, ok := cards.Lookup(num, side)
	if !ok {
		return Action{}, errors.New("invalid action card " + strconv.Quote(e))
	}
	a := Action{Card: num, Side: side, Code: def.Code, Cost: def.Cost, Hand: -1, Target: -1}
	switch {
	case def.Code == cards.Strength:
		if choice == "" { // a STRENGTH whose use is not stated adds to the damage (20.2)
			choice = OptDamage
		}
		if !validOpt(def.Code, choice) {
			return Action{}, errors.New("invalid option " + strconv.Quote(choice) + " for " + def.Name + " (damage or wield)")
		}
		a.Opt = choice
	case cards.TakesTarget(def.Code):
		if choice == "" && (def.Code == cards.Shoot || def.Code == cards.Throw) {
			choice = OptNothing
		}
		opt, arg := choice, ""
		if i := strings.IndexByte(choice, ':'); i >= 0 {
			opt, arg = choice[:i], choice[i+1:]
		}
		if !validOpt(def.Code, opt) {
			return Action{}, errors.New("invalid option " + strconv.Quote(opt) + " for " + def.Name)
		}
		if takesTarget(opt) {
			switch {
			case strings.HasPrefix(arg, "@"):
				seat, err := strconv.Atoi(arg[1:])
				if err != nil || seat < 0 || seat >= MaxPlayers {
					return Action{}, errors.New("invalid character " + strconv.Quote(arg) + " to " + opt + " at")
				}
				a.Target = seat
			case validHex(arg):
				a.Hex = arg
			default:
				return Action{}, errors.New(opt + " needs a hex or a character to " + opt + " at, e.g. " + strconv.Quote(e+":"+opt+":A-F6") + " or " + strconv.Quote(e+":"+opt+":@1"))
			}
		} else if arg != "" {
			return Action{}, errors.New("option " + strconv.Quote(opt) + " takes no argument")
		}
		a.Opt = opt
	case choice == "":
	case def.Choice.NeedsGun():
		parts := strings.Split(choice, ":")
		if len(parts) != 2 {
			return Action{}, errors.New("gun choice must be <gun id>:<hand> in " + strconv.Quote(e+":"+choice))
		}
		ref := strings.TrimPrefix(parts[0], "g")
		id, err := strconv.Atoi(ref)
		if err != nil || id < 1 {
			return Action{}, errors.New("invalid gun id " + strconv.Quote(parts[0]))
		}
		hand, err := strconv.Atoi(parts[1])
		if _, ok := HandLocation(hand); err != nil || !ok {
			return Action{}, errors.New("invalid hand " + strconv.Quote(parts[1]) + " (0 gun hand, 1 other hand, 2 both hands)")
		}
		if ref != parts[0] {
			a.Ground = id
		} else {
			a.Gun = id
		}
		a.Hand = hand
	default:
		r, ok := hex.ParseRel(choice)
		if !ok {
			return Action{}, errors.New("invalid direction " + strconv.Quote(choice))
		}
		a.Dir = r
	}
	return a, nil
}

// String is the canonical plan string, parseable by ParsePlan.
func (p Plan) String() string {
	var b strings.Builder
	for i, a := range p {
		if i > 0 {
			b.WriteByte(',')
		}
		for _, m := range a.Moves {
			b.WriteString(m.String())
			b.WriteByte(',')
		}
		b.WriteString(strconv.Itoa(a.Card))
		b.WriteByte(a.Side)
		if a.Gun > 0 || a.Ground > 0 {
			b.WriteByte(':')
			if a.Ground > 0 {
				b.WriteByte('g')
				b.WriteString(strconv.Itoa(a.Ground))
			} else {
				b.WriteString(strconv.Itoa(a.Gun))
			}
			b.WriteByte(':')
			b.WriteString(strconv.Itoa(a.Hand))
		} else if a.Opt != "" && !((a.Code == cards.Shoot || a.Code == cards.Throw) && a.Opt == OptNothing) {
			b.WriteByte(':')
			b.WriteString(a.Opt)
			if takesTarget(a.Opt) {
				b.WriteByte(':')
				if a.Target >= 0 {
					b.WriteByte('@')
					b.WriteString(strconv.Itoa(a.Target))
				} else {
					b.WriteString(a.Hex)
				}
			}
		} else if a.Dir != "" {
			b.WriteByte(':')
			b.WriteString(string(a.Dir))
		}
	}
	return b.String()
}

// Cost is the total time points of the plan.
func (p Plan) Cost() int {
	n := 0
	for _, a := range p {
		n += a.Cost
	}
	return n
}

// Has reports whether the plan holds the action.
func (p Plan) Has(code cards.Code) bool {
	for _, a := range p {
		if a.Code == code {
			return true
		}
	}
	return false
}

// PlayedFoot reports whether the plan holds any foot action ([H12]).
func (p Plan) PlayedFoot() bool {
	for _, a := range p {
		if def, ok := cards.Lookup(a.Card, a.Side); ok && def.Kind == cards.KindFoot {
			return true
		}
	}
	return false
}

// Validate checks the plan against the selection rules for the character
// that will play it (port of the BGA actConfirmPlan checks).
func (p Plan) Validate(c Character) error {
	used := map[int]bool{}
	for i, a := range p {
		def, ok := cards.Lookup(a.Card, a.Side)
		if !ok {
			return errors.New("invalid action card")
		}
		if !cards.Enabled(def.Code) {
			return errors.New("that action is not available yet")
		}
		if used[a.Card] { // rule 7.2: one side per card, once per turn
			return errors.New("you cannot use both sides of a card")
		}
		used[a.Card] = true
		// The gun may be one the plan picks up first (its id is the sheet's
		// next): whether it is there is checked when the move is done.
		for _, m := range a.Moves {
			if m.To == HandOther { // the other hand comes with a second gun, as for Draw & Cock
				return errors.New("a gun moves to the gun hand or the ground for now")
			}
			if m.To != HandGun && m.To != HandGround {
				return errors.New("a gun moves to the gun hand or the ground")
			}
		}
		switch {
		case def.Code == cards.Strength:
			if !validOpt(def.Code, a.Opt) {
				return errors.New("choose what the strength adds to")
			}
			// Played just before (on top of) the action it combines with
			// (20.1): a Throw, until the attacks come.
			if i+1 >= len(p) || p[i+1].Code != cards.Throw {
				return errors.New("strength is played just before a throw")
			}
		case cards.TakesTarget(def.Code):
			if !validOpt(def.Code, a.Opt) {
				if def.Code == cards.Throw {
					return errors.New("choose whether to throw")
				}
				return errors.New("choose what to do with the gun")
			}
			if takesTarget(a.Opt) && a.Hex == "" && a.Target < 0 {
				return errors.New("choose what to " + a.Opt + " at")
			}
		case def.Choice.IsAheadRel():
			if !a.Dir.IsAhead() {
				return errors.New("choose a forward direction")
			}
		case def.Choice.IsBackRel():
			if !a.Dir.IsBack() {
				return errors.New("choose a backward direction")
			}
		case def.Choice.NeedsGun():
			if a.Gun == 0 && a.Ground == 0 {
				return errors.New("choose the gun to draw")
			}
			if a.Hand == HandOther { // the other hand comes with a second gun
				return errors.New("only the gun hand or both hands can take a gun for now")
			}
			dest, _ := HandLocation(a.Hand)
			slot := -1
			if a.Gun != 0 { // a gun on the ground is checked against the hex when the action executes
				if slot = c.Guns.Find(a.Gun); slot < 0 {
					return errors.New("you have no such gun")
				}
				if c.Guns[slot].Location == dest {
					return errors.New("that gun is already there")
				}
			}
			if c.Guns.Blocked(dest, slot) {
				return errors.New("that hand already holds a gun")
			}
		default:
			if a.Dir != "" {
				return errors.New("that action takes no direction")
			}
			if a.Gun != 0 || a.Ground != 0 {
				return errors.New("that action takes no gun")
			}
		}
	}
	budget := MaxActionPoints - c.Delay // [H5]
	if p.Cost() > budget {
		return errors.New("those actions cost more time points than you have")
	}
	// Prerequisite chains (rule 9.21).
	if p.Has(cards.Run) && !p.Has(cards.Advance) {
		return errors.New("run can only be played together with advance")
	}
	if p.Has(cards.Sprint) {
		if !p.Has(cards.Run) {
			return errors.New("sprint can only be played together with run")
		}
		if !c.RanLastTurn { // rule 9.23: speed is built up over two turns
			return errors.New("sprint can only be played after a run on the previous turn")
		}
	}
	return nil
}

// Combine folds each run of STRENGTHs into the Throw it is played on top
// of (20.1): treated as part of that action, revealed with it, their time
// points added to its own, their bonuses in its Wield and Damage, their
// gun moves done as it is revealed. Validate has checked that each
// STRENGTH comes just before a Throw; one that does not is dropped.
func (p Plan) Combine() Plan {
	out := make(Plan, 0, len(p))
	var (
		cost, wield, damage int
		moves               []GunMove
	)
	for _, a := range p {
		if a.Code == cards.Strength {
			cost += a.Cost
			if a.Opt == OptWield {
				wield += StrengthWield
			} else {
				damage += StrengthDamage
			}
			moves = append(moves, a.Moves...)
			continue
		}
		if a.Code == cards.Throw {
			a.Cost += cost
			a.Wield += wield
			a.Damage += damage
			if len(moves) > 0 {
				a.Moves = append(moves, a.Moves...)
			}
		}
		cost, wield, damage, moves = 0, 0, 0, nil
		out = append(out, a)
	}
	return out
}
