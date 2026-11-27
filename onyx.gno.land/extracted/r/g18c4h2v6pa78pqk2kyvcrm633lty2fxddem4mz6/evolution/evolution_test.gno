package evolution

import "testing"

func TestPulsarEvolution(t *testing.T) {
	if !CanEvolve("pulsar_lance", 10, "prism_lens", 8) {
		t.Fatal("matching equipment at max level should evolve")
	}
	if CanEvolve("pulsar_lance", 9, "prism_lens", 8) {
		t.Fatal("weapon level 9 should not evolve")
	}
	if CanEvolve("pulsar_lance", 10, "prism_lens", 7) {
		t.Fatal("accessory level 7 should not evolve")
	}
	if CanEvolve("pulsar_lance", 10, "wrong_accessory", 8) {
		t.Fatal("wrong accessory should not evolve")
	}
	if CanEvolve("wrong_weapon", 10, "prism_lens", 8) {
		t.Fatal("wrong weapon should not evolve")
	}
}
