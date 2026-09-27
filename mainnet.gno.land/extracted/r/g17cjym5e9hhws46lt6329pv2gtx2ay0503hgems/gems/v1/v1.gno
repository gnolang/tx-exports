// Package gems6v2 (deployed at .../gems6v2/v5, wired to ../stablev5; v4 with the gemsart3d2 art) is the mint-mechanics
// half of the gems6v2 candidate design: trait assembly and chain-
// roster management live here, same as the real gems6/v1. The one
// real difference is what MintAssembled does with the assembled
// traits: it never renders anything -- no gemsart.RenderTokenSVG call
// at all -- it just hands the raw trait fields to ../stable's
// RecordMint, which writes a cheap sealed placeholder. Rendering
// happens later, lazily, on a read (see ../stable's currentMetadata).
// This realm still imports gemsartfab, but only for its roster helper
// functions (StoneForChain, ColorPaletteSize, ShapeNames, ...) used to
// pick a valid random combination -- never for the expensive render
// itself.
package gems

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	unsaferealm "chain/runtime/unsafe"
	"crypto/sha256"
	"strings"

	gemsart "gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gemsart3d2"
	"gno.land/p/nt/grc721/v0"
	stable "gno.land/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gems/stable"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	collectionOwnerHere address = "g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems"

	mintingOpen = true

	maxMintsPerWallet int64 = 0

	nextID seqid.ID
)

/* -------------------------------- Minting ---------------------------------- */

// MintAssembled: assembles a fresh random (chain, shape, color, metal,
// active) combination, verifies payment against ../stable's discount-
// adjusted price, then hands the RAW trait fields (not a rendered
// image) to ../stable.RecordMint -- the render happens later, lazily,
// on a read. This is the whole fix: nothing shape-dependent runs
// inside this transaction, so its real gas cost stays small and
// uniform regardless of which random trait combination gets drawn
// (confirmed on the throwaway revealpoc spike before this real
// split-realm version was built).
func MintAssembled(cur realm, to address) grc721.TokenID {
	if !mintingOpen {
		panic("minting is closed")
	}
	if maxMintsPerWallet > 0 && callerAddress() != collectionOwnerHere && stable.MintsByWallet(to) >= maxMintsPerWallet {
		panic(ufmt.Sprintf("wallet %s has already reached the %d-mint limit for this collection", to.String(), maxMintsPerWallet))
	}

	caller := callerAddress()
	requiredPrice := stable.EffectivePrice(caller)
	if requiredPrice != 0 {
		runtime.AssertOriginCall()
		if !unsaferealm.PreviousRealm().IsUserCall() {
			panic("payment verification requires a direct user call")
		}
		got := unsaferealm.OriginSend().AmountOf("ugnot")
		if got != requiredPrice {
			panic(ufmt.Sprintf("payment required: exactly %d ugnot, got %d", requiredPrice, got))
		}
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), stable.Owner(), chain.Coins{{Denom: "ugnot", Amount: got}})
	}

	tp, comboKey := assembleUniqueTraits()

	// plain numbers from 1 (#1, #2, ...), not seqid's padded base-32
	// string ("000003q"): what collectors and marketplaces expect to read
	tid := grc721.TokenID(ufmt.Sprintf("%d", uint64(nextID)+1))
	stable.RecordMint(cross(cur), to, caller, tid, tp.Chain, tp.ShapeIdx, tp.ColorIdx, tp.Metal, tp.Active, comboKey, rarityTier(tp))

	nextID.Next()

	return tid
}

/* --------------------------- trait assembly --------------------------- */

type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
}

func traitComboKey(chainName string, shapeIdx, colorIdx int, metal string, active bool) string {
	return ufmt.Sprintf("%s|%d|%d|%s|%t", chainName, shapeIdx, colorIdx, metal, active)
}

const activeProbability = 0.2

type prng struct {
	seed string
	n    int
}

func newPRNG(seed string) *prng { return &prng{seed: seed} }

func (p *prng) next() uint64 {
	p.n++
	material := ufmt.Sprintf("%s:%d", p.seed, p.n)
	sum := sha256.Sum256([]byte(material))
	var v uint64
	for i := 0; i < 8; i++ {
		v = v<<8 | uint64(sum[i])
	}
	return v
}

func (p *prng) floatIn(lo, hi float64) float64 {
	frac := float64(p.next()%1000000) / 1000000.0
	return lo + frac*(hi-lo)
}

func (p *prng) intn(n int) int {
	if n <= 1 {
		return 0
	}
	return int(p.next() % uint64(n))
}

func randomTraitPreset(attempt int) traitPreset {
	material := ufmt.Sprintf("assemble:%d:%d:%s:%d",
		runtime.ChainHeight(), uint64(nextID), callerAddress().String(), attempt)
	rnd := newPRNG(material)

	chainName := chainRoster[rnd.intn(len(chainRoster))]
	stone := gemsart.StoneForChain(chainName)
	// colour by the stone's real-world odds (gemsart.colorWeights)
	colorIdx := gemsart.PickColorIndex(stone, rnd.next())
	// only cuts the stone is really sold in; pearls have their own shapes
	var shapeIdx int
	if stone == "Pearl" {
		shapeIdx = rnd.intn(len(gemsart.PearlShapeNames))
	} else {
		cuts := gemsart.CutsForStone(stone)
		shapeIdx = cuts[rnd.intn(len(cuts))]
	}
	metal := gemsart.MetalNames[rnd.intn(len(gemsart.MetalNames))]
	// mainnet never sunsets: always Active, so metadata matches the image
	active := rnd.floatIn(0, 1) < activeProbability || gemsart.ChainAlwaysActive(chainName)

	return traitPreset{Chain: chainName, ShapeIdx: shapeIdx, ColorIdx: colorIdx, Metal: metal, Active: active}
}

const maxAssembleAttempts = 200

func assembleUniqueTraits() (traitPreset, string) {
	for attempt := 0; attempt < maxAssembleAttempts; attempt++ {
		tp := randomTraitPreset(attempt)
		key := traitComboKey(tp.Chain, tp.ShapeIdx, tp.ColorIdx, tp.Metal, tp.Active)
		if stable.IsTraitComboAvailable(key) {
			return tp, key
		}
	}
	panic("could not find an unused trait combination after many attempts -- the collection may be fully minted")
}

func IsTraitComboAvailable(chainName string, shapeIdx, colorIdx int, metal string, active bool) bool {
	key := traitComboKey(chainName, shapeIdx, colorIdx, metal, active)
	return stable.IsTraitComboAvailable(key)
}

func MaxUniqueTraitCombos() int64 {
	var total int64
	for _, chainName := range chainRoster {
		stone := gemsart.StoneForChain(chainName)
		shapeCount := len(gemsart.CutsForStone(stone))
		if stone == "Pearl" {
			shapeCount = len(gemsart.PearlShapeNames)
		}
		states := int64(2) // active or sunset
		if gemsart.ChainAlwaysActive(chainName) {
			states = 1
		}
		total += int64(gemsart.ColorPaletteSize(stone)) * int64(shapeCount) * states
	}
	return total * int64(len(gemsart.MetalNames))
}

/* -------------------------------- rarity -------------------------------- */

// ComboProbability is the chance (0..1) that one mint draws this piece's
// look: its stone (the share of roster chains that carry it), its cut
// (even among the stone's cuts), its colour (the stone's colour odds) and
// its status (20% active; always active on mainnet). Ring metal and the
// chain's own name are equally likely for every piece, so they leave the
// ranking unchanged and are left out.
func ComboProbability(chainName string, shapeIdx, colorIdx int, active bool) float64 {
	stone := gemsart.StoneForChain(chainName)
	same := 0
	for _, c := range chainRoster {
		if gemsart.StoneForChain(c) == stone {
			same++
		}
	}
	p := float64(same) / float64(len(chainRoster))
	if stone == "Pearl" {
		p /= float64(len(gemsart.PearlShapeNames))
	} else {
		p /= float64(len(gemsart.CutsForStone(stone)))
	}
	p *= gemsart.ColorProbability(stone, colorIdx)
	if !gemsart.ChainAlwaysActive(chainName) {
		if active {
			p *= activeProbability
		} else {
			p *= 1 - activeProbability
		}
	}
	return p
}

// rarityTiers are upper bounds on ComboProbability, rarest first. Set
// (2026-09-25) from the full distribution of all 691 looks on the
// 18-chain roster, each bound the midpoint between two neighbouring
// probability values, so no two equally likely looks fall on different
// sides and float rounding cannot move one. Shares of mints:
//   Legendary 1.3%, Epic 3.5%, Rare 11.1%, Uncommon 25.0%, Common 59.1%.
// A tier is fixed at mint (stored with the token); adding a chain later
// only changes the odds of new mints, never an existing token's tier.
var rarityTiers = []struct {
	name string
	maxP float64
}{
	{"Legendary", 0.000127233877},
	{"Epic", 0.000423465423},
	{"Rare", 0.000754985755},
	{"Uncommon", 0.00364957265},
}

func rarityTier(tp traitPreset) string {
	p := ComboProbability(tp.Chain, tp.ShapeIdx, tp.ColorIdx, tp.Active)
	for _, t := range rarityTiers {
		if p <= t.maxP {
			return t.name
		}
	}
	return "Common"
}

/* ----------------------------- Chain roster ---------------------------- */

var chainRoster = []string{
	"TEST-1", "TEST-2", "TEST-3", "TEST-4", "TEST-5", "TEST-6", "TEST-7",
	"TEST-8", "TEST-9", "TEST-10", "TEST-11", "TEST-12", "TEST-13",
	"TOPAZ-1", "SAPPHIRE-1", "PEARL-1", "BETANET", "GNOLAND-1",
}

func AddChain(cur realm, chainName string) {
	assertOwner()
	if chainName == "" {
		panic("chain name must not be empty")
	}
	for _, c := range chainRoster {
		if c == chainName {
			panic("chain already in the roster")
		}
	}
	chainRoster = append(chainRoster, chainName)
}

func ChainRosterSize() int64 { return int64(len(chainRoster)) }
func ChainRosterCSV() string { return strings.Join(chainRoster, ";") }

/* ----------------------------- Owner controls -------------------------------- */

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwnerHere {
		panic("unauthorized: caller is not the collection owner")
	}
}

func MintingOpen() bool { return mintingOpen }

func SetMintingOpen(cur realm, open bool) {
	assertOwner()
	mintingOpen = open
	stable.ReportMintingOpen(cross(cur), open)
}

func MaxMintsPerWallet() int64 { return maxMintsPerWallet }

func SetMaxMintsPerWallet(cur realm, max int64) {
	assertOwner()
	if max < 0 {
		panic("max must be non-negative (0 = unlimited)")
	}
	maxMintsPerWallet = max
	stable.ReportMaxMintsPerWallet(cross(cur), max)
}

func MintsByWallet(owner address) int64 {
	return stable.MintsByWallet(owner)
}
