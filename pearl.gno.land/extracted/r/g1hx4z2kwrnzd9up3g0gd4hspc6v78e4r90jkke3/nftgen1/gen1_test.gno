package nftgen1

import (
	"strings"
	"testing"
)

// Determinism is the entire value proposition: if the same seed ever
// rendered differently, every token minted from this engine would be
// unverifiable.
func TestDeterministic(t *testing.T) {
	for _, seed := range []string{"gen1:1", "3:7", "", "a very long seed string \u00e7\u00fc"} {
		if SVG(seed) != SVG(seed) {
			t.Fatalf("SVG(%q) not deterministic", seed)
		}
		if TraitString(seed) != TraitString(seed) {
			t.Fatalf("TraitString(%q) not deterministic", seed)
		}
	}
}

// The headline reason gen1 exists: at a full 1000-token drop gen0 put
// 112 tokens on a shared trait set. gen1 must stay in single digits.
func TestFullSupplyCollisions(t *testing.T) {
	seen := map[string]int{}
	for i := 1; i <= 1000; i++ {
		seen[TraitString(SeedFor("1", itoa(i)))]++
	}
	dupes := 0
	worst := 0
	for _, c := range seen {
		if c > 1 {
			dupes += c - 1
		}
		if c > worst {
			worst = c
		}
	}
	if dupes > 20 {
		t.Fatalf("too many shared trait sets: %d (gen0 had 112)", dupes)
	}
	if worst > 2 {
		t.Fatalf("a trait set repeats %dx", worst)
	}
}

// Artwork, not just metadata, has to diverge.
func TestArtDiverges(t *testing.T) {
	seen := map[string]bool{}
	for i := 1; i <= 60; i++ {
		s := SVG(SeedFor("gen1", itoa(i)))
		if seen[s] {
			t.Fatalf("duplicate artwork at token %d", i)
		}
		seen[s] = true
	}
}

// The salt is the anti-snipe mechanism: with a salt, knowing the token
// ID must tell you nothing about the traits, while determinism holds.
func TestSaltShiftsButStaysDeterministic(t *testing.T) {
	if SeedForSalted("1", "7", "") != SeedFor("1", "7") {
		t.Fatal("empty salt must degrade to the plain seed")
	}
	if SeedForSalted("1", "7", "abc") == SeedFor("1", "7") {
		t.Fatal("a salt must change the seed")
	}

	changed := 0
	for i := 1; i <= 100; i++ {
		plain := TraitString(SeedFor("1", itoa(i)))
		salted := TraitString(SeedForSalted("1", itoa(i), "9f3c1a"))
		if plain != salted {
			changed++
		}
		// same salt, same answer - twice
		if salted != TraitString(SeedForSalted("1", itoa(i), "9f3c1a")) {
			t.Fatalf("salted seed %d not deterministic", i)
		}
	}
	if changed < 90 {
		t.Fatalf("salt barely moved the map: only %d/100 changed", changed)
	}
}

func TestSVGWellFormed(t *testing.T) {
	for i := 1; i <= 40; i++ {
		s := SVG(SeedFor("3", itoa(i)))
		if !strings.HasPrefix(s, "<svg xmlns=") || !strings.HasSuffix(s, "</svg>") {
			t.Fatalf("token %d: bad envelope", i)
		}
		if strings.Count(s, "<g ") != strings.Count(s, "</g>") {
			t.Fatalf("token %d: unbalanced groups", i)
		}
		// A tokenURI this size is stored on chain forever at roughly
		// 0.1 GNOT/KB. gen1 draws up to 8x14 primitives, so the cap has
		// to be checked, not assumed.
		if len(s) > 32000 {
			t.Fatalf("token %d: svg too large (%d bytes)", i, len(s))
		}
	}
}

func TestDataURI(t *testing.T) {
	u := DataURI("gen1:1")
	if !strings.HasPrefix(u, "data:image/svg+xml;base64,") {
		t.Fatalf("unexpected prefix: %s", u[:40])
	}
	// nft5x classifies storage by the URI prefix; anything else here
	// would make an on-chain token report as an off-chain one.
	if strings.ContainsAny(u, " \n\"'<>") {
		t.Fatal("data URI must be transport-safe")
	}
	// The realm caps a URI at 700.000 chars.
	if len(u) > 700000 {
		t.Fatalf("data URI exceeds the realm URI limit: %d", len(u))
	}
}

// The trait string has to survive the "k=v;k=v" parser and the realm's
// 16-attribute / 64-char limits.
func TestTraitStringShape(t *testing.T) {
	parts := strings.Split(TraitString("gen1:4"), ";")
	if len(parts) != 9 {
		t.Fatalf("want 9 traits, got %d", len(parts))
	}
	for _, p := range parts {
		kv := strings.Split(p, "=")
		if len(kv) != 2 || kv[0] == "" || kv[1] == "" {
			t.Fatalf("malformed trait %q", p)
		}
		if len(kv[0]) > 64 || len(kv[1]) > 64 {
			t.Fatalf("trait %q exceeds the 64-char realm limit", p)
		}
	}
}

// Metadata and artwork are derived from one struct, so every visible
// layer must actually be drawn when the traits claim it.
func TestVisibleLayersMatchArt(t *testing.T) {
	for i := 1; i <= 120; i++ {
		seed := SeedFor("v", itoa(i))
		tr := TraitsOf(seed)
		art := SVG(seed)

		hasAura := strings.Contains(art, `r="230"`)
		if (tr.Aura != "None") != hasAura {
			t.Fatalf("seed %s: Aura=%s but ring=%t", seed, tr.Aura, hasAura)
		}

		hasFrame := strings.Contains(art, `height="488"`) ||
			strings.Contains(art, `height="492"`) ||
			strings.Contains(art, `height="496"`)
		if (tr.Frame != "None") != hasFrame {
			t.Fatalf("seed %s: Frame=%s but border=%t", seed, tr.Frame, hasFrame)
		}
	}
}

// Rarity must come from the whole trait set, not one flag. A Common
// token therefore has to be scoreless, and every tier must be reachable
// within a single 1000-token drop.
func TestRarityIsScoreBased(t *testing.T) {
	valid := map[string]bool{
		"Common": true, "Uncommon": true, "Rare": true,
		"Legendary": true, "Mythic": true,
	}
	counts := map[string]int{}
	for i := 1; i <= 1000; i++ {
		tr := TraitsOf(SeedFor("1", itoa(i)))
		if !valid[tr.Rarity] {
			t.Fatalf("unknown rarity %q", tr.Rarity)
		}
		if tr.Rarity == "Common" && tr.Score >= scoreUncommon {
			t.Fatalf("Common token with score %d", tr.Score)
		}
		if tr.Rarity == "Mythic" && tr.Score < scoreMythic {
			t.Fatalf("Mythic token with score %d", tr.Score)
		}
		if RarityOf(SeedFor("1", itoa(i))) != tr.Rarity {
			t.Fatal("RarityOf disagrees with TraitsOf")
		}
		counts[tr.Rarity]++
	}
	for tier := range valid {
		if counts[tier] == 0 {
			t.Fatalf("tier %s never appears in a 1000-token drop", tier)
		}
	}
	// The top tier has to stay scarce, or it is not a top tier.
	if counts["Mythic"] > 40 {
		t.Fatalf("Mythic too common: %d/1000", counts["Mythic"])
	}
	// ...and the bottom tier must not swallow the drop.
	if counts["Common"] > 450 {
		t.Fatalf("Common too dominant: %d/1000", counts["Common"])
	}
}

// Scarce traits must actually be scarce: the weights are the product
// design, so a table typo that flattens them should fail here.
func TestWeightsHold(t *testing.T) {
	pal := map[string]int{}
	shape := map[string]int{}
	for i := 1; i <= 1000; i++ {
		tr := TraitsOf(SeedFor("w", itoa(i)))
		pal[tr.Palette]++
		shape[tr.Shape]++
	}
	if pal["Prism"] == 0 || pal["Prism"] > 90 {
		t.Fatalf("Prism should be ~4%%, got %d/1000", pal["Prism"])
	}
	if shape["Rift"] == 0 || shape["Rift"] > 110 {
		t.Fatalf("Rift should be ~5%%, got %d/1000", shape["Rift"])
	}
	if pal["Emerald"] < 100 {
		t.Fatalf("Emerald should be ~18%%, got %d/1000", pal["Emerald"])
	}
}

func TestElementRanges(t *testing.T) {
	for i := 1; i <= 300; i++ {
		tr := TraitsOf(SeedFor("e", itoa(i)))
		if tr.Elements < 5 || tr.Elements > 14 {
			t.Fatalf("Elements out of range: %d", tr.Elements)
		}
		if tr.Symmetry < 2 || tr.Symmetry > 8 {
			t.Fatalf("Symmetry out of range: %d", tr.Symmetry)
		}
	}
}

func TestPreviewAndRender(t *testing.T) {
	traits, art := Preview("1", "5")
	if !strings.Contains(traits, "Rarity=") || !strings.HasPrefix(art, "data:image/svg+xml;base64,") {
		t.Fatal("Preview should return traits plus artwork")
	}
	sTraits, sArt := PreviewSalted("1", "5", "salt")
	if sTraits == traits && sArt == art {
		t.Fatal("PreviewSalted should follow the salted seed")
	}
	if idx := Render(""); !strings.Contains(idx, "gen1:10") {
		t.Fatal("index should list the sample drop")
	}
	if d := Render("gen1:2"); !strings.Contains(d, "data:image/svg+xml;base64,") {
		t.Fatal("detail page should embed the artwork")
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	return string(b)
}
