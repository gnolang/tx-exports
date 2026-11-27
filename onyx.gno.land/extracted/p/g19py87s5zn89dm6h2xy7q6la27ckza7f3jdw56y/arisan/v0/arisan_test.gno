package arisan

import (
	"strings"
	"testing"
)

func TestParseMode(t *testing.T) {
	cases := []struct {
		in   string
		want Mode
		ok   bool
	}{
		{"giliran", ModeGiliran, true},
		{" Rotation ", ModeGiliran, true},
		{"KOCOK", ModeKocok, true},
		{"draw", ModeKocok, true},
		{"random", ModeKocok, true},
		{"", ModeGiliran, false},
		{"auction", ModeGiliran, false},
	}
	for _, c := range cases {
		got, ok := ParseMode(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("ParseMode(%q) = %v,%v want %v,%v", c.in, got, ok, c.want, c.ok)
		}
	}
	if ModeGiliran.String() != "giliran" || ModeKocok.String() != "kocok" || Mode(9).String() != "unknown" {
		t.Errorf("unexpected Mode.String values")
	}
}

func TestMixEntropyDeterministicAndSensitive(t *testing.T) {
	a := MixEntropy(nil, "g1alice", "100")
	b := MixEntropy(nil, "g1alice", "100")
	if string(a) != string(b) {
		t.Fatalf("MixEntropy must be deterministic")
	}
	if len(a) != 32 {
		t.Fatalf("want 32-byte seed, got %d", len(a))
	}
	// length prefixing: ("ab","c") must differ from ("a","bc")
	if string(MixEntropy(nil, "ab", "c")) == string(MixEntropy(nil, "a", "bc")) {
		t.Fatalf("parts must be length-prefixed")
	}
	// chaining depends on previous seed
	if string(MixEntropy(a, "x")) == string(MixEntropy(nil, "x")) {
		t.Fatalf("previous seed must matter")
	}
}

func TestPickIndexRangeAndSpread(t *testing.T) {
	counts := make([]int, 5)
	seed := []byte("seed")
	for i := 0; i < 500; i++ {
		seed = MixEntropy(seed, "round")
		idx := PickIndex(seed, 5)
		if idx < 0 || idx >= 5 {
			t.Fatalf("index out of range: %d", idx)
		}
		counts[idx]++
	}
	for i, c := range counts {
		// expected 100 each; a fair hash never lands this far off
		if c < 60 || c > 140 {
			t.Errorf("bucket %d has %d hits, distribution looks broken: %v", i, c, counts)
		}
	}
}

func TestPickIndexPanicsOnZero(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatalf("expected panic for n=0")
		}
	}()
	PickIndex([]byte{1}, 0)
}

func TestPickWinner(t *testing.T) {
	if PickWinner(ModeGiliran, nil, nil) != -1 {
		t.Fatalf("no candidates must return -1")
	}
	if got := PickWinner(ModeGiliran, []int{3, 1, 4}, []byte("anything")); got != 3 {
		t.Fatalf("giliran must take the first candidate, got %d", got)
	}
	seed := MixEntropy(nil, "fixed")
	cands := []int{2, 5, 7}
	got := PickWinner(ModeKocok, cands, seed)
	if got != cands[PickIndex(seed, 3)] {
		t.Fatalf("kocok must follow PickIndex")
	}
}

func TestFormatGNOT(t *testing.T) {
	cases := map[int64]string{
		0:          "0 GNOT",
		1000000:    "1 GNOT",
		1500000:    "1.5 GNOT",
		250:        "0.00025 GNOT",
		123456789:  "123.456789 GNOT",
		-2000000:   "-2 GNOT",
		1000000001: "1000.000001 GNOT",
	}
	for in, want := range cases {
		if got := FormatGNOT(in); got != want {
			t.Errorf("FormatGNOT(%d) = %q want %q", in, got, want)
		}
	}
}

func TestShortAddrAndProgress(t *testing.T) {
	a := "g19py87s5zn89dm6h2xy7q6la27ckza7f3jdw56y"
	if got := ShortAddr(a); got != "g19py8…w56y" {
		t.Errorf("ShortAddr = %q", got)
	}
	if ShortAddr("g1short") != "g1short" {
		t.Errorf("short addresses must be unchanged")
	}
	if got := ProgressBar(2, 5, 10); got != "▰▰▰▰▱▱▱▱▱▱" {
		t.Errorf("ProgressBar = %q", got)
	}
	if got := ProgressBar(9, 5, 4); got != "▰▰▰▰" {
		t.Errorf("ProgressBar clamps: %q", got)
	}
	if got := ProgressBar(1, 0, 3); got != "▱▱▱" {
		t.Errorf("ProgressBar zero total: %q", got)
	}
}

func TestWheel(t *testing.T) {
	slots := []Slot{
		{Label: "1", Caption: "Rizki", State: SlotWon},
		{Label: "2", Caption: "<script>", State: SlotPaid},
		{Label: "3", Caption: "Ayu", State: SlotWinner},
		{Label: "4", Caption: "Budi", State: SlotLate},
	}
	svg := Wheel(slots, "4 GNOT", "Putaran 2 / 4")
	if !strings.HasPrefix(svg, "<svg") || !strings.HasSuffix(svg, "</svg>") {
		t.Fatalf("not an svg document")
	}
	if strings.Contains(svg, "<script>") {
		t.Fatalf("captions must be escaped")
	}
	if !strings.Contains(svg, "&lt;script") {
		t.Fatalf("escaped caption missing")
	}
	if strings.Count(svg, `r="26"`) != 4 {
		t.Fatalf("want 4 seats")
	}
	img := WheelImage("wheel", slots, "4 GNOT", "Putaran 2 / 4")
	if !strings.HasPrefix(img, "![wheel](data:image/svg+xml;base64,") {
		t.Fatalf("bad markdown image: %.60s", img)
	}
	if empty := Wheel(nil, "0 GNOT", ""); !strings.Contains(empty, "no members yet") {
		t.Fatalf("empty wheel should say so")
	}
}
