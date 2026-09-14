// Package gems2 (deployed at .../gems2/v1 -- gno's own /vN convention
// requires the package name to match the segment before the suffix,
// confirmed compiler-enforced in the splitpoc spike) is the first
// "version" realm in the Gems split-realm design: mint mechanics (trait
// assembly, on-chain SVG rendering, roster management) live here and can
// be redeployed and re-approved at will, with zero holder migration,
// because ownership + pricing + the whitelist live permanently in
// ../stable instead (see that package's own doc comment). No reveal
// delay in this build -- dropped entirely per request (2026-09-14): a
// mint's real metadata is visible immediately, no sealed placeholder.
package gems2

import (
	"chain"
	"chain/banker"
	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/base64"
	"strings"

	"gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/avl"
	gemsart "gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gemsart2"
	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
	stable "gno.land/r/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/gems2/stable"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	// collectionOwnerHere administers mint mechanics (rosters,
	// minting-open, wallet cap) -- pricing/whitelist administration
	// lives on ../stable instead (see that package's own doc comment).
	// Same address as stable's own collectionOwner; kept as a plain
	// local constant here rather than a cross-realm read on every
	// assertOwner call.
	collectionOwnerHere address = "g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku"

	// mintingOpen is the owner's kill switch on new mints.
	mintingOpen = true

	// maxMintsPerWallet caps how many tokens a single recipient may
	// receive from this version realm -- 0 means unlimited. Resets to 0
	// history on a future version swap (a known simplification of this
	// test build, along with mintedTraitCombos below -- see
	// conversation history, 2026-09-14).
	maxMintsPerWallet int64 = 3
	mintCountByWallet avl.Tree // address.String() -> int64

	nextID seqid.ID

	// mintedTraitCombos is this VERSION's own record of trait
	// combinations already minted -- not shared with a future v2 (a
	// version swap starts a fresh trait space). Acceptable for this
	// test build; a production version would want this on ../stable
	// too if trait-uniqueness must hold across every future redeploy.
	mintedTraitCombos avl.Tree // combo key -> true
)

// traitPreset is one token's small trait selection for the
// assembled-on-read path -- holds just enough for gemsart to
// reconstruct the full image at mint time.
type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
}

/* -------------------------------- Minting ---------------------------------- */

// MintAssembled is the collection's only mint path: assembles a fresh
// random (chain, shape, color, metal, active) combination, verifies
// payment against ../stable's whitelist-adjusted price for the caller,
// then records the mint on ../stable (the only place ownership actually
// lives). See ../stable/stable.gno's own doc comment for why pricing and
// the payment check are split this way.
func MintAssembled(cur realm, to address) grc721.TokenID {
	if !mintingOpen {
		panic("minting is closed")
	}
	if maxMintsPerWallet > 0 && callerAddress() != collectionOwnerHere && MintsByWallet(to) >= maxMintsPerWallet {
		panic(ufmt.Sprintf("wallet %s has already reached the %d-mint limit for this collection", to.String(), maxMintsPerWallet))
	}

	// Payment check is INLINED here (not factored into a helper) for the
	// same reason it was inlined in the original single-realm design:
	// chain/runtime.AssertOriginCall counts real call frames between the
	// origin MsgCall and itself, and a separate helper function adds
	// exactly one hop too many. This realm is the direct target of the
	// origin call (the user calls MintAssembled directly, which then
	// calls stable.RecordMint) so the frame-sensitive checks belong
	// here, not in stable.
	//
	// requiredPrice comes from stable.EffectivePrice -- a plain
	// cross-realm READ (no cur needed), so calling it adds no frame
	// before AssertOriginCall below.
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
		// Forwarded straight to stable's registered owner, same
		// auto-forward pattern the original single-realm design used.
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), stable.Owner(), chain.Coins{{Denom: "ugnot", Amount: got}})
	}

	tp, comboKey := assembleUniqueTraits()
	mintedTraitCombos.Set(comboKey, true)

	tid := grc721.TokenID(nextID.String())
	metadata := assembledMetadata(tid, tp)

	// The actual mint + storage write happens on stable -- this is the
	// version-gate boundary the whole split exists to prove (see
	// stable.RecordMint's own doc comment). cross(cur) required: calling
	// ANOTHER realm's crossing function needs it, not bare cur.
	stable.RecordMint(cross(cur), to, tid, metadata)

	mintCountByWallet.Set(to.String(), MintsByWallet(to)+1)
	nextID.Next()

	return tid
}

// assembledMetadata renders tp's full metadata by calling gemsart's
// on-chain generator -- no reveal step in this build, so this runs at
// mint time and the result is visible immediately.
func assembledMetadata(tid grc721.TokenID, tp traitPreset) grc721.Metadata {
	svg, stone, _, colorName := gemsart.RenderTokenSVG(tp.Chain, tp.Metal, tp.ShapeIdx, tp.ColorIdx, tp.Active, tid.String())
	shapeName := gemsart.ShapeNames[tp.ShapeIdx]
	if stone == "Pearl" {
		shapeName = gemsart.PearlShapeNames[tp.ShapeIdx]
	}
	image := "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
	status := "Sunset"
	if tp.Active {
		status = "Active"
	}
	attrs := []grc721.Trait{
		{TraitType: "Chain", Value: tp.Chain + " Chain"},
		{TraitType: "Stone", Value: stone},
		{TraitType: "Shape", Value: shapeName},
		{TraitType: "Color", Value: colorName},
		{TraitType: "Metal", Value: tp.Metal + " Ring"},
		{TraitType: "Status", Value: status},
	}
	return grc721.Metadata{
		Name:            gemDisplayName(colorName, stone, shapeName, tp.Metal, tp.Chain),
		Description:     ufmt.Sprintf("A %s %s set in %s, minted on %s.", colorName, shapeName, tp.Metal, tp.Chain),
		Image:           image,
		BackgroundColor: "0a0b10",
		Attributes:      attrs,
	}
}

func gemDisplayName(colorName, stone, shape, metal, chain string) string {
	kind := stone
	if kind == "" || kind == "Not Set" {
		kind = "Gem"
	}
	return colorName + " " + kind + " " + shape + " -- " + metal + " Ring - " + chain + " Chain"
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
	colorIdx := rnd.intn(gemsart.ColorPaletteSize(stone))
	shapeCount := len(gemsart.ShapeNames)
	if stone == "Pearl" {
		shapeCount = len(gemsart.PearlShapeNames)
	}
	shapeIdx := rnd.intn(shapeCount)
	metal := gemsart.MetalNames[rnd.intn(len(gemsart.MetalNames))]
	activeDraw := rnd.floatIn(0, 1) < activeProbability
	active := chainName == "MAINNET" || activeDraw

	return traitPreset{
		Chain:    chainName,
		ShapeIdx: shapeIdx,
		ColorIdx: colorIdx,
		Metal:    metal,
		Active:   active,
	}
}

const maxAssembleAttempts = 200

func assembleUniqueTraits() (traitPreset, string) {
	for attempt := 0; attempt < maxAssembleAttempts; attempt++ {
		tp := randomTraitPreset(attempt)
		key := traitComboKey(tp.Chain, tp.ShapeIdx, tp.ColorIdx, tp.Metal, tp.Active)
		if !mintedTraitCombos.Has(key) {
			return tp, key
		}
	}
	panic("could not find an unused trait combination after many attempts -- the collection may be fully minted")
}

func IsTraitComboAvailable(chainName string, shapeIdx, colorIdx int, metal string, active bool) bool {
	key := traitComboKey(chainName, shapeIdx, colorIdx, metal, active)
	return !mintedTraitCombos.Has(key)
}

func MaxUniqueTraitCombos() int64 {
	var total int64
	for _, chainName := range chainRoster {
		stone := gemsart.StoneForChain(chainName)
		shapeCount := len(gemsart.ShapeNames)
		if stone == "Pearl" {
			shapeCount = len(gemsart.PearlShapeNames)
		}
		total += int64(gemsart.ColorPaletteSize(stone)) * int64(shapeCount)
	}
	return total * int64(len(gemsart.MetalNames)) * 2
}

/* ----------------------------- Chain roster ---------------------------- */

var chainRoster = []string{
	"TEST-1", "TEST-2", "TEST-3", "TEST-4", "TEST-5", "TEST-6", "TEST-7",
	"TEST-8", "TEST-9", "TEST-10", "TEST-11", "TEST-12", "TEST-13",
	"TOPAZ-1", "SAPPHIRE-1", "PEARL-1", "BETANET",
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

/* ------------------------- Stone/color extensibility ------------------------ */

func SetStoneForChain(cur realm, chainName, stone string) {
	assertOwner()
	if stone == "" {
		panic("stone must not be empty")
	}
	gemsart.SetStoneForChain(chainName, stone)
}

func AddStoneColor(cur realm, stone, hex, name string) {
	assertOwner()
	if stone == "" || hex == "" || name == "" {
		panic("stone, hex, and name must not be empty")
	}
	gemsart.AddStoneColor(stone, hex, name)
}

func MetalToneHex(metalName string) string  { return gemsart.MetalToneHex(metalName) }
func StoneForChain(chainName string) string { return gemsart.StoneForChain(chainName) }
func ColorPaletteSize(stone string) int64   { return int64(gemsart.ColorPaletteSize(stone)) }
func StoneNames() string                    { return gemsart.StoneNamesCSV() }
func ColorPaletteCSV(stone string) string   { return gemsart.ColorPaletteCSV(stone) }

func ShapeNamesForStone(stone string) string {
	names := gemsart.ShapeNames
	if stone == "Pearl" {
		names = gemsart.PearlShapeNames
	}
	return strings.Join(names, ";")
}

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
}

func MaxMintsPerWallet() int64 { return maxMintsPerWallet }

func SetMaxMintsPerWallet(cur realm, max int64) {
	assertOwner()
	if max < 0 {
		panic("max must be non-negative (0 = unlimited)")
	}
	maxMintsPerWallet = max
}

func MintsByWallet(owner address) int64 {
	n, _ := mintCountByWallet.Get(owner.String()).(int64)
	return n
}

// WithdrawFunds sweeps this realm's own balance to stable's registered
// owner -- normally near-zero, since MintAssembled forwards payment
// directly, but this exists for anything that reaches this realm's
// balance some other way (a stray direct send).
func WithdrawFunds(cur realm, amountUgnot int64) {
	assertOwner()
	if amountUgnot <= 0 {
		panic("amount must be positive")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), stable.Owner(), chain.Coins{{Denom: "ugnot", Amount: amountUgnot}})
}
