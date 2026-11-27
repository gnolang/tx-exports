package bench

import (
	"strings"
	"testing"

	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"
	"gno.land/p/nt/avl/v0"
)

func TestComputeRoundSeed(t *testing.T) {
	// SHA-256 of the ADR-002 preimage: colorado/v1|D:20783:wca|42|1795680000.
	want := [32]byte{
		0x30, 0xbe, 0x0f, 0x9d, 0x52, 0xff, 0x36, 0xbf,
		0x5c, 0xd5, 0x1f, 0x3a, 0xce, 0x76, 0x16, 0x74,
		0xfe, 0xe9, 0x94, 0x3b, 0xb6, 0xcd, 0x71, 0xe1,
		0x93, 0x2a, 0xa6, 0xd3, 0xa8, 0x11, 0x9b, 0xc0,
	}
	first := computeRoundSeed("D:20783:wca", 42, 1795680000)
	if first != want {
		t.Errorf("seed = %x, want %x", first, want)
	}
	if again := computeRoundSeed("D:20783:wca", 42, 1795680000); again != first {
		t.Errorf("same inputs produced a different seed: %x", again)
	}
}

func TestComputePhase(t *testing.T) {
	challenge := &challengeRecord{CommitDeadline: 100, RevealDeadline: 200}
	for _, tc := range []struct {
		now  int64
		want string
	}{
		{99, "commit_open"},
		{100, "reveal_open"},
		{199, "reveal_open"},
		{200, "finalized"},
		{201, "finalized"},
	} {
		if got := computePhase(challenge, tc.now); got != tc.want {
			t.Errorf("phase at %d = %q, want %q", tc.now, got, tc.want)
		}
	}
}

func TestNormalizeModeTag(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want string
		ok   bool
	}{
		{"", "human", true},
		{"human", "human", true},
		{"assisted", "assisted", true},
		{"ai", "ai", true},
		{"AI", "", false},
		{" human ", "", false},
		{"other", "", false},
	} {
		if got, ok := normalizeModeTag(tc.raw); got != tc.want || ok != tc.ok {
			t.Errorf("normalizeModeTag(%q) = (%q, %t), want (%q, %t)", tc.raw, got, ok, tc.want, tc.ok)
		}
	}
}

func TestValidateAgentModel(t *testing.T) {
	max := strings.Repeat("A", 64)
	for _, tc := range []struct {
		raw  string
		want string
		ok   bool
	}{
		{"", "", true},
		{"   ", "", true},
		{" Model  1~ ", "Model  1~", true},
		{max, max, true},
		{" " + max + " ", max, true},
		{max + "A", "", false},
		{"model\n", "", false},
		{"\tmodel", "", false},
		{"model\x00name", "", false},
		{"model\x7f", "", false},
		{"mod\xc3\xa8le", "", false},
	} {
		if got, ok := validateAgentModel(tc.raw); got != tc.want || ok != tc.ok {
			t.Errorf("validateAgentModel(%q) = (%q, %t), want (%q, %t)", tc.raw, got, ok, tc.want, tc.ok)
		}
	}
}

func TestPadInt64(t *testing.T) {
	small := padInt64(9, 4)
	large := padInt64(10, 4)
	if small != "0009" || large != "0010" || small >= large {
		t.Errorf("padded scores must sort numerically: got %q and %q", small, large)
	}
	if got := padInt64(1795680000, 12); got != "001795680000" {
		t.Errorf("padded Unix time = %q, want 001795680000", got)
	}
	if got := padInt64(1000000000, 10); got != "1000000000" {
		t.Errorf("full-width sequence = %q, want 1000000000", got)
	}
}

func TestPrefixRangeEnd(t *testing.T) {
	const prefix = "Q:3|"
	const rankingKey = "Q:3|0009|0010|001795680000|g1solver"
	const commitKey = "Q:3|g1solver"
	tree := avl.NewTree()
	for _, key := range []string{"Q:2|g1solver", rankingKey, commitKey, "Q:30|g1solver", "Q:4|g1solver"} {
		tree.Set(key, key)
	}

	var got []string
	tree.Iterate(prefix, prefixRangeEnd(prefix), func(key string, _ any) bool {
		got = append(got, key)
		return false
	})
	if len(got) != 2 || got[0] != rankingKey || got[1] != commitKey {
		t.Errorf("round range yielded %v, want [%s %s]", got, rankingKey, commitKey)
	}
}

func TestResolveBuiltinAndUnknownRules(t *testing.T) {
	for _, key := range []string{"wca_obtm", "no_fb", "no_half_turns", "checkpoint_cross_f2l", "pattern_checkerboard"} {
		rule, ok := resolveRule(key)
		if !ok || rule == nil || rule.ID() != key {
			t.Errorf("resolveRule(%q) = (%v, %t), want the requested built-in rule", key, rule, ok)
		}
	}
	if rule, ok := resolveRule("missing_rule"); ok || rule != nil {
		t.Errorf("unknown rule resolved to (%v, %t), want (nil, false)", rule, ok)
	}
}

func TestResolveRegisteredRule(cur realm, t *testing.T) {
	const key = "gno.land/r/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/customrule_demo:example"
	rule, _ := cube3x3.BuiltinRule("no_fb")
	customRules.Set(key, registeredRule{Rule: rule})
	defer customRules.Remove(key)

	got, ok := resolveRule(key)
	if !ok || got == nil || got.ID() != "no_fb" {
		t.Errorf("resolveRule(%q) = (%v, %t), want the registered rule", key, got, ok)
	}
}
