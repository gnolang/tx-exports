// Package hex holds the pure hex geometry of the game: absolute directions,
// directions relative to a character's facing, and board adjacency tables.
package hex

// Dir is an absolute direction on a flat-top hex grid laid out in vertical
// columns: 0=N 1=NE 2=SE 3=S 4=SW 5=NW.
type Dir int

const (
	N Dir = iota
	NE
	SE
	S
	SW
	NW
)

var dirNames = [6]string{"N", "NE", "SE", "S", "SW", "NW"}

// Valid reports whether d is one of the six directions.
func (d Dir) Valid() bool { return d >= 0 && d < 6 }

// String returns the compass name of d.
func (d Dir) String() string {
	if !d.Valid() {
		return "?"
	}
	return dirNames[d]
}

// Opposite returns the direction pointing back at d.
func (d Dir) Opposite() Dir { return (d + 3) % 6 }

// Rel is a direction relative to a character's facing, as chosen on a move
// or turn card. The names are the ones the client and the plan string use.
// Same and Long only appear on the HEX line of result cards (direction
// cards, rule 14.3, relative to the target's body counter): they are not
// movement choices, ParseRel rejects them and Offset panics on them.
type Rel string

const (
	AheadLeft  Rel = "ahead_left"
	Ahead      Rel = "ahead"
	AheadRight Rel = "ahead_right"
	BackLeft   Rel = "back_left"
	Back       Rel = "back"
	BackRight  Rel = "back_right"
	Same       Rel = "same" // the target's own hex (14.33)
	Long       Rel = "long" // the hex beyond the target on the line from the shooter's hex through the target's (14.32)
)

// AheadRels are the three forward directions a move_ahead/turn_ahead card offers.
var AheadRels = [3]Rel{AheadLeft, Ahead, AheadRight}

// BackRels are the three backward directions a move_back/turn_back card offers.
var BackRels = [3]Rel{BackLeft, Back, BackRight}

// ParseRel converts a plan string token to a Rel.
func ParseRel(s string) (Rel, bool) {
	switch r := Rel(s); r {
	case AheadLeft, Ahead, AheadRight, BackLeft, Back, BackRight:
		return r, true
	}
	return "", false
}

// IsAhead reports whether r is one of the three forward directions.
func (r Rel) IsAhead() bool { return r == AheadLeft || r == Ahead || r == AheadRight }

// IsBack reports whether r is one of the three backward directions.
func (r Rel) IsBack() bool { return r == BackLeft || r == Back || r == BackRight }

// Offset is the number of 60° clockwise steps from the facing to r
// (ahead_left=5 ahead=0 ahead_right=1 back_right=2 back=3 back_left=4).
// Left and right are the character's own sides while it keeps facing
// forward: facing N, back_right is SE and back_left is SW.
func (r Rel) Offset() int {
	switch r {
	case Ahead:
		return 0
	case AheadRight:
		return 1
	case BackRight:
		return 2
	case Back:
		return 3
	case BackLeft:
		return 4
	case AheadLeft:
		return 5
	}
	panic("hex: invalid relative direction " + string(r))
}

// Resolve turns a relative direction into an absolute one for a facing.
func Resolve(facing Dir, r Rel) Dir {
	return Dir((int(facing) + r.Offset()) % 6)
}

// AheadDirs returns the absolute directions of ahead_left, ahead and
// ahead_right for a facing; these are also the aim-zone spokes (rule 8.32).
func AheadDirs(f Dir) [3]Dir {
	return [3]Dir{Resolve(f, AheadLeft), Resolve(f, Ahead), Resolve(f, AheadRight)}
}

// BackDirs returns the absolute directions of back_left, back and back_right.
func BackDirs(f Dir) [3]Dir {
	return [3]Dir{Resolve(f, BackLeft), Resolve(f, Back), Resolve(f, BackRight)}
}
