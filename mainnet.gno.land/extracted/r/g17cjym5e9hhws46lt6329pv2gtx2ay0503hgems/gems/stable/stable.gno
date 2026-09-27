// Package stablev4 is the permanent half of the gems6v2 split-realm
// design (stablev3 plus two fixes from the 2026-09-15 Pearl test run:
// a burned token's own page, and no per-token copy of the sealed image) -- a candidate successor to the real gems6/stable, built to
// prove two things together before either goes anywhere near mainnet:
// a delayed-reveal mint (fixing the OutOfGasError problem the real
// gems6/v1's instant-reveal MintAssembled has against Adena's own gas
// estimation -- confirmed on a throwaway single-realm spike,
// gno.land/r/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/revealpoc,
// before this real split-realm version was attempted), and the
// approved gemsartfab art package (crystal-look repaint + a real Rose
// Cut cascade fix + a facet-merge seam fix on Round Brilliant/Oval).
//
// Deployed under a test address (not the vesting wallet) so this whole
// prototype -- stable, campaign, v2, and gemsartfab itself -- is
// self-contained and doesn't need the real collection's own keys to
// validate. Folding a confirmed-good design into the real mainnet
// deploy is a separate step once this proves out.
//
// Reveal mechanism: MintAssembled records a trait selection and a
// SEALED placeholder image immediately (cheap, see RecordMint's own
// doc comment for why this is the whole point). TokenURI/TokenMetadata
// compute the real image via gemsartfab -- but ONLY once
// RevealDelayBlocks has passed -- through currentMetadata, which is
// the one addition to the real stable's own read path. This DOES mean
// this realm, unlike the real gems6/stable, imports an art package
// directly: unavoidable given gno's static imports (the realm serving
// TokenURI has to know how to render, and rendering can't be deferred
// to "whichever realm is currently approved" the way minting can,
// since a future version's own art package isn't importable before it
// exists). Matches the tradeoff the older g20 collection already
// accepted for the exact same reason -- not a new problem introduced
// here.
//
// Everything else (ownership, whitelist, royalty, claim log, campaign
// wiring) is unchanged from the real gems6/stable -- see that
// package's own doc comments for the full design history.
//
// Ledger: the standard gno.land/p/nt/grc721/v0 (2026-09-26), not a
// vendored grc721. Adena lists only collections whose NewToken/Transfer
// events come from that exact package (see ~/gno-land-dev-notes.md), and
// chain.Emit stamps the emitting package, so this cannot be retrofitted
// later. The package stores ownership only; every token's metadata is
// computed here from its traits (sealedData), never stored per token.
// TokenURI returns the image itself (Adena puts it straight into an
// <img>); TokenMetadata returns the metadata as a JSON string, and
// TokenJSON the classic base64 JSON data URI for marketplaces that want it.
package stable

import (
	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
	campaign "gno.land/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gems/campaign"
	gemsart "gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gemsart3d2"
	"gno.land/p/nt/ufmt/v0"
)

const (
	CollectionName   = "GNO Gems"
	CollectionSymbol = "GEMS"

	// realmRelPath: this realm's own gnoweb-relative path, baked in as
	// a compile-time constant -- see the real gems6/stable's own
	// comment on why (unsaferealm.CurrentRealm() resolves differently
	// nested inside Render than called directly). Bumped for this
	// deployment, per the gemsartfab handoff's own reminder that this
	// gets missed.
	realmRelPath = "/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gems/stable"

	// 6, not 10: every read has a 3,000,000,000 gas ceiling (vm
	// maxGasQuery) and a 3D token renders for up to ~265M (Cushion); 8
	// renders plus page overhead ran out of gas on a local chain, 6 leave
	// about half the budget spare
	// summaryPageSize: tokens per CollectionSummary / WalletSummary call
	// (the mint site's grids). Thumbnail renders, like the gnoweb table;
	// TokenSummary of one token keeps the full art.
	summaryPageSize = 10
	// gnowebListLimit: rows per page of the gnoweb collection table. Rows
	// use the art's thumbnail render (~145-165M gas, vs ~245-265M full),
	// so 10 fit well under the 3B query ceiling; the token page and the
	// summaries the mint site reads keep the full art.
	gnowebListLimit = 10
	pageWindow         = 2
	tokenPageImageSize = "420"

	// RevealDelayBlocks: kept short so this candidate design can be
	// tested end-to-end in one sitting -- a real production value
	// would be tuned separately before mainnet.
	RevealDelayBlocks = 5
)

var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger // private: only this realm mints, burns and moves tokens

	collectionOwner address = "g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems"

	approvedVersion string

	mintPriceUgnot int64 = 100000000 // 100 GNOT, per request

	whitelistBps avl.Tree

	royaltyBps       int64   = 500
	royaltyRecipient address = "g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems"

	mintedIDs []grc721.TokenID

	mintedTraitCombos avl.Tree // combo key -> true
	tokenComboKeys    avl.Tree // tid.String() -> comboKey string
	mintCountByWallet avl.Tree // address.String() -> int64

	mintingOpenMirror       = true
	maxMintsPerWalletMirror int64 = 0

	burnedRecords avl.Tree // tid.String() -> burnRecord
	burnedIDs     []grc721.TokenID

	claimRecords []claimRecord

	// sealedData/mintHeight: the reveal mechanism's own state. tid ->
	// its locked-in trait selection / the block it was minted at.
	// Deleted from both on Burn (releases their storage deposit, same
	// as tokenComboKeys already does) and never touched again once a
	// token is revealed -- IsRevealed keeps working after that point
	// purely from Age, no separate "already revealed" flag needed.
	sealedData avl.Tree // tid.String() -> traitPreset
	mintHeight avl.Tree // tid.String() -> int64

	sealedImage string
)

// traitPreset is one token's locked-in trait selection -- everything
// gemsartfab needs to render the real image once revealed. Owned here
// (not imported from whichever realm minted it) since stable is the
// one place this needs to survive any future mint-mechanics version
// swap.
type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
	Rarity   string // tier fixed at mint by the version realm (v5.rarityTier)
}

type claimRecord struct {
	Wallet     address
	Bps        int64
	MintHeight int64
	Tid        grc721.TokenID
}

// burnRecord keeps a burned token's compact trait selection, not its
// expanded name/description/attribute strings: the text is rebuilt on read
// (traitOnlyMetadata), so a burn frees more storage deposit.
type burnRecord struct {
	BurnedBy   address
	BurnHeight int64
	Traits     traitPreset
}

func (r burnRecord) metadata() Metadata {
	if r.Traits.Chain == "" {
		return Metadata{Name: "Untitled"}
	}
	return traitOnlyMetadata(r.Traits)
}

func init(cur realm) {
	// emits NewToken; the token id becomes "<this realm>.<symbol>.0000000"
	token, ledger = grc721.NewToken(CollectionName, CollectionSymbol, seqid.ID(0), cur)
	svg := `<svg xmlns="http://www.w3.org/2000/svg" width="170" height="170" viewBox="0 0 170 170">` +
		`<rect width="170" height="170" fill="#0a0b10"/>` +
		`<circle cx="85" cy="78" r="34" fill="none" stroke="#555" stroke-width="4"/>` +
		`<text x="85" y="83" font-size="12" text-anchor="middle" fill="#999" font-family="monospace">SEALED</text>` +
		`</svg>`
	sealedImage = "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

// Metadata/Trait: the shape every reader here builds (grc721/v0 keeps no
// metadata of its own). Never stored per token -- see currentMetadata.
type Trait struct {
	TraitType string
	Value     string
}

type Metadata struct {
	Name            string
	Description     string
	Image           string
	BackgroundColor string
	Attributes      []Trait
}

/* ------------------------------ standard reads ------------------------------ */

func Name() string      { return CollectionName }
func Symbol() string    { return CollectionSymbol }
func TokenCount() int64 { return token.TotalSupply() }
func TokenID() string   { return token.ID() }

// GetName/GetSymbol: the Teller-style names some tools look for.
func GetName() string   { return CollectionName }
func GetSymbol() string { return CollectionSymbol }

func OwnerOf(tid grc721.TokenID) (address, error)     { return token.OwnerOf(tid) }
func BalanceOf(owner address) (int64, error)          { return token.BalanceOf(owner) }
func GetApproved(tid grc721.TokenID) (address, error) { return token.GetApproved(tid) }
func IsApprovedForAll(owner, operator address) bool   { return token.IsApprovedForAll(owner, operator) }

func ApprovedVersion() string { return approvedVersion }
func Owner() address          { return collectionOwner }
func MintPrice() int64        { return mintPriceUgnot }

func MintedIDs() []grc721.TokenID { return mintedIDs }
func TotalBurned() int64          { return int64(len(burnedIDs)) }

func MintingOpen() bool        { return mintingOpenMirror }
func MaxMintsPerWallet() int64 { return maxMintsPerWalletMirror }

func MintsByWallet(owner address) int64 {
	n, _ := mintCountByWallet.Get(owner.String()).(int64)
	return n
}

func IsTraitComboAvailable(comboKey string) bool {
	return !mintedTraitCombos.Has(comboKey)
}

func WhitelistBps(wallet address) (bps int64, ok bool) {
	if !whitelistBps.Has(wallet.String()) {
		return 0, false
	}
	return whitelistBps.Get(wallet.String()).(int64), true
}

func WhitelistCount() int64 { return int64(whitelistBps.Size()) }

func WhitelistEntry(index int) (wallet string, bps int64) {
	w, v := whitelistBps.GetByIndex(index)
	return w, v.(int64)
}

func EffectivePrice(caller address) int64 {
	if v, ok := whitelistBps.Get(caller.String()).(int64); ok {
		return mintPriceUgnot * v / 10000
	}
	if bps, _, ok := campaign.Peek(caller); ok {
		return mintPriceUgnot * bps / 10000
	}
	return mintPriceUgnot
}

func RoyaltyInfo(tid grc721.TokenID, salePrice int64) (address, int64, error) {
	if _, err := token.OwnerOf(tid); err != nil {
		return "", 0, err
	}
	return royaltyRecipient, salePrice * royaltyBps / 10000, nil
}

func RoyaltyBps() int64         { return royaltyBps }
func RoyaltyRecipient() address { return royaltyRecipient }

/* -------------------------------- owner-gated -------------------------------- */

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("unauthorized: caller is not the collection owner")
	}
}

func SetApprovedVersion(cur realm, pkgpath string) {
	assertOwner()
	approvedVersion = pkgpath
}

func SetMintPrice(cur realm, ugnot int64) {
	assertOwner()
	if ugnot < 0 {
		panic("price cannot be negative")
	}
	mintPriceUgnot = ugnot
}

func AddToWhitelist(cur realm, wallet address, bps int64) {
	assertOwner()
	if bps < 0 || bps > 10000 {
		panic("bps must be between 0 and 10000")
	}
	whitelistBps.Set(wallet.String(), bps)
}

func AddToWhitelistBatch(cur realm, walletsCSV string, bps int64) {
	assertOwner()
	if bps < 0 || bps > 10000 {
		panic("bps must be between 0 and 10000")
	}
	for _, w := range strings.Split(walletsCSV, ",") {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		whitelistBps.Set(w, bps)
	}
}

func RemoveFromWhitelist(cur realm, wallet address) {
	assertOwner()
	whitelistBps.Remove(wallet.String())
}

func SetRoyaltyBps(cur realm, bps int64) {
	assertOwner()
	if bps < 0 || bps > 10000 {
		panic("bps must be between 0 and 10000")
	}
	royaltyBps = bps
}

func SetRoyaltyRecipient(cur realm, recipient address) {
	assertOwner()
	royaltyRecipient = recipient
}

/* ------------------------------- version-gated -------------------------------- */

func assertCallerIsApprovedVersion(cur realm) {
	caller := cur.Previous().PkgPath()
	if approvedVersion == "" {
		panic("no version realm has been approved yet")
	}
	if caller != approvedVersion {
		panic("unauthorized: caller is not the approved version realm")
	}
}

// RecordMint: the ENTIRE point of this v2 candidate. Unlike the real
// gems6/stable's own RecordMint, this does NOT take a full, rendered
// grc721.Metadata -- it takes the raw trait fields instead, and writes
// a small fixed-size SEALED placeholder to nft's own storage. The real
// image is never computed here, or anywhere, during a mint transaction
// -- see currentMetadata for where it actually happens (a plain read,
// unbound by any tx-level gas-wanted). Only the approved version realm
// may call this. Reserves comboKey atomically with the mint, same
// authoritative-check role the real stable's RecordMint plays.
func RecordMint(cur realm, to address, payer address, tid grc721.TokenID, chainName string, shapeIdx, colorIdx int, metal string, active bool, comboKey string, rarity string) grc721.TokenID {
	assertCallerIsApprovedVersion(cur)
	if mintedTraitCombos.Has(comboKey) {
		panic("trait combination already minted")
	}
	// Ownership only: no metadata is stored per token, not even a
	// "Sealed" record -- currentMetadata derives it from sealedData.
	checkErr(ledger.Mint(to, tid))
	mintedTraitCombos.Set(comboKey, true)
	tokenComboKeys.Set(tid.String(), comboKey)
	mintCountByWallet.Set(to.String(), MintsByWallet(to)+1)
	mintedIDs = append(mintedIDs, tid)

	height := runtime.ChainHeight()
	mintHeight.Set(tid.String(), height)
	sealedData.Set(tid.String(), traitPreset{
		Chain: chainName, ShapeIdx: shapeIdx, ColorIdx: colorIdx, Metal: metal, Active: active, Rarity: rarity,
	})

	if _, hasOverride := whitelistBps.Get(payer.String()).(int64); !hasOverride {
		if bps, ok := campaign.ConsumeDiscount(cross(cur), payer); ok {
			claimRecords = append(claimRecords, claimRecord{
				Wallet:     payer,
				Bps:        bps,
				MintHeight: height,
				Tid:        tid,
			})
		}
	}
	return tid
}

func ClaimCount() int64 { return int64(len(claimRecords)) }

func ClaimAt(index int) (wallet address, bps int64, mintHeight_ int64, tid string) {
	r := claimRecords[index]
	return r.Wallet, r.Bps, r.MintHeight, r.Tid.String()
}

func ReportMintingOpen(cur realm, open bool) {
	assertCallerIsApprovedVersion(cur)
	mintingOpenMirror = open
}

func ReportMaxMintsPerWallet(cur realm, max int64) {
	assertCallerIsApprovedVersion(cur)
	maxMintsPerWalletMirror = max
}

/* -------------------------------- reveal logic ------------------------------- */

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

// currentMetadata is what every reader-facing function below actually
// returns: nft's own stored (sealed) metadata before reveal, or the
// real image assembled fresh from gemsartfab after -- computed on this
// plain read, never inside a mint or any other gas-metered write. This
// is the one addition to the real gems6/stable's own read path.
func currentMetadata(tid grc721.TokenID) (Metadata, error) {
	if _, err := token.OwnerOf(tid); err != nil {
		return Metadata{}, err
	}
	tp, ok := sealedData.Get(tid.String()).(traitPreset)
	if !ok {
		return Metadata{}, grc721.ErrInvalidTokenId
	}
	if !IsRevealed(tid) {
		return sealedMetadata(), nil
	}
	return assembledMetadata(tid, tp), nil
}

// sealedMetadata: what every token shows until its reveal block, the one
// shared placeholder image (not per-token storage).
func sealedMetadata() Metadata {
	return Metadata{Name: "Sealed", Image: sealedImage, BackgroundColor: "0a0b10", Attributes: []Trait{{TraitType: "Status", Value: "Sealed"}}}
}

// listRow is one gnoweb table row's name and image: the name from the
// traits (no render), the image the art's thumbnail render once revealed,
// the shared sealed placeholder before.
func listRow(tid grc721.TokenID) (name, image string) {
	tp, ok := sealedData.Get(tid.String()).(traitPreset)
	if !ok {
		return "Untitled", ""
	}
	if !IsRevealed(tid) {
		return "Sealed", sealedImage
	}
	name = traitOnlyMetadata(tp).Name
	svg := gemsart.RenderTokenThumbSVG(tp.Chain, tp.Metal, tp.ShapeIdx, tp.ColorIdx, tp.Active, tid.String())
	return name, "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

func assembledMetadata(tid grc721.TokenID, tp traitPreset) Metadata {
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
	return Metadata{
		Name:            gemDisplayName(colorName, stone, shapeName, tp.Metal, tp.Chain),
		Description:     ufmt.Sprintf("%s %s %s set in %s %s ring, minted on %s.", article(colorName), colorName, shapeName, strings.ToLower(article(tp.Metal)), tp.Metal, tp.Chain),
		Image:           image,
		BackgroundColor: "0a0b10",
		Attributes: []Trait{
			{TraitType: "Chain", Value: tp.Chain},
			{TraitType: "Stone", Value: stone},
			{TraitType: "Shape", Value: shapeName},
			{TraitType: "Color", Value: colorName},
			{TraitType: "Ring", Value: tp.Metal},
			{TraitType: "Status", Value: status},
			{TraitType: "Rarity", Value: tp.Rarity},
		},
	}
}

// article is "An" before a vowel sound (Amethyst, Imperial, Orange), else "A".
func article(word string) string {
	if word != "" && strings.ContainsRune("AEIOUaeiou", rune(word[0])) {
		return "An"
	}
	return "A"
}

func gemDisplayName(colorName, stone, shape, metal, chain string) string {
	// "Amethyst Oval · Gold Ring · TEST-7": the piece, its setting, its
	// chain, split by a middle dot (the old "X -- Y Ring - Z Chain" was a
	// parsing delimiter that leaked into the name). Quartz colour names are
	// the variety names and already say what the stone is (Amethyst,
	// Citrine, Rose Quartz, Rock Crystal...): "Amethyst Oval", not
	// "Amethyst Quartz Oval".
	piece := colorName + " " + stone + " " + shape
	if stone == "Quartz" || stone == "" {
		piece = colorName + " " + shape
	}
	return piece + " · " + metal + " Ring · " + chain
}

// colorNameFor looks up a stone's colorIdx-th color name from
// gemsart.ColorPaletteCSV ("hex:name;hex:name;...") -- a cheap parse,
// not a render. Kept in sync with gemsart.RenderTokenSVG's own internal
// colorForStone by construction (same palette source), without ever
// calling RenderTokenSVG itself.
func colorNameFor(stone string, colorIdx int) string {
	pairs := strings.Split(gemsart.ColorPaletteCSV(stone), ";")
	if colorIdx < 0 || colorIdx >= len(pairs) {
		return ""
	}
	parts := strings.SplitN(pairs[colorIdx], ":", 2)
	if len(parts) != 2 {
		return ""
	}
	return parts[1]
}

// traitOnlyMetadata builds the archived record straight from tp's raw
// fields -- no gemsart.RenderTokenSVG call, so no image, ever. This is
// what Burn archives: the burn record was never meant to keep the
// picture (see Burn's own comment), so there's no reason to pay the
// render cost to build one just to immediately discard it.
func traitOnlyMetadata(tp traitPreset) Metadata {
	stone := gemsart.StoneForChain(tp.Chain)
	shapeName := gemsart.ShapeNames[tp.ShapeIdx]
	if stone == "Pearl" {
		shapeName = gemsart.PearlShapeNames[tp.ShapeIdx]
	}
	colorName := colorNameFor(stone, tp.ColorIdx)
	status := "Sunset"
	if tp.Active {
		status = "Active"
	}
	return Metadata{
		Name:            gemDisplayName(colorName, stone, shapeName, tp.Metal, tp.Chain),
		Description:     ufmt.Sprintf("%s %s %s set in %s %s ring, minted on %s.", article(colorName), colorName, shapeName, strings.ToLower(article(tp.Metal)), tp.Metal, tp.Chain),
		BackgroundColor: "0a0b10",
		Attributes: []Trait{
			{TraitType: "Chain", Value: tp.Chain},
			{TraitType: "Stone", Value: stone},
			{TraitType: "Shape", Value: shapeName},
			{TraitType: "Color", Value: colorName},
			{TraitType: "Ring", Value: tp.Metal},
			{TraitType: "Status", Value: status},
			{TraitType: "Rarity", Value: tp.Rarity},
		},
	}
}

// TokenURI is the token's image itself, as a data URI: the sealed
// placeholder until the reveal block, then the full art. Adena puts it
// straight into an <img>, which also runs the art's CSS animation.
func TokenURI(tid grc721.TokenID) (string, error) {
	metadata, err := currentMetadata(tid)
	if err != nil {
		return "", err
	}
	return metadata.Image, nil
}

// TokenMetadata is the metadata as a JSON string in the camelCase shape
// Adena reads (name, description, backgroundColor, attributes of
// {traitType, value}). No image in it, so it costs no render: the image
// is TokenURI.
func TokenMetadata(tid grc721.TokenID) (string, error) {
	if _, err := token.OwnerOf(tid); err != nil {
		return "", err
	}
	m := sealedMetadata()
	if tp, ok := sealedData.Get(tid.String()).(traitPreset); ok && IsRevealed(tid) {
		m = traitOnlyMetadata(tp)
	}
	m.Image = ""
	return metadataJSON(m, "traitType", "backgroundColor"), nil
}

// TokenJSON is the classic OpenSea-style metadata (snake_case keys, the
// image inline) as a base64 JSON data URI, for marketplaces that expect a
// tokenURI of that shape.
func TokenJSON(tid grc721.TokenID) (string, error) {
	metadata, err := currentMetadata(tid)
	if err != nil {
		return "", err
	}
	return "data:application/json;base64," + base64.StdEncoding.EncodeToString([]byte(metadataJSON(metadata, "trait_type", "background_color"))), nil
}

func jsonEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

func metadataJSON(m Metadata, traitKey, bgKey string) string {
	var b strings.Builder
	b.WriteString(`{"name":"`)
	b.WriteString(jsonEscape(m.Name))
	b.WriteString(`","description":"`)
	b.WriteString(jsonEscape(m.Description))
	b.WriteString(`"`)
	if m.Image != "" {
		b.WriteString(`,"image":"`)
		b.WriteString(jsonEscape(m.Image))
		b.WriteString(`"`)
	}
	if m.BackgroundColor != "" {
		b.WriteString(`,"` + bgKey + `":"`)
		b.WriteString(jsonEscape(m.BackgroundColor))
		b.WriteString(`"`)
	}
	b.WriteString(`,"attributes":[`)
	for i, t := range m.Attributes {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"` + traitKey + `":"`)
		b.WriteString(jsonEscape(t.TraitType))
		b.WriteString(`","value":"`)
		b.WriteString(jsonEscape(t.Value))
		b.WriteString(`"}`)
	}
	b.WriteString("]}")
	return b.String()
}

/* -------------------------- Token-owner actions --------------------------- */

func Approve(cur realm, to address, tid grc721.TokenID) {
	checkErr(ledger.Approve(callerAddress(), to, tid))
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	checkErr(ledger.SetApprovalForAll(callerAddress(), operator, approved))
}

func TransferFrom(cur realm, from, to address, tid grc721.TokenID) {
	checkErr(ledger.TransferFrom(callerAddress(), from, to, tid))
}

// SafeTransferFrom: kept for the standard signature. grc721/v0 has no
// receiver-contract hook, so it is TransferFrom.
func SafeTransferFrom(cur realm, from, to address, tid grc721.TokenID) {
	checkErr(ledger.TransferFrom(callerAddress(), from, to, tid))
}

// Burn destroys a token. Caller must be its current owner. Archives the
// real trait combination as text -- always the real traits, even if
// burned before the reveal delay passed, since sealedData already has
// them regardless of whether TokenURI has started showing them
// publicly yet. Deliberately never renders or stores an image: the
// archive was only ever a text record (see BurnedTokenSummary/
// renderMintedListPage's own "Burned" row), so calling
// gemsart.RenderTokenSVG here just to immediately discard its output
// was pure waste -- confirmed live, a burn on an already-revealed token
// cost ~165M gas, almost entirely that one re-render, roughly the same
// cost the whole reveal-delay design exists to avoid paying on mint.
// Releases the trait combo AND the reveal bookkeeping (sealedData/
// mintHeight) -- maximizes the real storage-deposit refund, same
// reasoning the real gems6/stable's own Burn already documents.
func Burn(cur realm, tid grc721.TokenID) {
	caller := callerAddress()
	owner, err := token.OwnerOf(tid)
	checkErr(err)
	if caller != owner {
		panic(grc721.ErrCallerIsNotOwner)
	}

	key := tid.String()
	archived, _ := sealedData.Get(key).(traitPreset)

	if comboKey, ok := tokenComboKeys.Get(key).(string); ok {
		mintedTraitCombos.Remove(comboKey)
		tokenComboKeys.Remove(key)
	}
	sealedData.Remove(key)
	mintHeight.Remove(key)

	checkErr(ledger.Burn(tid))

	burnedRecords.Set(key, burnRecord{
		BurnedBy:   caller,
		BurnHeight: runtime.ChainHeight(),
		Traits:     archived,
	})
	burnedIDs = append(burnedIDs, tid)
}

/* ------------------------------ gnoweb display ------------------------------ */

func traitsToCSV(attrs []Trait) string {
	pairs := make([]string, len(attrs))
	for i, a := range attrs {
		pairs[i] = a.TraitType + "=" + a.Value
	}
	return strings.Join(pairs, ";")
}

func TokenSummary(tid grc721.TokenID) (string, error) { return tokenSummary(tid, false) }

// thumbSummary is TokenSummary with the art's thumbnail render and the
// metadata built from the traits, so a page of them stays well under the
// query gas ceiling.
func thumbSummary(tid grc721.TokenID) (string, error) { return tokenSummary(tid, true) }

func tokenSummary(tid grc721.TokenID, thumb bool) (string, error) {
	owner, err := token.OwnerOf(tid)
	if err != nil {
		return "", err
	}
	var metadata Metadata
	if tp, ok := sealedData.Get(tid.String()).(traitPreset); thumb && ok && IsRevealed(tid) {
		metadata = traitOnlyMetadata(tp)
		svg := gemsart.RenderTokenThumbSVG(tp.Chain, tp.Metal, tp.ShapeIdx, tp.ColorIdx, tp.Active, tid.String())
		metadata.Image = "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
	} else {
		metadata, err = currentMetadata(tid)
		if err != nil {
			return "", err
		}
	}
	enc := base64.StdEncoding
	fields := []string{
		tid.String(),
		owner.String(),
		enc.EncodeToString([]byte(metadata.Name)),
		enc.EncodeToString([]byte(metadata.Description)),
		enc.EncodeToString([]byte(metadata.Image)),
		"", // external URL: none
		enc.EncodeToString([]byte(traitsToCSV(metadata.Attributes))),
		enc.EncodeToString([]byte(metadata.BackgroundColor)),
	}
	return strings.Join(fields, "|"), nil
}

func CollectionSummary(page int) string {
	total := len(mintedIDs)
	if page < 1 {
		page = 1
	}
	startK := (page - 1) * summaryPageSize
	endK := startK + summaryPageSize
	if endK > total {
		endK = total
	}
	var lines []string
	for k := startK; k < endK; k++ {
		tid := mintedIDs[total-1-k]
		line, err := thumbSummary(tid)
		if err != nil {
			continue
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// walletScanChunk bounds how many ids one WalletSummary call scans;
// walletRenderCap bounds how many of the caller's OWN tokens it renders.
// The second bound is the one that matters: every matched token is a
// full SVG render (TokenSummary -> currentMetadata -> gemsart), and one
// vm/qeval has a fixed gas budget -- a wallet holding 30 pieces made
// the unbounded version fail outright with "out of gas in location:
// CPUCycles" on Pearl (2026-09-16), taking the mint page's "Your
// minted Gems" panel down for exactly the collectors who care most.
// A client pages by calling again with the returned nextIdx until it
// reaches the collection size, same protocol as before; it just gets
// more, smaller pages for a big holder.
const (
	walletScanChunk = 100
	walletRenderCap = summaryPageSize
)

func WalletSummary(owner address, startIdx int64) (summary string, nextIdx int64) {
	total := len(mintedIDs)
	start := int(startIdx)
	if start < 0 {
		start = 0
	}
	end := start + walletScanChunk
	if end > total {
		end = total
	}
	var lines []string
	k := start
	for ; k < end; k++ {
		if len(lines) >= walletRenderCap {
			break
		}
		tid := mintedIDs[total-1-k]
		tokenOwner, err := token.OwnerOf(tid)
		if err != nil || tokenOwner != owner {
			continue
		}
		line, err := thumbSummary(tid)
		if err != nil {
			continue
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n"), int64(k)
}

func BurnedTokenSummary(tid grc721.TokenID) (string, error) {
	raw := burnedRecords.Get(tid.String())
	rec, ok := raw.(burnRecord)
	if !ok {
		return "", grc721.ErrInvalidTokenId
	}
	m := rec.metadata()
	enc := base64.StdEncoding
	fields := []string{
		tid.String(),
		rec.BurnedBy.String(),
		ufmt.Sprintf("%d", rec.BurnHeight),
		enc.EncodeToString([]byte(m.Name)),
		enc.EncodeToString([]byte(m.Description)),
		"", // image: a burn keeps none
		"", // external URL: none
		enc.EncodeToString([]byte(traitsToCSV(m.Attributes))),
		enc.EncodeToString([]byte(m.BackgroundColor)),
	}
	return strings.Join(fields, "|"), nil
}

func bigTokenImage(image string) string {
	const prefix = "data:image/svg+xml;base64,"
	if !strings.HasPrefix(image, prefix) {
		return image
	}
	raw, err := base64.StdEncoding.DecodeString(image[len(prefix):])
	if err != nil {
		return image
	}
	svg := string(raw)
	resized := strings.Replace(svg, `width="170.00" height="170.00"`, `width="`+tokenPageImageSize+`" height="`+tokenPageImageSize+`"`, 1)
	if resized == svg {
		resized = strings.Replace(svg, `width="170" height="170"`, `width="`+tokenPageImageSize+`" height="`+tokenPageImageSize+`"`, 1)
	}
	return prefix + base64.StdEncoding.EncodeToString([]byte(resized))
}

// shortAddr is how lists show an address: g1 + 4 characters … last 4.
func shortAddr(a string) string {
	if len(a) <= 14 {
		return a
	}
	return a[:6] + "…" + a[len(a)-4:]
}

func renderMintedListPage(b *strings.Builder, page int) {
	total := len(mintedIDs)
	if total == 0 {
		return
	}
	totalPages := (total + gnowebListLimit - 1) / gnowebListLimit
	if page < 1 {
		page = 1
	}
	if page > totalPages {
		page = totalPages
	}
	startK := (page - 1) * gnowebListLimit
	endK := startK + gnowebListLimit
	if endK > total {
		endK = total
	}

	b.WriteString("\n## Minted so far\n\n")
	if totalPages > 1 {
		b.WriteString(ufmt.Sprintf("_page %d of %d -- %d minted total_\n\n", page, totalPages, total))
	}
	// Image column centred (so is a burned row's "Burned"). Owners are
	// shortened to g1xxxx…xxxx: the full 40-character address made the
	// Owner column so wide that gnoweb broke "Index" over two lines. The
	// token's own page still shows the full address.
	b.WriteString("| Image | Index | Name | Owner |\n|:---:|:---:|---|---|\n")
	for k := startK; k < endK; k++ {
		tid := mintedIDs[total-1-k]
		link := realmRelPath + ":token/" + tid.String()
		owner, err := token.OwnerOf(tid)
		if err != nil {
			// Burned -- stays in its original chronological position
			// (never skipped: a listing that silently drops rows reads
			// as broken, not as "nothing to see here" -- confirmed live
			// against the real gems6/stable, where an all-burned page
			// rendered as a blank table with no explanation). Pulled
			// from the permanent burnedRecords archive, image always
			// empty by design (see Burn's own doc comment) so "Burned"
			// stands in for it. No wall-clock date is available inside
			// a gno.land realm (only block height) -- shown as that
			// instead of a fabricated date.
			raw := burnedRecords.Get(tid.String())
			rec, ok := raw.(burnRecord)
			if !ok {
				continue // shouldn't happen: burned but no archive record
			}
			name := rec.metadata().Name
			b.WriteString(ufmt.Sprintf("| Burned | [#%s](%s) | %s (burned at block %d) | %s |\n", tid.String(), link, name, rec.BurnHeight, shortAddr(rec.BurnedBy.String())))
			continue
		}
		name, image := listRow(tid)
		imgCell := ""
		if image != "" {
			imgCell = ufmt.Sprintf("[![%s](%s)](%s)", name, image, link)
		}
		b.WriteString(ufmt.Sprintf("| %s | [#%s](%s) | %s | %s |\n", imgCell, tid.String(), link, name, shortAddr(owner.String())))
	}
	b.WriteString("\n")

	renderPageLinks(b, page, totalPages, "page")
}

func renderPageLinks(b *strings.Builder, page, totalPages int, linkBase string) {
	if totalPages <= 1 {
		return
	}
	b.WriteString("\n")
	parts := []string{}
	if page > 1 {
		parts = append(parts, ufmt.Sprintf("[<< First](%s:%s/1)", realmRelPath, linkBase))
		parts = append(parts, ufmt.Sprintf("[<- newer](%s:%s/%d)", realmRelPath, linkBase, page-1))
	}
	lastShown := 0
	for p := 1; p <= totalPages; p++ {
		if p != 1 && p != totalPages && (p < page-pageWindow || p > page+pageWindow) {
			continue
		}
		if lastShown != 0 && p != lastShown+1 {
			parts = append(parts, "...")
		}
		if p == page {
			parts = append(parts, ufmt.Sprintf("**%d**", p))
		} else {
			parts = append(parts, ufmt.Sprintf("[%d](%s:%s/%d)", p, realmRelPath, linkBase, p))
		}
		lastShown = p
	}
	if page < totalPages {
		parts = append(parts, ufmt.Sprintf("[older ->](%s:%s/%d)", realmRelPath, linkBase, page+1))
		parts = append(parts, ufmt.Sprintf("[Last >>](%s:%s/%d)", realmRelPath, linkBase, totalPages))
	}
	b.WriteString(strings.Join(parts, " - "))
	b.WriteString("\n")
}

func renderBurnedListPage(b *strings.Builder, page int) {
	total := len(burnedIDs)
	if total == 0 {
		return
	}
	totalPages := (total + gnowebListLimit - 1) / gnowebListLimit
	if page < 1 {
		page = 1
	}
	if page > totalPages {
		page = totalPages
	}
	startK := (page - 1) * gnowebListLimit
	endK := startK + gnowebListLimit
	if endK > total {
		endK = total
	}

	b.WriteString("\n## Burned tokens\n\n")
	if totalPages > 1 {
		b.WriteString(ufmt.Sprintf("_page %d of %d -- %d burned total_\n\n", page, totalPages, total))
	}
	b.WriteString("| Index | Name | Burned By | Block |\n|:---:|---|---|---|\n")
	for k := startK; k < endK; k++ {
		tid := burnedIDs[total-1-k]
		raw := burnedRecords.Get(tid.String())
		rec, ok := raw.(burnRecord)
		if !ok {
			continue
		}
		name := rec.metadata().Name
		b.WriteString(ufmt.Sprintf("| #%s | %s | %s | %d |\n", tid.String(), name, shortAddr(rec.BurnedBy.String()), rec.BurnHeight))
	}
	b.WriteString("\n")

	renderPageLinks(b, page, totalPages, "burned/page")
}

// renderBurnedTokenPage is the token route for an id that no longer
// exists. If it was burned, its archived record -- name, traits, who
// burned it, at what block -- is shown: the minted list links every
// burned row here, and stablev3 answered that link with a 404, which
// read as a broken site (found in the 2026-09-15 Pearl test run).
// Anything else really is a 404.
func renderBurnedTokenPage(tid grc721.TokenID) string {
	raw := burnedRecords.Get(tid.String())
	rec, ok := raw.(burnRecord)
	if !ok {
		return render404()
	}
	m := rec.metadata()
	name := m.Name
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# %s #%s (burned)\n\n[<- back to collection](%s)\n\n", CollectionName, tid.String(), realmRelPath))
	b.WriteString("## Details\n\n")
	b.WriteString(ufmt.Sprintf("* **Collection**: %s\n", CollectionName))
	b.WriteString(ufmt.Sprintf("* **Name**: %s\n", name))
	b.WriteString(ufmt.Sprintf("* **Index**: #%s\n", tid.String()))
	if m.Description != "" {
		b.WriteString(ufmt.Sprintf("* **Description**: %s\n", m.Description))
	}
	b.WriteString(ufmt.Sprintf("* **Status**: burned by %s at block %d\n", rec.BurnedBy, rec.BurnHeight))
	b.WriteString(ufmt.Sprintf("* **Archive**: [all burned tokens](%s:burned)\n", realmRelPath))
	if len(m.Attributes) > 0 {
		b.WriteString("\n## Traits\n\n")
		for _, attr := range m.Attributes {
			b.WriteString(ufmt.Sprintf("* **%s**: %s\n", attr.TraitType, attr.Value))
		}
	}
	return b.String()
}

// gnotString: ugnot as GNOT, trailing zeros trimmed (100000000 -> "100",
// 1500000 -> "1.5").
func gnotString(ugnot int64) string {
	whole, frac := ugnot/1_000_000, ugnot%1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10)
	}
	f := strconv.FormatInt(frac+1_000_000, 10)[1:]
	return strconv.FormatInt(whole, 10) + "." + strings.TrimRight(f, "0")
}

// bpsPercent: basis points as a percentage (500 -> "5%", 250 -> "2.5%").
// ufmt ignores zero-padding, so "%d.%02d" printed 500 as "5.0%".
func bpsPercent(bps int64) string {
	if bps%100 == 0 {
		return strconv.FormatInt(bps/100, 10) + "%"
	}
	f := strconv.FormatInt(bps%100+100, 10)[1:]
	return strconv.FormatInt(bps/100, 10) + "." + strings.TrimRight(f, "0") + "%"
}

func render404() string {
	return ufmt.Sprintf("# 404\n\n[<- back to collection](%s)\n", realmRelPath)
}

func Render(path string) string {
	if path == "" {
		var b strings.Builder
		b.WriteString(token.RenderHome())
		b.WriteString("\n## About\n\n")
		b.WriteString(CollectionName + " are gemstones captured in an anti-gravity field. Each stone floats, suspended, at the heart of the ring around it -- gold, platinum, silver, bronze or obsidian -- which holds it in place and turns it into a display piece for the collector.\n\n")
		b.WriteString("The collection is inspired by the names of gno.land's chains. Every piece's Chain trait names a gno.land chain generation, and its stone is that chain's own: Topaz, Sapphire and Pearl for the testnets that carry those names, Diamond for mainnet, and Quartz for the testnets without one. Only real cuts and colours; every image is drawn on-chain. Delayed-reveal mint: each piece's traits stay sealed for a few blocks after it is minted.\n\n")
		b.WriteString(ufmt.Sprintf("* **Owner**: %s\n", Owner()))
		b.WriteString(ufmt.Sprintf("* **Assembled trait combinations minted**: %d\n", int64(mintedTraitCombos.Size())))
		b.WriteString("* **Max supply**: unlimited\n")
		if mintingOpenMirror {
			b.WriteString("* **Minting**: open\n")
		} else {
			b.WriteString("* **Minting**: closed\n")
		}
		if mintPriceUgnot > 0 {
			b.WriteString("* **Mint price**: " + gnotString(mintPriceUgnot) + " GNOT\n")
		} else {
			b.WriteString("* **Mint price**: free\n")
		}
		b.WriteString(ufmt.Sprintf("* **Reveal delay**: %d block(s)\n", RevealDelayBlocks))
		if maxMintsPerWalletMirror > 0 {
			b.WriteString(ufmt.Sprintf("* **Max mints per wallet**: %d\n", maxMintsPerWalletMirror))
		} else {
			b.WriteString("* **Max mints per wallet**: unlimited\n")
		}
		if royaltyBps > 0 {
			b.WriteString("* **Secondary sale royalty**: " + bpsPercent(royaltyBps) + " (EIP-2981 RoyaltyInfo)\n")
		}
		if len(burnedIDs) > 0 {
			b.WriteString(ufmt.Sprintf("* **Burned**: %d -- [view burned tokens ->](%s:burned)\n", len(burnedIDs), realmRelPath))
		}

		renderMintedListPage(&b, 1)
		return b.String()
	}

	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "page" {
		page, err := strconv.Atoi(parts[1])
		if err != nil || page < 1 {
			return render404()
		}
		var b strings.Builder
		b.WriteString(ufmt.Sprintf("# %s -- minted tokens\n\n[<- back to collection](%s)\n", CollectionName, realmRelPath))
		renderMintedListPage(&b, page)
		return b.String()
	}
	if parts[0] == "burned" {
		page := 1
		if len(parts) == 3 && parts[1] == "page" {
			p, err := strconv.Atoi(parts[2])
			if err != nil || p < 1 {
				return render404()
			}
			page = p
		} else if len(parts) != 1 {
			return render404()
		}
		var b strings.Builder
		b.WriteString(ufmt.Sprintf("# %s -- burned tokens\n\n[<- back to collection](%s)\n", CollectionName, realmRelPath))
		renderBurnedListPage(&b, page)
		return b.String()
	}
	if len(parts) == 2 && parts[0] == "token" {
		tid := grc721.TokenID(parts[1])
		owner, err := token.OwnerOf(tid)
		if err != nil {
			return renderBurnedTokenPage(tid)
		}
		metadata, _ := currentMetadata(tid)
		var b strings.Builder
		b.WriteString(ufmt.Sprintf("# %s #%s\n\n[<- back to collection](%s)\n\n", CollectionName, tid.String(), realmRelPath))
		image := metadata.Image
		name := metadata.Name
		if name == "" {
			name = "Untitled"
		}
		if image != "" {
			b.WriteString(ufmt.Sprintf("![%s](%s)\n\n", name, bigTokenImage(image)))
		}

		b.WriteString("## Details\n\n")
		b.WriteString(ufmt.Sprintf("* **Collection**: %s\n", CollectionName))
		b.WriteString(ufmt.Sprintf("* **Name**: %s\n", name))
		b.WriteString(ufmt.Sprintf("* **Index**: #%s\n", tid.String()))
		if metadata.Description != "" {
			b.WriteString(ufmt.Sprintf("* **Description**: %s\n", metadata.Description))
		}
		b.WriteString(ufmt.Sprintf("* **Owner**: %s\n", owner))
		b.WriteString(ufmt.Sprintf("* **Revealed**: %t (age %d block(s))\n", IsRevealed(tid), Age(tid)))

		if len(metadata.Attributes) > 0 {
			b.WriteString("\n## Traits\n\n")
			for _, attr := range metadata.Attributes {
				b.WriteString(ufmt.Sprintf("* **%s**: %s\n", attr.TraitType, attr.Value))
			}
		}
		return b.String()
	}

	return render404()
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
