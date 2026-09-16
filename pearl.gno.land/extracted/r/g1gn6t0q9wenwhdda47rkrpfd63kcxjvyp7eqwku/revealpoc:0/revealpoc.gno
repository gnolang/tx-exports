// Package revealpoc is a throwaway spike, NOT part of the real Gems6
// collection: it exists only to prove whether a delayed-reveal mint
// (the same pattern the older g20 collection already uses, see that
// realm's own doc comments) actually fixes the OutOfGasError problem
// gems6/v1's instant-reveal MintAssembled has been hitting against
// Adena's own gas estimation -- confirmed elsewhere this session that
// the expensive part (gemsart2.RenderTokenSVG, ~90-250M gas depending
// on which shape gets randomly rolled) runs INSIDE gems6/v1's mint
// transaction, which is exactly what g20 avoids by rendering nothing
// at mint time and deferring the real art to a later, ordinary READ
// (TokenURI), which isn't bound by a pre-committed tx-level
// gas-wanted the way a write is.
//
// Self-contained single realm (not the stable/campaign/v1 split) on
// purpose: gems6's own `stable` realm bakes a token's full metadata,
// image included, into RecordMint permanently -- there is no function
// on the currently-deployed, permanent `stable` that can later update
// a token's stored metadata, so a true reveal step cannot be grafted
// onto it. Proving the mechanism here, on a disposable realm, is step
// one; folding it into a real stable-v2 design is a separate, bigger
// piece of work once this confirms the fix actually works.
//
// RevealDelayBlocks is deliberately tiny (a handful of blocks) so this
// can be tested end-to-end within one sitting -- a real production
// value would be tuned separately.
package revealpoc

import (
	"crypto/sha256"
	"encoding/base64"

	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"

	"gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/avl"
	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
	gemsart "gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gemsart2"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	CollectionName   = "Gems Reveal PoC"
	CollectionSymbol = "GEMSRP"

	// RevealDelayBlocks: kept small on purpose -- see this file's own
	// package doc comment.
	RevealDelayBlocks = 3

	realmRelPath = "/r/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/revealpoc"
)

var (
	nft *grc721.MetadataNFT

	collectionOwner address = "g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku"
	mintingOpen             = true

	nextID seqid.ID

	// sealedData: tid.String() -> traitPreset, the trait selection a
	// mint locked in but hasn't rendered yet.
	sealedData avl.Tree
	// mintHeight: tid.String() -> int64, the block a token was minted
	// at -- Age/IsRevealed compare against this.
	mintHeight avl.Tree
	// mintedTraitCombos: comboKey -> true, same uniqueness-history
	// purpose as the real collection's stable.IsTraitComboAvailable.
	mintedTraitCombos avl.Tree

	mintedIDs []grc721.TokenID

	sealedImage string
)

func init(cur realm) {
	nft = grc721.NewNFTWithMetadata(0, cur, CollectionName, CollectionSymbol)
	svg := `<svg xmlns="http://www.w3.org/2000/svg" width="170" height="170" viewBox="0 0 170 170">` +
		`<rect width="170" height="170" fill="#0a0b10"/>` +
		`<circle cx="85" cy="78" r="34" fill="none" stroke="#555" stroke-width="4"/>` +
		`<text x="85" y="83" font-size="12" text-anchor="middle" fill="#999" font-family="monospace">SEALED</text>` +
		`</svg>`
	sealedImage = "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

/* ------------------------------ standard reads ------------------------------ */

func Name() string      { return CollectionName }
func Symbol() string    { return CollectionSymbol }
func TokenCount() int64 { return nft.TokenCount() }
func Owner() address    { return collectionOwner }
func MintingOpen() bool { return mintingOpen }

func OwnerOf(tid grc721.TokenID) (address, error) { return nft.OwnerOf(tid) }
func BalanceOf(owner address) (int64, error)      { return nft.BalanceOf(owner) }

/* -------------------------------- reveal logic ------------------------------- */

// traitPreset is one token's locked-in trait selection -- everything
// needed to reconstruct the real image once revealed.
type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
}

// Age returns real blocks elapsed since tid was minted, or -1 if it
// doesn't exist / was never sealed.
func Age(tid grc721.TokenID) int64 {
	h := mintHeight.Get(tid.String())
	if h == nil {
		return -1
	}
	return runtime.ChainHeight() - h.(int64)
}

// IsRevealed reports whether tid's real metadata is visible yet.
func IsRevealed(tid grc721.TokenID) bool {
	if _, isTraitPreset := sealedData.Get(tid.String()).(traitPreset); !isTraitPreset {
		return true
	}
	age := Age(tid)
	return age >= 0 && age >= RevealDelayBlocks
}

// currentMetadata is what every reader-facing function returns: the
// sealed placeholder before reveal, the real assembled art after --
// computed HERE, on a plain read, never inside MintAssembled's own
// gas-metered transaction. This is the entire point of the spike.
func currentMetadata(tid grc721.TokenID) (grc721.Metadata, error) {
	stored, err := nft.TokenMetadata(tid)
	if err != nil {
		return stored, err
	}
	tp, hadReveal := sealedData.Get(tid.String()).(traitPreset)
	if !hadReveal {
		return stored, nil
	}
	if !IsRevealed(tid) {
		return stored, nil // still sealed
	}
	return assembledMetadata(tid, tp), nil
}

func TokenURI(tid grc721.TokenID) (string, error) {
	metadata, err := currentMetadata(tid)
	if err != nil {
		return "", err
	}
	return metadataDataURI(metadata), nil
}

func TokenMetadata(tid grc721.TokenID) (grc721.Metadata, error) {
	return currentMetadata(tid)
}

// assembledMetadata renders tp's full metadata on demand by calling
// gemsart2's on-chain generator -- only reached once IsRevealed(tid)
// is true. This is the expensive call (~90-250M gas depending on
// shape) that gems6/v1 currently makes INSIDE its mint transaction;
// here it only ever runs from a read.
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
	return grc721.Metadata{
		Name:            colorName + " " + stone + " " + shapeName + " -- " + tp.Metal + " Ring - " + tp.Chain + " Chain",
		Description:     ufmt.Sprintf("A %s %s set in %s, minted on %s. (Reveal PoC)", colorName, shapeName, tp.Metal, tp.Chain),
		Image:           image,
		BackgroundColor: "0a0b10",
		Attributes: []grc721.Trait{
			{TraitType: "Chain", Value: tp.Chain + " Chain"},
			{TraitType: "Stone", Value: stone},
			{TraitType: "Shape", Value: shapeName},
			{TraitType: "Color", Value: colorName},
			{TraitType: "Metal", Value: tp.Metal + " Ring"},
			{TraitType: "Status", Value: status},
		},
	}
}

func jsonEscape(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			out = append(out, '\\', '"')
		case '\\':
			out = append(out, '\\', '\\')
		default:
			out = append(out, c)
		}
	}
	return string(out)
}

func metadataDataURI(m grc721.Metadata) string {
	b := `{"name":"` + jsonEscape(m.Name) + `","description":"` + jsonEscape(m.Description) + `","image":"` + jsonEscape(m.Image) + `","attributes":[`
	for i, t := range m.Attributes {
		if i > 0 {
			b += ","
		}
		b += `{"trait_type":"` + jsonEscape(t.TraitType) + `","value":"` + jsonEscape(t.Value) + `"}`
	}
	b += `]}`
	return "data:application/json;base64," + base64.StdEncoding.EncodeToString([]byte(b))
}

/* -------------------------------- Minting ---------------------------------- */

const activeProbability = 0.2

var chainRoster = []string{
	"TEST-1", "TEST-2", "TEST-3", "TEST-4", "TEST-5", "TEST-6", "TEST-7",
	"TEST-8", "TEST-9", "TEST-10", "TEST-11", "TEST-12", "TEST-13",
	"TOPAZ-1", "SAPPHIRE-1", "PEARL-1", "BETANET",
}

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

func traitComboKey(chainName string, shapeIdx, colorIdx int, metal string, active bool) string {
	return ufmt.Sprintf("%s|%d|%d|%s|%t", chainName, shapeIdx, colorIdx, metal, active)
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
	active := rnd.floatIn(0, 1) < activeProbability

	return traitPreset{Chain: chainName, ShapeIdx: shapeIdx, ColorIdx: colorIdx, Metal: metal, Active: active}
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
	panic("could not find an unused trait combination after many attempts")
}

// MintAssembled: the ENTIRE point of this spike. Unlike gems6/v1, this
// never calls gemsart2.RenderTokenSVG -- it writes a tiny, fixed-size
// sealed placeholder instead, so its real gas cost should be small and
// (this is the hypothesis under test) uniform regardless of which
// random trait combination gets drawn, since nothing shape-dependent
// runs during the mint at all.
func MintAssembled(cur realm, to address) grc721.TokenID {
	if !mintingOpen {
		panic("minting is closed")
	}

	tp, comboKey := assembleUniqueTraits()
	mintedTraitCombos.Set(comboKey, true)

	tid := grc721.TokenID(nextID.String())
	checkErr(nft.Mint(to, tid))
	checkErr(nft.SetTokenMetadata(to, tid, grc721.Metadata{
		Name:       "Sealed",
		Image:      sealedImage,
		Attributes: []grc721.Trait{{TraitType: "Status", Value: "Sealed"}},
	}))

	height := runtime.ChainHeight()
	mintHeight.Set(tid.String(), height)
	sealedData.Set(tid.String(), tp)

	nextID.Next()
	mintedIDs = append(mintedIDs, tid)

	return tid
}

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("unauthorized: caller is not the collection owner")
	}
}

func SetMintingOpen(cur realm, open bool) {
	assertOwner()
	mintingOpen = open
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}

/* ------------------------------ gnoweb display ------------------------------ */

func Render(path string) string {
	b := "# Gems Reveal PoC\n\n"
	b += "Throwaway spike testing whether a delayed-reveal mint fixes gems6/v1's OutOfGasError problem. Not part of the real collection.\n\n"
	b += ufmt.Sprintf("* **Minted so far**: %d\n", nft.TokenCount())
	b += ufmt.Sprintf("* **Reveal delay**: %d block(s)\n", RevealDelayBlocks)
	if len(mintedIDs) > 0 {
		b += "\n## Tokens\n\n"
		b += "| Index | Revealed? | Age (blocks) |\n|---|---|---|\n"
		for i := len(mintedIDs) - 1; i >= 0; i-- {
			tid := mintedIDs[i]
			b += ufmt.Sprintf("| [#%s](%s:token/%s) | %t | %d |\n", tid.String(), realmRelPath, tid.String(), IsRevealed(tid), Age(tid))
		}
	}
	return b
}