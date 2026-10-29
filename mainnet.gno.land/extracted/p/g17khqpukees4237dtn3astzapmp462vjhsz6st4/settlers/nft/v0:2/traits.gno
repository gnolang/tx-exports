package nft

import (
	"crypto/sha256"
	"errors"
)

var (
	beardColorNames = [...]string{"White", "Grey", "Ginger", "Brown"}
	beardShapeNames = [...]string{"None", "Long", "Pointy", "Round"}
	backgroundNames = [...]string{"Sky", "Sand", "Mint", "Lilac", "Blush"}
	glassesNames    = [...]string{"None", "Black", "Gold", "Red", "Teal"}
	hatNames        = [...]string{"Red", "Blue", "Green", "Purple", "Orange"}
	skinNames       = [...]string{"Light", "Medium", "Deep"}
	tunicNames      = [...]string{"Sky", "Leaf", "Clay", "Rose", "Sun"}
)

// Attribute is a named trait of a gnome.
type Attribute struct {
	Type  string
	Value string
}

// Traits describe a gnome.
type Traits struct {
	Skin       uint8
	Hat        uint8
	BeardColor uint8
	Tunic      uint8
	Background uint8
	HatShape   uint8 // 0 pointy, 1 bent
	Flip       uint8 // 0 or 1, no effect on pointy hats
	Glasses    uint8
	Beard      uint8
}

// NewTraits derives the traits of the gnome from a seed.
// A single seed always generate the same traits.
// Use `Validate()` to check traits before drawing.
func NewTraits(seed string) Traits {
	data := sha256.Sum256([]byte(seed))
	t := Traits{
		Skin:       data[0] % 3,
		Hat:        data[1] % 5,
		BeardColor: data[2] % 4,
		Tunic:      data[3] % 5,
		Background: data[4] % 5,
		Flip:       data[6] & 1,
	}

	// Gnome with bent hat, about 35%
	if data[5] < 90 {
		t.HatShape = 1
	}

	// Gnome with glasses, about 30%
	if data[7] < 77 {
		t.Glasses = data[8]%4 + 1
	}

	// Gnome without beard is a rare trait, about 4%
	if data[9] >= 10 {
		t.Beard = data[10]%3 + 1
	}
	return t
}

// Validate checks that all the traits are in range.
func (t Traits) Validate() error {
	switch {
	case t.Skin > 2:
		return errors.New("invalid skin")
	case t.Hat > 4:
		return errors.New("invalid hat color")
	case t.BeardColor > 3:
		return errors.New("invalid beard color")
	case t.Tunic > 4:
		return errors.New("invalid tunic")
	case t.Background > 4:
		return errors.New("invalid background")
	case t.HatShape > 1:
		return errors.New("invalid hat shape")
	case t.Flip > 1:
		return errors.New("invalid flip")
	case t.Glasses > 4:
		return errors.New("invalid glasses")
	case t.Beard > 3:
		return errors.New("invalid beard")
	}
	return nil
}

// Normalized returns the traits with the flip cleared when it has no effect.
// Two traits that draw the same gnome have the same normalized traits, so
// this is the value to compare and to keep when gnomes must be different.
func (t Traits) Normalized() Traits {
	// Clear trait when hat is pointy.
	if t.HatShape == 0 {
		t.Flip = 0
	}
	return t
}

// Attributes returns the traits of a gnome with their names.
// It panics when traits are not valid.
func (t Traits) Attributes() []Attribute {
	if err := t.Validate(); err != nil {
		panic(err.Error())
	}

	hat := "Pointed"
	if t.HatShape == 1 {
		hat = "Bent tip (right)"
		if t.Flip == 1 {
			hat = "Bent tip (left)"
		}
	}

	return []Attribute{
		{"Skin", skinNames[t.Skin]},
		{"Hat color", hatNames[t.Hat]},
		{"Hat", hat},
		{"Beard color", beardColorNames[t.BeardColor]},
		{"Beard", beardShapeNames[t.Beard]},
		{"Tunic", tunicNames[t.Tunic]},
		{"Glasses", glassesNames[t.Glasses]},
		{"Background", backgroundNames[t.Background]},
	}
}

// Pack packs the traits in 20 bits.
func Pack(t Traits) uint32 {
	// Bits:
	//   0-1   skin
	//   2-4   hat
	//   5-6   beard color
	//   7-9   tunic
	//   10-12 background
	//   13    hat shape
	//   14    flip
	//   15-17 glasses
	//   18-19 beard
	return uint32(t.Skin) |
		uint32(t.Hat)<<2 |
		uint32(t.BeardColor)<<5 |
		uint32(t.Tunic)<<7 |
		uint32(t.Background)<<10 |
		uint32(t.HatShape)<<13 |
		uint32(t.Flip)<<14 |
		uint32(t.Glasses)<<15 |
		uint32(t.Beard)<<18
}

// Unpack unpacks the traits.
// It does not check the values, use FromPacked for untrusted input.
func Unpack(v uint32) Traits {
	return Traits{
		Skin:       uint8(v & 3),
		Hat:        uint8((v >> 2) & 7),
		BeardColor: uint8((v >> 5) & 3),
		Tunic:      uint8((v >> 7) & 7),
		Background: uint8((v >> 10) & 7),
		HatShape:   uint8((v >> 13) & 1),
		Flip:       uint8((v >> 14) & 1),
		Glasses:    uint8((v >> 15) & 7),
		Beard:      uint8((v >> 18) & 3),
	}
}

// FromPacked unpacks traits and checks them.
func FromPacked(v uint32) (Traits, error) {
	if v>>20 != 0 {
		return Traits{}, errors.New("invalid packed traits")
	}

	t := Unpack(v)
	if err := t.Validate(); err != nil {
		return Traits{}, err
	}
	return t, nil
}
