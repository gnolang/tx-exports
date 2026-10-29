package engine

// GunType identifies a weapon model.
type GunType string

const (
	// NoGun marks an empty gun slot.
	NoGun GunType = ""
	// Colt45 is the one-handed six-shooter every character starts with.
	Colt45 GunType = "colt45"
)

// GunSpec is the static data of a gun model (rules section 10 and the
// WEAPON LISTS).
type GunSpec struct {
	Name      string
	Capacity  int
	OneHanded bool
	Impact    byte // its line of the IMPACT TABLE (see Impact)
	Wielding  int  // its wielding factor: how far it can be thrown (16.21, 17.2)
	Striking  byte // its line of the STRIKING TABLE (see Striking)
}

// Spec returns the model's static data.
func (t GunType) Spec() GunSpec {
	switch t {
	case Colt45:
		return GunSpec{Name: "Colt 45", Capacity: 6, OneHanded: true, Impact: 'B', Wielding: 4, Striking: 'B'}
	}
	return GunSpec{}
}

// GunLocation is where a character keeps a gun (the boxes of the sheet).
type GunLocation int

const (
	Holstered GunLocation = iota
	GunHand
	OtherHand
	BothHands
)

// Hand codes used in plan strings: 0 = gun hand, 1 = other hand, 2 = both
// hands; HandGround, "g" in a gun move, is the hex the character stands in.
const (
	HandGun    = 0
	HandOther  = 1
	HandBoth   = 2
	HandGround = 3
)

// HandLocation maps a plan hand code to the location it designates.
func HandLocation(code int) (GunLocation, bool) {
	switch code {
	case HandGun:
		return GunHand, true
	case HandOther:
		return OtherHand, true
	case HandBoth:
		return BothHands, true
	}
	return 0, false
}

// String returns the location name used in JSON views.
func (l GunLocation) String() string {
	switch l {
	case Holstered:
		return "holstered"
	case GunHand:
		return "gun_hand"
	case OtherHand:
		return "other_hand"
	case BothHands:
		return "both_hands"
	}
	return "?"
}

// Gun is one weapon carried by a character. ID identifies it for the whole
// game (plans refer to it), even among several guns of the same model.
type Gun struct {
	ID       int
	Type     GunType
	Location GunLocation
	Cocked   bool
	Shells   int
	Jammed   bool // every shell crossed off; fires again once completely reloaded (13.31)
	Exploded bool // cannot fire for the rest of the game (13.31)
}

// CanFireFrom reports whether the gun is in a box it can shoot from (13.1):
// a one-handed gun in the gun hand or both hands, a two-handed one in both
// hands.
func (g Gun) CanFireFrom() bool {
	if g.Type == NoGun {
		return false
	}
	if g.Type.Spec().OneHanded {
		return g.Location == GunHand || g.Location == BothHands
	}
	return g.Location == BothHands
}

// MaxGuns is how many guns a character can carry (hands and holsters).
const MaxGuns = 3

// Guns is a character's weapons; empty slots have Type NoGun.
type Guns [MaxGuns]Gun

// Find returns the slot of the gun with the given id, or -1.
func (g Guns) Find(id int) int {
	for i, gun := range g {
		if gun.Type != NoGun && gun.ID == id {
			return i
		}
	}
	return -1
}

// NextID is a free id for a gun added to this character.
func (g Guns) NextID() int {
	n := 0
	for _, gun := range g {
		if gun.Type != NoGun && gun.ID > n {
			n = gun.ID
		}
	}
	return n + 1
}

// At returns the slot of the gun held at a location, or -1.
func (g Guns) At(loc GunLocation) int {
	for i, gun := range g {
		if gun.Type != NoGun && gun.Location == loc {
			return i
		}
	}
	return -1
}

// Firing returns the slot of the gun held in a box it can shoot from
// (rule 11.3), or -1.
func (g Guns) Firing() int {
	for i, gun := range g {
		if gun.CanFireFrom() {
			return i
		}
	}
	return -1
}

// Blocked reports whether a gun other than the one in slot except holds
// loc, or a hand box overlapping it: BOTH HANDS takes the gun hand and the
// other hand, and either hand is taken by a gun in BOTH HANDS.
func (g Guns) Blocked(loc GunLocation, except int) bool {
	for i, gun := range g {
		if i == except || gun.Type == NoGun || gun.Location == Holstered {
			continue
		}
		if gun.Location == loc || gun.Location == BothHands || loc == BothHands {
			return true
		}
	}
	return false
}

// Free returns an empty slot, or -1 when the character carries MaxGuns.
func (g Guns) Free() int {
	for i, gun := range g {
		if gun.Type == NoGun {
			return i
		}
	}
	return -1
}

// Count is the number of guns carried.
func (g Guns) Count() int {
	n := 0
	for _, gun := range g {
		if gun.Type != NoGun {
			n++
		}
	}
	return n
}

// startingGuns is the fixed loadout at game creation: a loaded, uncocked
// Colt 45 in the holster, gun 1.
func startingGuns() Guns {
	return Guns{{ID: 1, Type: Colt45, Location: Holstered, Cocked: false, Shells: 6}}
}
