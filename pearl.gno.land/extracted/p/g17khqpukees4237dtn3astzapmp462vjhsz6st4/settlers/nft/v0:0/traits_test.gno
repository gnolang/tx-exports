package nft

import (
	"strconv"
	"testing"
)

var traitFields = []struct {
	name  string
	limit uint8
	set   func(traits *Traits, v uint8)
}{
	{"skin", 2, func(tr *Traits, v uint8) { tr.Skin = v }},
	{"hat color", 4, func(tr *Traits, v uint8) { tr.Hat = v }},
	{"beard color", 3, func(tr *Traits, v uint8) { tr.BeardColor = v }},
	{"tunic", 4, func(tr *Traits, v uint8) { tr.Tunic = v }},
	{"background", 4, func(tr *Traits, v uint8) { tr.Background = v }},
	{"hat shape", 1, func(tr *Traits, v uint8) { tr.HatShape = v }},
	{"flip", 1, func(tr *Traits, v uint8) { tr.Flip = v }},
	{"glasses", 4, func(tr *Traits, v uint8) { tr.Glasses = v }},
	{"beard", 3, func(tr *Traits, v uint8) { tr.Beard = v }},
}

var invalidTraits = []struct {
	name   string
	traits Traits
	err    string
}{
	{"skin", Traits{Skin: 3}, "invalid skin"},
	{"hat color", Traits{Hat: 5}, "invalid hat color"},
	{"beard color", Traits{BeardColor: 4}, "invalid beard color"},
	{"tunic", Traits{Tunic: 5}, "invalid tunic"},
	{"background", Traits{Background: 5}, "invalid background"},
	{"hat shape", Traits{HatShape: 2}, "invalid hat shape"},
	{"flip", Traits{Flip: 2}, "invalid flip"},
	{"glasses", Traits{Glasses: 5}, "invalid glasses"},
	{"beard", Traits{Beard: 4}, "invalid beard"},
}

func TestPackRoundTripsEveryValueOfEveryTrait(t *testing.T) {
	for _, field := range traitFields {
		for v := uint8(0); v <= field.limit; v++ {
			// Arrange
			traits := Traits{}
			field.set(&traits, v)

			// Act
			got, err := FromPacked(Pack(traits))

			// Assert
			assert(t, err == nil && got == traits, field.name+" "+strconv.Itoa(int(v))+": round trip")
		}
	}
}

func TestPackMaximumValue(t *testing.T) {
	// Arrange
	maximum := Traits{Skin: 2, Hat: 4, BeardColor: 3, Tunic: 4, Background: 4, HatShape: 1, Flip: 1, Glasses: 4, Beard: 3}

	// Act
	got := Pack(maximum)

	// Assert
	want := uint32(2 | 4<<2 | 3<<5 | 4<<7 | 4<<10 | 1<<13 | 1<<14 | 4<<15 | 3<<18)
	assert(t, got == want, "packed maximum: "+strconv.FormatUint(uint64(got), 10))
}

func TestFromPackedRejectsInvalidValues(t *testing.T) {
	// Arrange
	tests := []struct {
		name   string
		packed uint32
		err    string
	}{
		{"unused bits", 1 << 20, "invalid packed traits"},
		{"skin", 3, "invalid skin"},
		{"hat color", 5 << 2, "invalid hat color"},
		{"tunic", 5 << 7, "invalid tunic"},
		{"background", 5 << 10, "invalid background"},
		{"glasses", 5 << 15, "invalid glasses"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			_, err := FromPacked(tc.packed)

			// Assert
			assertErrorContains(t, err, tc.err)
		})
	}
}

func TestInvalidTraitsAreNotValid(t *testing.T) {
	for _, tc := range invalidTraits {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			err := tc.traits.Validate()

			// Assert
			assert(t, err != nil, "must not be valid")
			assertErrorContains(t, err, tc.err)
		})
	}
}

func TestAttributesPanicsWithInvalidTraits(t *testing.T) {
	for _, tc := range invalidTraits {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			message := panicMessage(func() { tc.traits.Attributes() })

			// Assert
			assertContains(t, "panic", message, tc.err)
		})
	}
}

func TestOverridingTraitsChangesTheGnome(t *testing.T) {
	// Arrange
	original := NewTraits("alice")
	overridden := original
	overridden.Glasses = 0
	overridden.Beard = 0

	// Act
	svg := RenderSVG(overridden, Options{})

	// Assert
	assert(t, overridden.Validate() == nil, "overridden traits are valid")
	assert(t, svg != RenderSVG(original, Options{}), "the override changes the gnome")
	assert(t, Pack(overridden) != Pack(original), "the override changes the packed traits")
}

func TestSeedRates(t *testing.T) {
	// Arrange
	const total = 5000
	samples := make([]Traits, total)
	for i := range samples {
		samples[i] = NewTraits("odds-" + strconv.Itoa(i))
	}
	tests := []struct {
		name    string
		matches func(Traits) bool
		percent int
	}{
		{"bent tip", func(tr Traits) bool { return tr.HatShape == 1 }, 35},
		{"glasses", func(tr Traits) bool { return tr.Glasses > 0 }, 30},
		{"no beard", func(tr Traits) bool { return tr.Beard == 0 }, 4},
		{"flip", func(tr Traits) bool { return tr.Flip == 1 }, 50},
	}

	for _, tc := range tests {
		// Act
		count := 0
		for _, tr := range samples {
			if tc.matches(tr) {
				count++
			}
		}

		// Assert
		low := total * (tc.percent - 3) / 100
		high := total * (tc.percent + 3) / 100
		if count < low || count > high {
			t.Fatalf("%s: got %d of %d, want %d%% plus or minus 3", tc.name, count, total, tc.percent)
		}
	}
}

func TestAttributesNameEveryTrait(t *testing.T) {
	// Arrange
	traits := Traits{Skin: 1, Hat: 2, BeardColor: 3, Tunic: 4, Background: 0, HatShape: 1, Flip: 1, Glasses: 2, Beard: 0}
	want := []Attribute{
		{"Skin", "Medium"},
		{"Hat color", "Green"},
		{"Hat", "Bent tip (left)"},
		{"Beard color", "Brown"},
		{"Beard", "None"},
		{"Tunic", "Sun"},
		{"Glasses", "Gold"},
		{"Background", "Sky"},
	}

	// Act
	got := traits.Attributes()

	// Assert
	assert(t, len(got) == len(want), "number of attributes")
	for i := range want {
		assert(t, got[i] == want[i], "attribute "+want[i].Type+": "+got[i].Value)
	}
}

func TestAttributesHatDirection(t *testing.T) {
	// Arrange
	tests := []struct {
		name   string
		traits Traits
		want   string
	}{
		{"bent tip to the right", Traits{HatShape: 1}, "Bent tip (right)"},
		{"bent tip to the left", Traits{HatShape: 1, Flip: 1}, "Bent tip (left)"},
		{"tall hat ignores the flip", Traits{Flip: 1}, "Pointed"},
	}

	for _, tc := range tests {
		// Act
		got := tc.traits.Attributes()[2].Value

		// Assert
		assertEqual(t, got, tc.want, tc.name)
	}
}

func TestNormalized(t *testing.T) {
	// Arrange
	tall := Traits{Skin: 1, Hat: 2, BeardColor: 3, Tunic: 4, Background: 1, HatShape: 0, Flip: 1, Glasses: 2, Beard: 2}
	straight := tall
	straight.Flip = 0
	bent := Traits{Skin: 1, Hat: 2, BeardColor: 3, Tunic: 4, Background: 1, HatShape: 1, Flip: 1, Glasses: 2, Beard: 2}
	tests := []struct {
		name   string
		traits Traits
		want   Traits
	}{
		{"tall hat clears the flip", tall, straight},
		{"bent tip keeps the flip", bent, bent},
	}

	for _, tc := range tests {
		// Act
		got := tc.traits.Normalized()

		// Assert
		assert(t, got == tc.want, tc.name)
		assert(t, got.Validate() == nil, tc.name+": normalized traits are valid")
	}
}

func TestFlipChangesTheImageOnlyForABentTip(t *testing.T) {
	// Arrange
	tall := Traits{Skin: 1, Hat: 2, BeardColor: 3, Tunic: 4, Background: 1, HatShape: 0, Flip: 1, Glasses: 2, Beard: 2}
	bent := tall
	bent.HatShape = 1
	tests := []struct {
		name    string
		traits  Traits
		changes bool
	}{
		{"tall hat", tall, false},
		{"bent tip", bent, true},
	}

	for _, tc := range tests {
		flipped := tc.traits
		unflipped := tc.traits
		unflipped.Flip = 0

		// Act
		differs := RenderSVG(flipped, Options{}) != RenderSVG(unflipped, Options{})

		// Assert
		assert(t, differs == tc.changes, tc.name)
	}
}

func TestNormalizedNeverChangesTheImage(t *testing.T) {
	for _, s := range specSeeds {
		// Arrange
		traits := NewTraits(s.seed)

		// Act
		normalized := RenderSVG(traits.Normalized(), Options{})

		// Assert
		assertEqual(t, normalized, RenderSVG(traits, Options{}), "same image, seed "+s.seed)
	}
}
