// Package nftminter is a single-collection GRC721 NFT minter realm.
//
// Minting is public — anyone can call MintAssembled, no allowlist, no
// curation. Every mint randomly assembles a small trait selection
// (traitPreset) from on-chain rosters (chainRoster, gems.gno's
// shapeNames/metalNames/stone color palettes) and calls this realm's own
// gems.gno to render the actual image on every read — storage cost is
// dominated by gems.gno's own one-time deployment, not by how many tokens
// exist. There is no owner curation step, no preset pool, and no way for
// anyone — including the collection owner — to choose, influence, or
// later change what a token looks like once minted: no function in this
// realm can rewrite a token's traits, image, or attributes after the
// fact. Metadata is stored fully on-chain per token, following the
// OpenSea metadata standard.
//
// An earlier version of this realm also shipped a second, owner-curated
// mint path (Mint/AddPresetToken, plus a family of owner-only metadata-
// editing functions) for a future collection that might want
// precomputed/hand-authored art instead of on-the-fly assembly. Removed
// entirely, not just left unused — a curated, editable path sitting next
// to the fair-random one invited a reasonable question ("could the owner
// just hand themselves something hand-picked through that?") that no
// amount of the pool being empty could fully answer just by reading the
// deployed bytecode. See git history for that design if a future
// collection wants it back.
//
// Uniqueness + reveal: MintAssembled retries with a fresh random draw on
// the rare collision against an already-minted combination (see
// assembleUniqueTraits) — every piece of chain state is still publicly
// readable, so this alone doesn't stop someone from computing in advance
// what a specific future draw might land on. What actually prevents
// choosing/sniping a specific outcome is the delayed reveal (below): each
// token's real name/image/attributes stay sealed behind a shared
// placeholder for RevealDelayBlocks blocks after its own mint, so nobody
// — including the minter — can see what they got until reveal.
//
// Migration/provenance: every token, however it entered the collection,
// carries an original-chain/original-token-id/original-mint-height record
// (Provenance). AddMigrationSnapshotEntry + ClaimMigrated let the owner
// carry a previous chain's holder list forward onto a new deployment
// (mainnet launch, or one testnet generation replacing another) while
// preserving that provenance rather than starting over.
//
// The realm's public functions deliberately mirror the standard GRC721
// shape (Mint/OwnerOf/TokenURI/SafeTransferFrom/BalanceOf/...) so that
// tooling built against any GRC721 collection — a marketplace, an
// explorer/observer — can interact with this one without special-casing
// it. See gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/grc721 for
// the underlying token implementation.
package g14

import (
	"chain"
	"chain/banker"
	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/avl"
	// grc721v2, aliased to keep every existing grc721.X reference below
	// unchanged -- v1 (unversioned grc721) is already deployed and
	// immutable, so fixing Burn to actually free a token's metadata
	// storage (see grc721v2's own Burn doc comment) required a new
	// package path, not an in-place edit.
	grc721 "gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/grc721v2"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	CollectionName   = "Gems"
	CollectionSymbol = "GEMS"

	// MaxSupply caps total mints (normal + migrated-in); 0 means unlimited.
	// Unlimited per request -- there's no fixed edition size for this
	// collection. Minting is stopped by the owner toggling mintingOpen
	// off (see SetMintingOpen), not by hitting a count.
	MaxSupply = 0

	// RevealDelayBlocks is how long a token's real metadata stays sealed
	// behind sealedImage after its own Mint. Block count, not real time —
	// see revealcollection2's doc comment (same project, same reasoning)
	// for why: real elapsed time doesn't track real user actions in an
	// agentic/multi-tool-call context the way block count does.
	RevealDelayBlocks = 10

	// realmRelPath is this realm's own gnoweb-relative path, baked in as a
	// compile-time constant rather than computed via
	// chain/runtime/unsafe.CurrentRealm() at render time -- confirmed live
	// that stack-walking primitive resolves differently when called nested
	// one level inside a non-crossing Render(path string) string (the
	// exact shape vm/qrender always uses in production) than when called
	// directly: it silently truncates to just the chain domain instead of
	// the full path. Must be updated by hand on every new iteration
	// (g1/g2/g3/...) since gno.land packages can't be redeployed in place.
	realmRelPath = "/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/g14"

	// homeRenderLimit is how many minted tokens each page of the listing
	// shows (see renderMintedListPage) -- the home page is always page 1,
	// with "page/2", "page/3", etc. for the rest. Unlike
	// simplenftminter.gno's generic template (aimed at small one-off
	// collections), Gems has no fixed supply and is meant to run for a
	// long time, so a single uncapped listing would eventually hit
	// gnoweb's own 1 MiB markdown render ceiling and silently fall back
	// to a plain-text dump -- pagination instead of a hard cutoff means
	// every token stays reachable from the listing, not just the most
	// recent ones. Most-recent-first, same as gems-mint.html's own
	// client-side stream.
	//
	// Lowered from 50 to 10 after confirming live (153 minted tokens on
	// /g6) that 50 revealed tokens' worth of on-the-fly SVG regeneration
	// per page blows straight through a read query's gas budget --
	// confirmed via a direct RPC vm/qrender call returning "out of gas"
	// for both the home page and page/1 specifically, even though the
	// underlying data (IsRevealed/Age) was correct. gnoweb then has
	// nothing fresh to serve and falls back to whatever it cached
	// earlier (from before the token count made this expensive), which
	// is what a "stuck on Sealed" listing actually is -- not stale
	// on-chain state, a render that can no longer complete. 10 stays
	// affordable at this collection's real image-generation cost with
	// real headroom, not just barely under the line.
	homeRenderLimit = 10
)

// sealedImage is the shared placeholder every token shows until its own
// reveal delay has passed. Built from a literal SVG rather than a
// hand-encoded base64 blob so it stays readable/editable in source.
//
// Two independently-moving pieces, chosen after comparing several
// candidates live: the ring stays perfectly still except for a slow
// rotation (kf-ring-spin, 12s -- an earlier 4s attempt read as too
// fast). Its dashes use pathLength="40" + stroke-dasharray="1 1" rather
// than a fixed "8 8" -- pathLength rescales the dash pattern onto
// whatever the circle's real geometric length is, so it always divides
// into exactly 20 evenly-spaced dashes with no seam mismatch; "8 8"
// against this circle's true circumference (100*pi =~ 314.16) came out
// to ~19.6 repeats, and the leftover 0.6 of a segment showed up as two
// dashes crowding together where the pattern wrapped. The "?" floats
// (kf-v/kf-h, reused verbatim from gems.gno's own applyMotion durations)
// AND now also rotates/pulses like a revealed gem does (kf-mark-r/
// kf-mark-s, reusing gems.gno's own r/s durations and rotation degrees,
// but with a deliberately bigger scale swing -- 1.0 to 1.35, vs. gems.gno's
// own subtler 1.09 -- so the pulse reads clearly on a single lone glyph
// instead of blending into the rest of a busy revealed-gem composition)
// -- the ring deliberately does NOT share any of the mark's motion. Both
// the ring's stroke and the mark's fill share the exact same kf-hue
// keyframe/duration, so their color cycles stay perfectly synchronized
// even though they're driven by two separate class rules; same starting
// color on both for the same reason.
var sealedImage = "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(
	// width/height on the root svg, not just viewBox -- see gems.gno's
	// renderTokenSVG for why (gnoweb collapses an otherwise-ambiguous-size
	// embedded image down to 2x2px).
	`<svg xmlns="http://www.w3.org/2000/svg" width="170" height="170" viewBox="0 0 170 170">`+
		`<style>`+
		`.gt-v{animation:gt-kf-v 3.4s cubic-bezier(.45,0,.55,1) infinite}`+
		`.gt-h{animation:gt-kf-h 4.66s cubic-bezier(.45,0,.55,1) infinite}`+
		`.gt-mark-r{animation:gt-kf-mark-r 5.81s cubic-bezier(.45,0,.55,1) infinite;transform-box:view-box;transform-origin:85px 78px}`+
		`.gt-mark-s{animation:gt-kf-mark-s 6.56s cubic-bezier(.45,0,.55,1) infinite;transform-box:view-box;transform-origin:85px 78px}`+
		`.gt-ring{animation:gt-kf-ring-spin 12s linear infinite,gt-kf-hue 6s linear infinite;transform-box:view-box;transform-origin:85px 78px}`+
		`.gt-mark-hue{animation:gt-kf-hue 6s linear infinite}`+
		`@keyframes gt-kf-v{0%,100%{transform:translate(0,0)}50%{transform:translate(0,-5px)}}`+
		`@keyframes gt-kf-h{0%,100%{transform:translate(0,0)}50%{transform:translate(1.8px,0)}}`+
		`@keyframes gt-kf-mark-r{0%,100%{transform:rotate(0deg)}25%{transform:rotate(-6deg)}50%{transform:rotate(0deg)}75%{transform:rotate(6deg)}}`+
		`@keyframes gt-kf-mark-s{0%,100%{transform:scale(1)}50%{transform:scale(1.35)}}`+
		`@keyframes gt-kf-ring-spin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}`+
		`@keyframes gt-kf-hue{from{filter:hue-rotate(0deg)}to{filter:hue-rotate(360deg)}}`+
		`</style>`+
		`<rect width="170" height="170" fill="#0a0b10"/>`+
		`<circle class="gt-ring" cx="85" cy="78" r="50" fill="none" stroke="#7fa8e0" stroke-width="4" pathLength="40" stroke-dasharray="1 1"/>`+
		`<g class="gt-v"><g class="gt-h"><g class="gt-mark-r"><g class="gt-mark-s">`+
		`<text class="gt-mark-hue" x="85" y="94" font-size="46" text-anchor="middle" fill="#7fa8e0" font-family="ui-monospace,monospace">?</text>`+
		`</g></g></g></g>`+
		`</svg>`,
))

var (
	// nft holds the collection's token state. Concrete type on purpose
	// (see grc721.IGRC721Reader's doc comment): there is no writer
	// interface, so every mutation must go through one of this realm's
	// own cur-validating wrappers below.
	nft *grc721.MetadataNFT

	// collectionOwner administers the collection (chain/stone/metal
	// rosters, minting-open/price/wallet-cap knobs, migration) — minting
	// itself is public and needs no authorization, and no function this
	// realm exposes lets this address (or anyone) change a token's
	// traits/image/attributes once minted. A dedicated address for this
	// collection specifically (funded and
	// designated 2026-08-12), not necessarily the same key that signs the
	// realm's own deploy transaction — those are two independent things:
	// whoever calls addpkg determines this realm's package path
	// (gno.land/r/<deployer>/nftminter), while collectionOwner is purely
	// an application-level access-control value this file checks itself.
	//
	// Self-owned rather than gno.land/p/nt/ownable/v0 — that package's
	// own API isn't consistent across gno.land networks either (a third
	// instance of the same class of problem as avl.Tree.Get and
	// chain/runtime's PreviousRealm/CurrentRealm split: Beta Mainnet's
	// deployed ownable has a completely different shape — AssertOwned()
	// takes no address argument at all, auth mode baked in at
	// construction time — confirmed from its actual deployed source, not
	// assumed). We only ever used two methods (AssertOwnedBy, Owner) on
	// top of an address we already derive ourselves via callerAddress(),
	// so owning this directly removes a dependency that has already
	// drifted once, rather than adding a third per-network dialect to
	// render-for-address.sh for something this small.
	collectionOwner address = "g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems"

	// mintingOpen is the owner's kill switch on new mints -- checked by
	// MintAssembled (not ClaimMigrated: closing new mints shouldn't block
	// someone completing a rightful migration claim).
	mintingOpen = true

	// mintPriceUgnot is the price MintAssembled charges, checked exactly
	// (not a minimum) -- see the payment check inlined in MintAssembled
	// itself. Starts at 0 (free) until the owner sets a real price via
	// SetMintPrice. Deliberately a plain owner-settable number rather
	// than any on-chain USD-oracle conversion: GNOT/USD is expected to
	// move, and re-pricing is a manual "update it when it matters"
	// decision, not something this contract tries to automate — and
	// since each chain this gets deployed to (testnet vs. eventual
	// mainnet) is a fully separate instance with its own independently-
	// set state, the same mechanism naturally supports a different
	// price per chain without any special-casing here.
	mintPriceUgnot int64 = 0

	// maxMintsPerWallet caps how many MintAssembled tokens a single
	// recipient (the `to` address, not the caller) may hold from this
	// mechanism -- 0 means unlimited. Checked and incremented against
	// `to` specifically because that's who ends up holding the token; a
	// cap on the calling/paying address instead would do nothing to stop
	// one caller directing many mints to many different recipients they
	// still control. Like maxMintsPerWallet's sibling knobs
	// (mintingOpen/mintPriceUgnot), this is a soft, on-chain-only lever:
	// nothing stops someone from spreading mints across many separate
	// wallets, the same way nothing stops a bot willing to pay
	// mintPriceUgnot repeatedly. Owner-adjustable via
	// SetMaxMintsPerWallet, starts at 5 per request.
	maxMintsPerWallet int64 = 5

	// mintCountByWallet tracks MintAssembled mints per recipient address,
	// enforcing maxMintsPerWallet. Never decremented, even if a token is
	// later transferred or burned -- this counts mints a wallet has
	// RECEIVED from this mechanism, not tokens it currently holds.
	mintCountByWallet avl.Tree // address.String() -> int64

	nextID seqid.ID

	// mintedTraitCombos is a PERMANENT record of every exact trait
	// combination (chain+shape+color+metal+active) that has ever actually
	// been minted via MintAssembled -- never removed. Checked (and
	// re-drawn around) by assembleUniqueTraits so no two tokens can ever
	// share identical traits -- the collection has no supply cap, so the
	// only real limit is how many distinct combinations the trait space
	// allows.
	mintedTraitCombos avl.Tree // combo key -> true

	// mintedIDs is every token ID ever minted, in mint order, including
	// burned ones (OwnerOf simply errors for those — callers iterating
	// this list should skip whatever it rejects). Exists purely to make
	// "list the whole collection" / "list what address X owns" possible
	// without needing to reach into grc721's internal owners tree, which
	// isn't exposed for iteration.
	mintedIDs []grc721.TokenID

	// mintHeight and sealedData back the reveal mechanism: mintHeight is
	// when a normal (non-migrated) mint happened, sealedData is that
	// token's real name/image/attributes, kept out of the publicly-set
	// metadata until IsRevealed. A token only gets a sealedData entry if
	// it went through MintAssembled — ClaimMigrated sets final metadata
	// directly (a migrated token is re-establishing something already
	// revealed on its original chain, not a fresh random draw).
	mintHeight avl.Tree // tid.String() -> int64
	sealedData avl.Tree // tid.String() -> traitPreset

	// mintProvenance is set for EVERY token, migrated or not, so the
	// collection has a uniform legitimacy record from the start rather
	// than treating provenance as something bolted on only for migrated
	// pieces.
	mintProvenance avl.Tree // tid.String() -> provenanceInfo

	// migrationSnapshot is the owner-seeded record of who held what on a
	// previous chain, keyed by "<originalChain>/<originalTokenID>". See
	// AddMigrationSnapshotEntry/ClaimMigrated.
	migrationSnapshot     avl.Tree // key -> migrationEntry
	migrationSnapshotSize int64
	migrationClaimedCount int64

	// burnedRecords/burnedIDs are a permanent record of every token this
	// realm has ever burned — Burn deliberately erases the token's own
	// ownership/metadata/provenance (see Burn's own comment on why), so
	// without a separate record kept BEFORE that erasure, there'd be no
	// way to answer "what did this piece look like, and who burned it"
	// afterward. burnedIDs mirrors mintedIDs' own "append-only, oldest
	// first" shape for the same reason: iterating grc721's internal
	// state isn't possible, so this realm keeps its own ordered list.
	burnedRecords avl.Tree // tid.String() -> burnRecord
	burnedIDs     []grc721.TokenID
)

// traitPreset is one not-yet-minted token's small trait selection for the
// assembled-on-read path (see gems.gno, MintAssembled) — holds just
// enough for the shared on-chain generator to reconstruct the full image
// at TokenURI time instead of a whole precomputed image string. Stone
// isn't stored here: it's derived from Chain (see stoneForChain in
// gems.gno), same as the prototype that designed this collection.
type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
}

// burnRecord is a permanent snapshot of one burned token — who burned
// it, at what block, and what it looked like right before burning. It's
// the only place that survives Burn's own erasure of the live
// token/metadata (see Burn) — without it, "which pieces were burned, by
// whom" would be unanswerable after the fact.
//
// HadTuple picks which half is meaningful, matching whatever storage
// shape the token had right before burning: a MintAssembled piece never
// stores its rendered image (see gems.gno — the whole point of that
// path is regenerating it fresh from a small trait tuple on every read),
// so capturing just Tuple here keeps a burn just as cheap as the rest of
// that path's storage story, and burnRecordMetadata regenerates the
// real image/name/attributes from it on demand. A migrated-in token has
// no such tuple to fall back to (its image is already baked into stored
// metadata permanently — see currentMetadata's own doc comment) — for
// those, Metadata is the only option and gets snapshotted as-is.
type burnRecord struct {
	BurnedBy   address
	BurnHeight int64
	HadTuple   bool
	Tuple      traitPreset
	Metadata   grc721.Metadata
}

// provenanceInfo is the "when/where this token's art was first minted"
// record, kept for every token regardless of how it entered the
// collection — a fresh Mint here, or a ClaimMigrated carrying it forward
// from an earlier chain.
type provenanceInfo struct {
	OriginalChain      string
	OriginalTokenID    string
	OriginalMintHeight int64
}

// migrationEntry is one owner-seeded record of a holder's token on a
// previous chain, awaiting that holder's own claim on this one.
//
// Holds a compact traitPreset -- name, description, and image all get
// regenerated on demand at claim time (see
// mintMigratedToken/assembledMetadata), exactly like a live
// MintAssembled mint already does, instead of storing a precomputed
// copy of them here. Confirmed live against the /g5->/g6 migration this
// replaces: that one stored a full rendered image + full metadata per
// entry (~18-19KB/token, real cost paid on-chain); this reuses the same
// on-the-fly rendering path a normal mint already relies on to avoid
// storing its own image, cutting the seeded entry down to a handful of
// small fields.
type migrationEntry struct {
	OriginalOwner      address
	OriginalChain      string
	OriginalTokenID    string
	OriginalMintHeight int64
	Trait              traitPreset
	Claimed            bool
}

func init(cur realm) {
	nft = grc721.NewNFTWithMetadata(0, cur, CollectionName, CollectionSymbol)
}

/* -------------------- Reader (standard GRC721 shape) -------------------- */

func Name() string      { return nft.Name() }
func Symbol() string    { return nft.Symbol() }
func TokenCount() int64 { return nft.TokenCount() }

func BalanceOf(owner address) (int64, error) {
	return nft.BalanceOf(owner)
}

func OwnerOf(tid grc721.TokenID) (address, error) {
	return nft.OwnerOf(tid)
}

// currentMetadata is what every reader-facing function below actually
// returns: nft's own stored metadata for tokens that never had a reveal
// step (migrated-in tokens set their final metadata directly), otherwise
// the sealed placeholder or the real revealed data depending on Age(tid).
func currentMetadata(tid grc721.TokenID) (grc721.Metadata, error) {
	stored, err := nft.TokenMetadata(tid)
	if err != nil {
		return stored, err
	}

	if tp, hadReveal := sealedData.Get(tid.String()).(traitPreset); hadReveal {
		if !IsRevealed(tid) {
			return stored, nil // still sealed
		}
		return assembledMetadata(tid, tp), nil
	}

	// migrated token, or something else that never went through a
	// MintAssembled seal step — the stored metadata already is final.
	return stored, nil
}

// gemDisplayName builds each piece's own Name from its actual traits --
// color, stone (crystal), cut, metal, and chain -- rather than a generic
// "Gem in a Ring #0000005", matching the descriptive "Color Shape" /
// "Metal · Stone" pattern already used for card captions in every
// comparison artifact this collection's art went through. Falls back to
// the generic "Gem" for the crystal-type word when the chain has no
// real gemstone mapping ("Not Set" -- see stoneForChain) -- every name
// still names SOME kind of stone rather than silently skipping that
// word. Ends with "<chain> Chain" (not just the bare chain code) so
// it's clear TEST-8/SAPPHIRE-1/etc name a blockchain, matching the same
// "<CHAIN> CHAIN" convention the label bar baked into the SVG itself
// already uses (just title-cased here to match "Ring"'s own casing).
func gemDisplayName(colorName, stone, shape, metal, chain string) string {
	kind := stone
	if kind == "" || kind == "Not Set" {
		kind = "Gem"
	}
	return colorName + " " + kind + " " + shape + " — " + metal + " Ring · " + chain + " Chain"
}

// assembledMetadata renders tp's full metadata on demand by calling
// gems.gno's generator — only reached once IsRevealed(tid) is true, so
// the sealed placeholder hides it beforehand exactly like the
// precomputed-image path does.
func assembledMetadata(tid grc721.TokenID, tp traitPreset) grc721.Metadata {
	svg, stone, _, colorName := renderTokenSVG(tp.Chain, tp.Metal, tp.ShapeIdx, tp.ColorIdx, tp.Active, tid.String())
	image := "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
	status := "Sunset"
	if tp.Active {
		status = "Active"
	}
	attrs := []grc721.Trait{
		{TraitType: "Chain", Value: tp.Chain + " Chain"},
		{TraitType: "Stone", Value: stone},
		{TraitType: "Shape", Value: shapeNames[tp.ShapeIdx]},
		{TraitType: "Color", Value: colorName},
		{TraitType: "Metal", Value: tp.Metal + " Ring"},
		{TraitType: "Status", Value: status},
	}
	attrs = append(attrs, provenanceAttrs(tid)...)
	return grc721.Metadata{
		Name:            gemDisplayName(colorName, stone, shapeNames[tp.ShapeIdx], tp.Metal, tp.Chain),
		Description:     ufmt.Sprintf("A %s %s set in %s, minted on %s.", colorName, shapeNames[tp.ShapeIdx], tp.Metal, tp.Chain),
		Image:           image,
		BackgroundColor: "0a0b10",
		Attributes:      attrs,
	}
}

// provenanceAttrs turns tid's provenanceInfo into visible traits, appended
// to a token's attributes once its real metadata is showing (revealed
// normal mint, or any migrated-in token, which is never sealed).
func provenanceAttrs(tid grc721.TokenID) []grc721.Trait {
	raw := mintProvenance.Get(tid.String())
	prov, ok := raw.(provenanceInfo)
	if !ok {
		return nil
	}
	return []grc721.Trait{
		{TraitType: "Original Chain", Value: prov.OriginalChain},
		{TraitType: "Original Token ID", Value: prov.OriginalTokenID},
		{TraitType: "Original Mint Height", Value: ufmt.Sprintf("%d", prov.OriginalMintHeight)},
	}
}

func jsonEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// metadataDataURI renders m as a data:application/json;base64,... URI —
// the standard shape a marketplace's TokenURI() call expects. Local copy
// rather than grc721.MetadataNFT.TokenURI() because that one reads
// straight from nft's own stored (possibly sealed) metadata — TokenURI
// below needs currentMetadata's seal/reveal-aware version instead.
func metadataDataURI(m grc721.Metadata) string {
	image := m.Image
	if image == "" {
		image = m.ImageData
	}
	var b strings.Builder
	b.WriteString(`{"name":"`)
	b.WriteString(jsonEscape(m.Name))
	b.WriteString(`","description":"`)
	b.WriteString(jsonEscape(m.Description))
	b.WriteString(`","image":"`)
	b.WriteString(jsonEscape(image))
	b.WriteString(`"`)
	if m.ExternalURL != "" {
		b.WriteString(`,"external_url":"`)
		b.WriteString(jsonEscape(m.ExternalURL))
		b.WriteString(`"`)
	}
	if m.BackgroundColor != "" {
		b.WriteString(`,"background_color":"`)
		b.WriteString(jsonEscape(m.BackgroundColor))
		b.WriteString(`"`)
	}
	b.WriteString(`,"attributes":[`)
	for i, t := range m.Attributes {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"trait_type":"`)
		b.WriteString(jsonEscape(t.TraitType))
		b.WriteString(`","value":"`)
		b.WriteString(jsonEscape(t.Value))
		b.WriteString(`"}`)
	}
	b.WriteString("]}")
	return "data:application/json;base64," + base64.StdEncoding.EncodeToString([]byte(b.String()))
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

func GetApproved(tid grc721.TokenID) (address, error) {
	return nft.GetApproved(tid)
}

func IsApprovedForAll(owner, operator address) bool {
	return nft.IsApprovedForAll(owner, operator)
}

// Getter returns a reader-only view of the collection, safe to register
// with cross-realm aggregators (marketplace, observer) without risking
// a captured cur.
func Getter() grc721.NFTGetter {
	return nft.Getter()
}

/* --------------------------- Reveal mechanics ------------------------------ */

// Age returns real blocks elapsed since tid was minted (MintAssembled
// only — migrated-in tokens have no seal step, hence no meaningful age),
// or -1 if it doesn't exist / was never sealed.
func Age(tid grc721.TokenID) int64 {
	h := mintHeight.Get(tid.String())
	if h == nil {
		return -1
	}
	return runtime.ChainHeight() - h.(int64)
}

// IsRevealed reports whether tid's real metadata is visible yet. Tokens
// that were never sealed (migrated-in) report true — there's nothing left
// to reveal.
func IsRevealed(tid grc721.TokenID) bool {
	if _, isTraitPreset := sealedData.Get(tid.String()).(traitPreset); !isTraitPreset {
		return true
	}
	age := Age(tid)
	return age >= 0 && age >= RevealDelayBlocks
}

// Provenance returns tid's original-chain/original-token-id/original-mint-
// height record — populated for every token, whether it was minted here
// directly or carried forward from a previous chain via ClaimMigrated.
func Provenance(tid grc721.TokenID) (originalChain string, originalTokenID string, originalMintHeight int64, err error) {
	raw := mintProvenance.Get(tid.String())
	prov, ok := raw.(provenanceInfo)
	if !ok {
		return "", "", 0, grc721.ErrInvalidTokenId
	}
	return prov.OriginalChain, prov.OriginalTokenID, prov.OriginalMintHeight, nil
}

/* --------------------------- Trait/wallet summaries ------------------------ */

// traitsToCSV packs a token's traits into one "TraitType=Value;..."
// string for TokenSummary/rawTokenSummary — a []Trait return value
// itself round-trips fine through vm/qeval, but packing it into one
// primitive string keeps every summary line's shape uniform and easy
// for a plain JS client to parse without decoding Gno's own struct
// value syntax.
func traitsToCSV(attrs []grc721.Trait) string {
	pairs := make([]string, len(attrs))
	for i, a := range attrs {
		pairs[i] = a.TraitType + "=" + a.Value
	}
	return strings.Join(pairs, ";")
}

// TokenSummary returns tid, its current owner, and its metadata's
// name/description/image/externalURL/attributes as one line: fields
// separated by "|", each value (other than the plain tokenID/owner)
// base64-encoded. Base64 rather than plain text specifically so a
// description or name containing "|", a newline, or anything else can
// never be mistaken for a field boundary — a plain-text delimited format
// would be one user-supplied "|" away from corrupting whatever parses
// it. Meant for simple off-chain UIs (this project's own web/ console)
// to build a gallery view without decoding Gno's own struct value syntax.
func TokenSummary(tid grc721.TokenID) (string, error) {
	owner, err := nft.OwnerOf(tid)
	if err != nil {
		return "", err
	}
	metadata, err := currentMetadata(tid)
	if err != nil {
		return "", err
	}

	enc := base64.StdEncoding
	fields := []string{
		tid.String(),
		owner.String(),
		enc.EncodeToString([]byte(metadata.Name)),
		enc.EncodeToString([]byte(metadata.Description)),
		enc.EncodeToString([]byte(metadata.Image)),
		enc.EncodeToString([]byte(metadata.ExternalURL)),
		enc.EncodeToString([]byte(traitsToCSV(metadata.Attributes))),
		enc.EncodeToString([]byte(metadata.BackgroundColor)),
	}
	return strings.Join(fields, "|"), nil
}

// CollectionSummary returns one TokenSummary line per currently-existing
// token on the given page (1-indexed, newest first, homeRenderLimit per
// page — same page size as renderMintedListPage, confirmed live to fit
// a single qeval call's gas budget), newline-separated. Used to be
// unbounded (every token in one call) — confirmed live that this starts
// failing with "out of gas in location: CPUCycles" at just 21 minted
// tokens, since TokenSummary regenerates a full SVG per token
// (currentMetadata -> renderTokenSVG). Paginating the same way the
// gnoweb listing already does keeps every call's cost bounded
// regardless of collection size.
func CollectionSummary(page int) string {
	total := len(mintedIDs)
	if page < 1 {
		page = 1
	}
	startK := (page - 1) * homeRenderLimit
	endK := startK + homeRenderLimit
	if endK > total {
		endK = total
	}
	var lines []string
	for k := startK; k < endK; k++ {
		tid := mintedIDs[total-1-k] // k=0 is newest
		line, err := TokenSummary(tid)
		if err != nil {
			continue // burned since minting
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// walletScanChunk bounds how many mintedIDs entries WalletSummary
// checks per call — same "out of gas" risk as CollectionSummary's own
// fix above, but WalletSummary can't just paginate by recency: a
// wallet's tokens can be scattered anywhere across the mint history, so
// the SCAN itself (not just the match count) needs bounding regardless
// of how many of a wallet's tokens happen to turn up in a given window.
const walletScanChunk = 100

// WalletSummary is CollectionSummary filtered to tokens currently owned
// by owner, scanning at most walletScanChunk of mintedIDs starting at
// startIdx (0-based, newest-first ordering — same as CollectionSummary).
// Returns the matching TokenSummary lines found in that window plus
// nextIdx to resume the scan from; nextIdx == TokenCount() once nothing
// is left to check. A caller that wants "all of this wallet's tokens"
// calls repeatedly with nextIdx until it stops advancing — the same
// chunked-calls pattern this collection's migrate/deliver flows already
// use for writes, applied here to a read that can no longer be a single
// unbounded call.
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
	for k := start; k < end; k++ {
		tid := mintedIDs[total-1-k] // newest first, consistent with CollectionSummary
		tokenOwner, err := nft.OwnerOf(tid)
		if err != nil || tokenOwner != owner {
			continue
		}
		line, err := TokenSummary(tid)
		if err != nil {
			continue
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n"), int64(end)
}

// rawMetadata is TokenMetadata's owner-only counterpart: the REAL data
// regardless of reveal state, bypassing the seal entirely. Never exposed
// through the public TokenMetadata/TokenURI path -- only the raw summary
// functions below use it, both owner-gated.
func rawMetadata(tid grc721.TokenID) (grc721.Metadata, error) {
	stored, err := nft.TokenMetadata(tid)
	if err != nil {
		return stored, err
	}

	if tp, hadReveal := sealedData.Get(tid.String()).(traitPreset); hadReveal {
		return assembledMetadata(tid, tp), nil
	}

	return stored, nil // migrated-in token: stored already is the real data
}

func rawTokenSummary(tid grc721.TokenID) (string, error) {
	owner, err := nft.OwnerOf(tid)
	if err != nil {
		return "", err
	}
	metadata, err := rawMetadata(tid)
	if err != nil {
		return "", err
	}
	enc := base64.StdEncoding
	fields := []string{
		tid.String(),
		owner.String(),
		enc.EncodeToString([]byte(metadata.Name)),
		enc.EncodeToString([]byte(metadata.Description)),
		enc.EncodeToString([]byte(metadata.Image)),
		enc.EncodeToString([]byte(metadata.ExternalURL)),
		enc.EncodeToString([]byte(traitsToCSV(metadata.Attributes))),
		enc.EncodeToString([]byte(metadata.BackgroundColor)),
	}
	return strings.Join(fields, "|"), nil
}

// RawCollectionSummary is CollectionSummary's owner-only counterpart,
// same line format and same page-based pagination (see
// CollectionSummary's own comment on why an unbounded version runs out
// of gas), but bypasses the reveal seal entirely so a complete,
// authoritative backup can be taken at any moment — e.g. right after a
// testnet deprecation is announced, without needing to wait out
// individual tokens' remaining reveal delay first. Meant specifically for
// disaster-recovery/migration snapshots (see AddMigrationSnapshotEntry) —
// exposing this to anyone but the owner would defeat the point of
// sealing in the first place, hence `cur realm` + assertOwner rather than
// a plain query function, matching this realm's other owner-gated calls.
func RawCollectionSummary(cur realm, page int) string {
	assertOwner()
	total := len(mintedIDs)
	if page < 1 {
		page = 1
	}
	startK := (page - 1) * homeRenderLimit
	endK := startK + homeRenderLimit
	if endK > total {
		endK = total
	}
	var lines []string
	for k := startK; k < endK; k++ {
		tid := mintedIDs[total-1-k]
		line, err := rawTokenSummary(tid)
		if err != nil {
			continue
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// callerAddress derives the address that crossed into whichever
// exported function called this, for authorization/ownership checks
// (assertOwner, token-transfer caller derivation, etc.).
//
// Uses chain/runtime/unsafe.PreviousRealm() instead of the more
// idiomatic cur.Previous() because cur.Previous() isn't available on
// every gno.land network — confirmed missing on Beta Mainnet's GnoVM
// as of 2026-08 (compile error: "type realm has no field or method
// IsCurrent", which cur.Previous() also depends on). unsafe.PreviousRealm()
// is documented as capable of misidentifying the caller in a "non-
// crossing helper" reachable via multiple different realms' crossing
// paths — that's NOT this function's shape: it's private, called only
// from this realm's own exported entrypoints, each itself the sole
// crossing frame in the chain, so there is exactly one possible
// "immediate caller" per call — no cross-realm ambiguity for the
// stack-walk to get wrong. Verified empirically (not just by this
// argument) against an adversarial "malicious realm caller" scenario
// and a two-hop EOA-through-an-intermediate-realm scenario, both
// through this exact one-hop-of-indirection shape, before relying on
// it here — see conversation history for the test cases if revisiting.
func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

// Owner returns the collection owner's address.
func Owner() address {
	return collectionOwner
}

// MintingOpen reports whether Mint/MintAssembled currently accept new
// mints. Toggled by SetMintingOpen — this collection has no fixed supply
// cap (see MaxSupply), so this is the owner's actual mechanism for
// ending the mint, independent of whether presets remain queued.
func MintingOpen() bool {
	return mintingOpen
}

// SetMintingOpen opens or closes new mints. Owner-only. Does not affect
// ClaimMigrated (see mintingOpen's doc comment) or any token that
// already exists.
func SetMintingOpen(cur realm, open bool) {
	assertOwner()
	mintingOpen = open
}

// MintPrice returns the current price, in ugnot, that MintAssembled
// charges. 0 means free.
func MintPrice() int64 {
	return mintPriceUgnot
}

// SetMintPrice updates the price MintAssembled charges. Owner-only,
// callable at any time — meant to be re-set whenever GNOT/USD moves
// enough to matter, and independently per chain this realm is deployed
// to (testnet vs. eventual mainnet each hold their own state). Does not
// affect any token already minted.
func SetMintPrice(cur realm, ugnot int64) {
	assertOwner()
	if ugnot < 0 {
		panic("price cannot be negative")
	}
	mintPriceUgnot = ugnot
}

// MaxMintsPerWallet returns the current per-recipient cap on
// MintAssembled mints -- 0 means unlimited.
func MaxMintsPerWallet() int64 {
	return maxMintsPerWallet
}

// SetMaxMintsPerWallet updates the per-recipient cap. Owner-only. Does
// not retroactively affect wallets already at or past a lower new cap —
// it only blocks further mints TO them going forward.
func SetMaxMintsPerWallet(cur realm, max int64) {
	assertOwner()
	if max < 0 {
		panic("max must be non-negative (0 = unlimited)")
	}
	maxMintsPerWallet = max
}

// MintsByWallet reports how many MintAssembled tokens owner has ever
// received (see mintCountByWallet's doc comment for why this isn't the
// same as current holdings).
func MintsByWallet(owner address) int64 {
	n, _ := mintCountByWallet.Get(owner.String()).(int64)
	return n
}

// WithdrawFunds sends amount ugnot from this realm's own balance to the
// collection owner. Owner-only. Necessary because MintAssembled's
// payments accumulate in the realm's own account automatically (the
// chain credits it as part of processing the same message, before
// MintAssembled's code even runs) -- nothing forwards them onward
// without an explicit call like this.
func WithdrawFunds(cur realm, amountUgnot int64) {
	assertOwner()
	if amountUgnot <= 0 {
		panic("amount must be positive")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), collectionOwner, chain.Coins{{Denom: "ugnot", Amount: amountUgnot}})
}

// assertOwner panics unless the caller is the collection owner — this
// realm's own equivalent of ownable.Ownable.AssertOwnedBy, see
// collectionOwner's doc comment for why it's not that package.
func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("unauthorized: caller is not the collection owner")
	}
}

/* ------------------------------- Minting ---------------------------------- */

// MintAssembled is the collection's only mint path: no owner-curated pool
// at all — every mint randomly assembles a fresh (chain, shape, color,
// metal, active) combination from the on-chain rosters
// (chainRoster/shapeNames/metalNames, with color drawn from whichever
// palette the chosen chain's stone uses), rejecting and re-drawing on the
// rare collision against a combination that's already been minted (see
// assembleUniqueTraits). No curation step means no control over rarity
// pacing or which combinations exist and when — every valid combination
// in the whole trait space is mintable from the start, and nobody,
// including the collection owner, can choose or later change what a
// specific mint produces. That's deliberate, not an oversight: see the
// package doc comment for the curated-pool alternative this used to sit
// alongside (git history) and why it was removed rather than left dormant.
// Public — no authorization check, no caller-supplied metadata of any
// kind — but DOES require payment if the owner has set one (see
// MintPrice/SetMintPrice and the payment check inlined below): the
// caller's attached "ugnot" send must match the current price exactly, or
// the whole call reverts (including the attempted payment — a panic here
// rolls back the entire message, confirmed against this project's actual
// SDK message-processing code, not assumed).
func MintAssembled(cur realm, to address) grc721.TokenID {
	if !mintingOpen {
		panic("minting is closed")
	}
	if MaxSupply > 0 && nft.TokenCount() >= MaxSupply {
		panic("max supply reached")
	}
	if maxMintsPerWallet > 0 && MintsByWallet(to) >= maxMintsPerWallet {
		panic(ufmt.Sprintf("wallet %s has already reached the %d-mint limit for this collection", to.String(), maxMintsPerWallet))
	}

	// Payment check is INLINED here rather than factored into a helper
	// function -- deliberately, not an oversight. AssertOriginCall
	// counts real call frames between the origin MsgCall and itself,
	// and a separate helper function (tried first, called
	// requireExactPayment) added exactly one hop too many, making
	// AssertOriginCall reject even a genuine direct call to
	// MintAssembled -- confirmed empirically against this gno version,
	// not assumed. Keep this block in MintAssembled's own body if it's
	// ever touched again.
	//
	// Skipped entirely when free (mintPriceUgnot == 0): nothing to
	// verify, and skipping means a free mint never needs to satisfy
	// AssertOriginCall/IsUserCall at all -- only a PAID mint does.
	if mintPriceUgnot != 0 {
		// Two guards beyond just reading the sent amount, both because
		// unsaferealm.OriginSend's own doc comment requires them for
		// safe payment verification: AssertOriginCall (this must be the
		// direct, top-level call -- a malicious intermediate realm
		// could otherwise consume the payment envelope before this
		// check runs) and PreviousRealm().IsUserCall() (a genuine
		// signed user call, not an ephemeral maketx-run realm that
		// could pre-consume the envelope the same way). Skipping either
		// turns this into a TOCTOU/phishing hole, not just a style
		// choice.
		runtime.AssertOriginCall()
		if !unsaferealm.PreviousRealm().IsUserCall() {
			panic("payment verification requires a direct user call")
		}
		got := unsaferealm.OriginSend().AmountOf("ugnot")
		if got != mintPriceUgnot {
			// Exact match required, not a minimum -- an overpayer gets
			// the whole call rejected rather than having the
			// difference silently kept; they can retry with the exact
			// amount. See WithdrawFunds's doc comment for confirmation
			// that a rejected call can never strand a sent payment: a
			// panic here rolls back the ENTIRE message, attached coins
			// included.
			panic(ufmt.Sprintf("payment required: exactly %d ugnot, got %d", mintPriceUgnot, got))
		}
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
	mintProvenance.Set(tid.String(), provenanceInfo{
		OriginalChain:      runtime.ChainID(),
		OriginalTokenID:    tid.String(),
		OriginalMintHeight: height,
	})
	mintCountByWallet.Set(to.String(), MintsByWallet(to)+1)

	nextID.Next()
	mintedIDs = append(mintedIDs, tid)

	return tid
}

// traitComboKey canonically encodes one trait combination for the
// mintedTraitCombos uniqueness check. Field order matches traitPreset's
// own declaration order.
func traitComboKey(chainName string, shapeIdx, colorIdx int, metal string, active bool) string {
	return ufmt.Sprintf("%s|%d|%d|%s|%t", chainName, shapeIdx, colorIdx, metal, active)
}

// activeProbability is the flat chance a freshly-assembled combination
// gets Active=true. Flat rather than per-chain: the old curated-pool
// design could weight this per preset at the owner's discretion (see git
// history), but on-the-fly assembly has no per-combination curation step
// to hang that on, so this is a single collection-wide constant instead.
const activeProbability = 0.2

// randomTraitPreset draws one candidate combination from the on-chain
// rosters (chainRoster/shapeNames/metalNames, color from whichever
// palette the drawn chain's stone uses) — not yet checked against
// mintedTraitCombos; see assembleUniqueTraits, its only caller. attempt
// must differ across retries of the same mint (assembleUniqueTraits
// passes its loop counter) so a collision doesn't just redraw the exact
// same combination forever.
func randomTraitPreset(attempt int) traitPreset {
	material := ufmt.Sprintf("assemble:%d:%d:%s:%d",
		runtime.ChainHeight(), uint64(nextID), callerAddress().String(), attempt)
	rnd := newPRNG(material)

	chainName := chainRoster[rnd.intn(len(chainRoster))]
	stone := stoneForChain(chainName)
	colorIdx := rnd.intn(colorPaletteSize(stone))
	shapeIdx := rnd.intn(len(shapeNames))
	metal := metalNames[rnd.intn(len(metalNames))]
	active := rnd.floatIn(0, 1) < activeProbability

	return traitPreset{
		Chain:    chainName,
		ShapeIdx: shapeIdx,
		ColorIdx: colorIdx,
		Metal:    metal,
		Active:   active,
	}
}

// maxAssembleAttempts bounds how many times MintAssembled will re-draw a
// candidate combination before giving up. A collision is vanishingly
// unlikely except very close to the trait space's own limit (see
// ChainRosterSize/gems.gno's shape/color/metal counts for the current
// total) — this exists so that endgame case fails with a clear message
// instead of an unbounded/expensive loop.
const maxAssembleAttempts = 200

// assembleUniqueTraits repeatedly calls randomTraitPreset until it finds
// a combination not already in mintedTraitCombos, or gives up after
// maxAssembleAttempts. This is MintAssembled's entire selection
// mechanism now — no owner-curated pool, every valid combination in the
// trait space is available to any mint from the start (see MintAssembled's
// own doc comment for the trade-off this implies).
func assembleUniqueTraits() (traitPreset, string) {
	for attempt := 0; attempt < maxAssembleAttempts; attempt++ {
		tp := randomTraitPreset(attempt)
		key := traitComboKey(tp.Chain, tp.ShapeIdx, tp.ColorIdx, tp.Metal, tp.Active)
		if !mintedTraitCombos.Has(key) {
			return tp, key
		}
	}
	panic("could not find an unused trait combination after many attempts — the collection may be fully minted")
}

// IsTraitComboAvailable reports whether the given exact trait
// combination has already been minted. Mostly useful for tooling that
// wants to display/verify a specific combination's status; MintAssembled
// itself never calls this — it just retries on collision (see
// assembleUniqueTraits).
func IsTraitComboAvailable(chainName string, shapeIdx, colorIdx int, metal string, active bool) bool {
	key := traitComboKey(chainName, shapeIdx, colorIdx, metal, active)
	return !mintedTraitCombos.Has(key)
}

// MaxUniqueTraitCombos reports the total size of the assembled-on-read
// trait space right now — every (chain, stone, color) triple the current
// chainRoster/stone assignments allow, times every shape times every
// metal times the two active states. This is the collection's real
// ceiling (there's no fixed MaxSupply): once mintedTraitCombos reaches
// this count, MintAssembled has nothing left to draw. Grows automatically
// whenever AddChain/AddStoneColor extend the rosters it reads from.
func MaxUniqueTraitCombos() int64 {
	var colorTriples int64
	for _, chainName := range chainRoster {
		colorTriples += int64(colorPaletteSize(stoneForChain(chainName)))
	}
	return colorTriples * int64(len(shapeNames)) * int64(len(metalNames)) * 2
}

/* ----------------------------- Chain roster ---------------------------- */
// chainRoster is the set of chains MintAssembled may randomly assign a new
// token to -- mutable on-chain state, not hardcoded source, so a NEW
// gno.land testnet generation can be added without a contract redeploy,
// the same reasoning gems.gno's stone/color tables already use below.
// Seeded with every real gno.land testnet generation to date (Test-1
// through Sapphire-1) plus Betanet/mainnet — see
// docs/nft-collection-writeup.md §8 for the sourcing. Order matters for
// AddChain's dedup check but not for randomness (MintAssembled picks a
// uniformly-random index into this slice, not a weighted/positional one).
var chainRoster = []string{
	"TEST-1", "TEST-2", "TEST-3", "TEST-4", "TEST-5", "TEST-6", "TEST-7",
	"TEST-8", "TEST-9", "TEST-10", "TEST-11", "TEST-12", "TEST-13",
	"TOPAZ-1", "SAPPHIRE-1", "BETANET",
}

// AddChain appends a new chain to the roster MintAssembled draws from.
// Owner-only. Does not itself assign a stone/color palette — pair with
// SetStoneForChain + AddStoneColor if the new chain should get its own
// exclusive colors; otherwise it defaults to the shared "Not Set" palette
// like every other chain without an assignment.
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

// ChainRosterSize reports how many chains MintAssembled currently draws
// from.
func ChainRosterSize() int64 { return int64(len(chainRoster)) }

// ChainRosterCSV lists every chain currently in the roster,
// semicolon-separated, in roster order — lets tooling/frontends introspect
// what's currently known instead of hardcoding it.
func ChainRosterCSV() string { return strings.Join(chainRoster, ";") }

/* ------------------------- Stone/color extensibility ------------------------ */
// gems.gno's stone-by-chain map and color palettes are mutable state, not
// hardcoded source, specifically so a FUTURE gno.land testnet generation
// that gets a real gem codename can be recognized without a contract
// redeploy. These are the owner-only functions that edit that state, and
// the public read accessors so tooling/frontends can introspect it
// instead of hardcoding what's currently known.

// SetStoneForChain assigns (or reassigns) which stone a chain maps to.
// Owner-only. A chain's stone (and therefore its color palette) is
// resolved fresh by MintAssembled on every mint, so changing this mapping
// takes effect on the very next mint for that chain — it does not affect
// any token already minted.
func SetStoneForChain(cur realm, chainName, stone string) {
	assertOwner()
	if stone == "" {
		panic("stone must not be empty")
	}
	stoneByChain[chainName] = stone
	registerStoneName(stone)
}

// AddStoneColor appends one exclusive color to a stone's palette —
// bootstraps a brand-new stone (its first color) or extends an existing
// one. Owner-only. Always appends, never overwrites or reorders: a
// colorIdx already used by a queued or minted preset keeps meaning the
// same color for its whole lifetime.
func AddStoneColor(cur realm, stone, hex, name string) {
	assertOwner()
	if stone == "" || hex == "" || name == "" {
		panic("stone, hex, and name must not be empty")
	}
	stonePalettes[stone] = append(stonePalettes[stone], namedColor{hex: hex, name: name})
	registerStoneName(stone)
}

// MetalToneHex reports metalName's current hi/lo gradient tones as
// "hi;lo", or "" if metalName isn't recognized. Public read accessor so
// tooling/frontends can introspect the current values instead of
// hardcoding them.
func MetalToneHex(metalName string) string {
	t, ok := metals[metalName]
	if !ok {
		return ""
	}
	return t.hi + ";" + t.lo
}

// StoneForChain reports what stone (if any) chainName currently maps to
// — "Not Set" if none. Public read accessor for gems.gno's stoneForChain.
func StoneForChain(chainName string) string {
	return stoneForChain(chainName)
}

// ColorPaletteSize reports how many colors are currently valid for
// stone — the range of colorIdx values AddTraitPreset will accept for
// it. Public read accessor for gems.gno's colorPaletteSize.
func ColorPaletteSize(stone string) int64 {
	return int64(colorPaletteSize(stone))
}

// StoneNames lists every stone name currently registered (has a chain
// mapped to it, a color in its palette, or both), semicolon-separated,
// in the order each was first introduced.
func StoneNames() string {
	return strings.Join(stoneNames, ";")
}

// ColorPaletteCSV lists stone's full color palette as
// "hex:name;hex:name;...", in colorIdx order — lets tooling build a
// picker for AddTraitPreset's colorIdx argument without hardcoding
// what colors currently exist.
func ColorPaletteCSV(stone string) string {
	palette := stonePalettes[stone]
	pairs := make([]string, len(palette))
	for i, c := range palette {
		pairs[i] = c.hex + ":" + c.name
	}
	return strings.Join(pairs, ";")
}

/* ----------------------------- Chain migration ----------------------------- */

// AddMigrationSnapshotEntry seeds one holder's record from a previous
// chain deployment of this collection, so they can later self-serve claim
// an equivalent token here via ClaimMigrated. Owner-only: verifying "this
// address really held this exact token on the old chain" isn't something
// this contract can check trustlessly (gno.land chains don't share state
// or expose light-client proofs to each other) — the owner is expected to
// read the old chain's real holder list off-chain (e.g. via
// CollectionSummary/WalletSummary there) and re-enter it here faithfully.
// The claim step itself (see ClaimMigrated) is still real self-service:
// the owner seeding an entry does not mint anything or move funds by
// itself, and only the matching originalOwner address can turn it into an
// actual token.
//
// originalMintHeight is that token's ORIGINAL mint height on the chain it
// came from (see Provenance) — not this call's height.
//
// traitChain/metal/shapeIdx/colorIdx/active are this token's small
// trait tuple (see traitPreset) -- NOT the same thing as originalChain
// above: traitChain is the gem's own thematic "Chain" trait (e.g.
// "TEST-3"), a fictional testnet-generation name baked into the piece
// itself, while originalChain is the real blockchain the previous
// deployment lived on (e.g. "sapphire-1"). A source realm never exposes
// the raw shapeIdx/colorIdx directly (only the rendered trait strings,
// via CollectionSummary) -- reverse-map those back with this realm's
// own FindShapeIndex/FindColorIndex (gems.gno) before calling this.
// Panics if shapeIdx/colorIdx/metal don't check out against this
// realm's own current tables, rather than silently storing something
// that would render wrong (or panic) later at claim time.
func AddMigrationSnapshotEntry(
	cur realm,
	originalOwner address,
	originalChain, originalTokenID string,
	originalMintHeight int64,
	traitChain, metal string,
	shapeIdx, colorIdx int,
	active bool,
) {
	assertOwner()
	if shapeIdx < 0 || shapeIdx >= len(shapeNames) {
		panic("shapeIdx out of range")
	}
	validMetal := false
	for _, m := range metalNames {
		if m == metal {
			validMetal = true
			break
		}
	}
	if !validMetal {
		panic("unrecognized metal name")
	}
	if colorIdx < 0 || colorIdx >= colorPaletteSize(stoneForChain(traitChain)) {
		panic("colorIdx out of range for this chain's stone")
	}

	key := originalChain + "/" + originalTokenID
	if _, exists := migrationSnapshot.Get(key).(migrationEntry); !exists {
		migrationSnapshotSize++
	}
	migrationSnapshot.Set(key, migrationEntry{
		OriginalOwner:      originalOwner,
		OriginalChain:      originalChain,
		OriginalTokenID:    originalTokenID,
		OriginalMintHeight: originalMintHeight,
		Trait: traitPreset{
			Chain:    traitChain,
			ShapeIdx: shapeIdx,
			ColorIdx: colorIdx,
			Metal:    metal,
			Active:   active,
		},
	})
}

// lookupUnclaimedMigrationEntry fetches and validates a migration entry
// shared by ClaimMigrated and AdminDeliverMigrated -- panics if there's
// no matching entry or it's already been claimed, so neither caller
// needs to duplicate that check.
func lookupUnclaimedMigrationEntry(originalChain, originalTokenID string) migrationEntry {
	key := originalChain + "/" + originalTokenID
	raw := migrationSnapshot.Get(key)
	entry, ok := raw.(migrationEntry)
	if !ok {
		panic("no migration record for that original chain/token")
	}
	if entry.Claimed {
		panic("already claimed")
	}
	return entry
}

// mintMigratedToken does the actual minting for an already-fetched,
// not-yet-claimed migration entry -- shared by ClaimMigrated (self-
// serve, recipient == caller) and AdminDeliverMigrated (owner-paid,
// recipient == the recorded original owner, no signature needed from
// them). Callers are responsible for their own authorization check
// before calling this.
//
// Unlike Mint/MintAssembled, the result is never sealed: a migrated
// token is re-establishing something already revealed on its original
// chain, not a fresh random draw, so hiding it here would serve no
// purpose. Name/description/image are regenerated fresh from the
// entry's compact trait tuple (see assembledMetadata), exactly like a
// live MintAssembled mint -- nothing precomputed is stored for this.
func mintMigratedToken(originalChain, originalTokenID string, entry migrationEntry, recipient address) grc721.TokenID {
	if MaxSupply > 0 && nft.TokenCount() >= MaxSupply {
		panic("max supply reached")
	}

	tid := grc721.TokenID(nextID.String())
	metadata := assembledMetadata(tid, entry.Trait)
	// assembledMetadata's own provenanceAttrs(tid) call finds nothing yet
	// (mintProvenance isn't set for this tid until just below), so its
	// base Chain/Stone/Shape/Color/Metal/Status traits come through
	// clean -- these three are appended on top, same labels ClaimMigrated
	// has always used to keep a migrated piece visibly distinct from a
	// token minted fresh on this realm.
	metadata.Attributes = append(metadata.Attributes,
		grc721.Trait{TraitType: "Migrated From", Value: entry.OriginalChain},
		grc721.Trait{TraitType: "Original Token ID", Value: entry.OriginalTokenID},
		grc721.Trait{TraitType: "Original Mint Height", Value: ufmt.Sprintf("%d", entry.OriginalMintHeight)},
	)
	checkErr(nft.Mint(recipient, tid))
	checkErr(nft.SetTokenMetadata(recipient, tid, metadata))

	mintProvenance.Set(tid.String(), provenanceInfo{
		OriginalChain:      entry.OriginalChain,
		OriginalTokenID:    entry.OriginalTokenID,
		OriginalMintHeight: entry.OriginalMintHeight,
	})

	nextID.Next()
	mintedIDs = append(mintedIDs, tid)

	key := originalChain + "/" + originalTokenID
	entry.Claimed = true
	migrationSnapshot.Set(key, entry)
	migrationClaimedCount++

	return tid
}

// ClaimMigrated mints a fresh token here carrying forward a previous
// chain's token, for whoever's address matches the seeded
// AddMigrationSnapshotEntry record — public, no owner involvement beyond
// having seeded the entry. Panics if there's no matching entry, it's
// already been claimed, or the caller isn't the recorded original owner.
func ClaimMigrated(cur realm, originalChain, originalTokenID string) grc721.TokenID {
	entry := lookupUnclaimedMigrationEntry(originalChain, originalTokenID)
	caller := callerAddress()
	if caller != entry.OriginalOwner {
		panic("caller did not hold this token on the original chain")
	}
	return mintMigratedToken(originalChain, originalTokenID, entry, caller)
}

// AdminDeliverMigrated lets the collection owner deliver an already-
// seeded migration entry directly to its recorded original holder,
// without that holder needing to sign or pay for anything themselves —
// the owner pays once for delivery instead of asking every holder to
// claim (and pay) individually. Same result as ClaimMigrated: same
// provenance, same recipient, same "Migrated From" traits — just
// owner-initiated. One call per token; batch many into a single
// multi-message transaction client-side, the same pattern this realm
// already uses for AddMigrationSnapshotEntry and MintAssembled.
func AdminDeliverMigrated(cur realm, originalChain, originalTokenID string) grc721.TokenID {
	assertOwner()
	entry := lookupUnclaimedMigrationEntry(originalChain, originalTokenID)
	return mintMigratedToken(originalChain, originalTokenID, entry, entry.OriginalOwner)
}

// IsMigrationClaimed reports whether the given original chain/token
// combination has already been claimed here.
func IsMigrationClaimed(originalChain, originalTokenID string) bool {
	raw := migrationSnapshot.Get(originalChain + "/" + originalTokenID)
	entry, ok := raw.(migrationEntry)
	return ok && entry.Claimed
}

// MigrationSnapshotSize and MigrationClaimedCount report how many
// migration records have been seeded in total, and how many of those
// have been claimed so far.
func MigrationSnapshotSize() int64 { return migrationSnapshotSize }
func MigrationClaimedCount() int64 { return migrationClaimedCount }

/* -------------------------- Token-owner actions --------------------------- */

func Approve(cur realm, to address, tid grc721.TokenID) {
	caller := callerAddress()
	checkErr(nft.Approve(caller, to, tid))
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	caller := callerAddress()
	checkErr(nft.SetApprovalForAll(caller, operator, approved))
}

func TransferFrom(cur realm, from, to address, tid grc721.TokenID) {
	caller := callerAddress()
	checkErr(nft.TransferFrom(caller, from, to, tid))
}

func SafeTransferFrom(cur realm, from, to address, tid grc721.TokenID) {
	caller := callerAddress()
	checkErr(nft.SafeTransferFrom(caller, from, to, tid))
}

// tokenOwnerAsCaller looks up tid's current owner so it can be passed as
// the "caller" grc721's metadata methods expect — they only check
// caller == token-owner, with no separate notion of "collection owner".
// SetTokenURI (the only remaining metadata-adjacent function that still
// needs it) asserts collection ownership itself first, then uses this to
// satisfy that inner check.
func tokenOwnerAsCaller(tid grc721.TokenID) address {
	owner, err := nft.OwnerOf(tid)
	checkErr(err)
	return owner
}

// SetTokenURI sets an (optional) off-chain pointer alongside the
// on-chain metadata. Owner-only (see tokenOwnerAsCaller). The one
// remaining owner-editable per-token field — not a trait, just a
// supplementary external link separate from Attributes/Image/Name.
func SetTokenURI(cur realm, tid grc721.TokenID, uri string) {
	assertOwner()
	_, err := nft.SetTokenURI(tokenOwnerAsCaller(tid), tid, grc721.TokenURI(uri))
	checkErr(err)
}

// Burn destroys a token. Caller must be its current owner.
// Burn destroys a token. Caller must be its current owner. nft.Burn
// itself now frees the token's real metadata storage too (see
// grc721v2's own Burn doc comment) -- but sealedData/mintProvenance/
// mintHeight are this realm's OWN per-token state, outside grc721
// entirely, so they need their own cleanup here. mintedTraitCombos is
// deliberately NOT touched -- it's a permanent record so a burned
// token's exact trait combination can never be re-minted (see its own
// doc comment); freeing it on burn would be a uniqueness regression,
// not a storage-cost fix.
func Burn(cur realm, tid grc721.TokenID) {
	caller := callerAddress()
	owner, err := nft.OwnerOf(tid)
	checkErr(err)
	if caller != owner {
		panic(grc721.ErrCallerIsNotOwner)
	}

	key := tid.String()
	rec := burnRecord{BurnedBy: caller, BurnHeight: runtime.ChainHeight()}
	switch sealed := sealedData.Get(key).(type) {
	case traitPreset:
		// MintAssembled path -- capture just the tuple, regenerated on
		// demand later (see burnRecordMetadata), same as a live token of
		// this kind never stores its own image either. Works whether or
		// not it was revealed yet: burning removes any reason left to
		// keep hiding it.
		rec.HadTuple = true
		rec.Tuple = sealed
	default:
		// Migrated-in, or anything else with no sealedData entry at all
		// — its stored metadata (image included) is already final.
		rec.Metadata, _ = currentMetadata(tid)
	}

	checkErr(nft.Burn(tid))
	sealedData.Remove(key)
	mintProvenance.Remove(key)
	mintHeight.Remove(key)

	burnedRecords.Set(key, rec)
	burnedIDs = append(burnedIDs, tid)
}

// burnRecordMetadata reconstructs a burned token's display metadata —
// regenerated fresh from its trait tuple for the common (MintAssembled)
// case, or the snapshot taken at burn time otherwise. See burnRecord's
// own doc comment for why there are two cases.
func burnRecordMetadata(tid grc721.TokenID, rec burnRecord) grc721.Metadata {
	if rec.HadTuple {
		return assembledMetadata(tid, rec.Tuple)
	}
	return rec.Metadata
}

// TotalBurned reports how many tokens this realm has ever burned.
func TotalBurned() int64 { return int64(len(burnedIDs)) }

/* --------------------------------- Render --------------------------------- */

// tokenPageImageSize is how big a token's own image renders on its
// dedicated gnoweb page -- noticeably bigger than the compact size used
// everywhere else (home-page thumbnails, wallets, marketplaces), while
// still leaving room on typical page widths for the traits table below
// it. Both this project's real art (gems.gno) and the sealed placeholder
// are natively 170x170, so one display size covers both.
const tokenPageImageSize = "420"

// bigTokenImage scales up image's declared width/height for display on
// its own token page. The viewBox -- and therefore every internal
// coordinate, radius, and animation transform-origin -- is left
// untouched, so the browser just renders the exact same piece bigger;
// nothing is re-rendered or recalculated. Falls back to the original
// image unchanged if it isn't in the expected shape (defensive -- not
// expected to actually happen for anything this realm itself produces).
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
	// gems.gno's real art writes float-formatted dims (fnum(170.0) ==
	// "170.00"); the sealed placeholder just above writes plain "170".
	// Both are 170x170 native, so exactly one of these two substrings is
	// always present.
	resized := strings.Replace(svg, `width="170.00" height="170.00"`, `width="`+tokenPageImageSize+`" height="`+tokenPageImageSize+`"`, 1)
	if resized == svg {
		resized = strings.Replace(svg, `width="170" height="170"`, `width="`+tokenPageImageSize+`" height="`+tokenPageImageSize+`"`, 1)
	}
	return prefix + base64.StdEncoding.EncodeToString([]byte(resized))
}

// renderMintedListPage writes page `page` (1-indexed, newest-first,
// homeRenderLimit tokens per page) of the minted-token listing, with
// prev/next links when there's more than one page. Shared by the home
// page (always page 1) and the dedicated "page/N" path, so the two never
// drift into different pagination math.
func renderMintedListPage(b *strings.Builder, page int) {
	total := len(mintedIDs)
	if total == 0 {
		return
	}
	totalPages := (total + homeRenderLimit - 1) / homeRenderLimit
	if page < 1 {
		page = 1
	}
	if page > totalPages {
		page = totalPages
	}
	startK := (page - 1) * homeRenderLimit
	endK := startK + homeRenderLimit
	if endK > total {
		endK = total
	}

	b.WriteString("\n## Minted so far\n\n")
	if totalPages > 1 {
		b.WriteString(ufmt.Sprintf("_page %d of %d — %d minted total_\n\n", page, totalPages, total))
	}
	// Table gallery -- chosen over the earlier image+bullet layout after
	// comparing both live (see the token-page "Layout comparison"
	// section for the same comparison at the single-token scale). A
	// table row is self-contained, so unlike the old bullet format this
	// has no lazy-continuation risk between entries (see git history for
	// that earlier bug) -- no blank-line-per-line workaround needed.
	b.WriteString("| Image | Index | Name | Owner |\n|---|---|---|---|\n")
	for k := startK; k < endK; k++ {
		tid := mintedIDs[total-1-k] // k=0 is newest
		owner, err := nft.OwnerOf(tid)
		if err != nil {
			continue // burned
		}
		metadata, _ := currentMetadata(tid)
		name := metadata.Name
		if name == "" {
			name = "Untitled"
		}
		link := realmRelPath + ":token/" + tid.String()
		image := metadata.Image
		if image == "" {
			image = metadata.ImageData
		}
		imgCell := ""
		if image != "" {
			imgCell = ufmt.Sprintf("[![%s](%s)](%s)", name, image, link)
		}
		b.WriteString(ufmt.Sprintf("| %s | [#%s](%s) | %s | %s |\n", imgCell, tid.String(), link, name, owner))
	}
	b.WriteString("\n")

	renderPageLinks(b, page, totalPages, "page")
}

// pageWindow is how many numbered pages to show on each side of the
// current one -- e.g. page 6 of 20 shows 4 5 [6] 7 8, with "…" filling
// the gaps out to First/1 and Last/totalPages so the link list stays a
// fixed, small width regardless of how many pages the collection grows
// to, while still reaching every page in at most two clicks (jump near
// it, then step).
const pageWindow = 2

// renderPageLinks writes First/newer/numbered-pages/older/Last links.
// Shared by renderMintedListPage and renderBurnedListPage -- linkBase is
// what changes between them ("page" vs "burned/page"), a no-op when
// there's only one page.
func renderPageLinks(b *strings.Builder, page, totalPages int, linkBase string) {
	if totalPages <= 1 {
		return
	}
	b.WriteString("\n")
	parts := []string{}
	if page > 1 {
		parts = append(parts, ufmt.Sprintf("[« First](%s:%s/1)", realmRelPath, linkBase))
		parts = append(parts, ufmt.Sprintf("[← newer](%s:%s/%d)", realmRelPath, linkBase, page-1))
	}
	lastShown := 0
	for p := 1; p <= totalPages; p++ {
		if p != 1 && p != totalPages && (p < page-pageWindow || p > page+pageWindow) {
			continue
		}
		if lastShown != 0 && p != lastShown+1 {
			parts = append(parts, "…")
		}
		if p == page {
			parts = append(parts, ufmt.Sprintf("**%d**", p))
		} else {
			parts = append(parts, ufmt.Sprintf("[%d](%s:%s/%d)", p, realmRelPath, linkBase, p))
		}
		lastShown = p
	}
	if page < totalPages {
		parts = append(parts, ufmt.Sprintf("[older →](%s:%s/%d)", realmRelPath, linkBase, page+1))
		parts = append(parts, ufmt.Sprintf("[Last »](%s:%s/%d)", realmRelPath, linkBase, totalPages))
	}
	b.WriteString(strings.Join(parts, " · "))
	b.WriteString("\n")
}

// renderBurnedListPage writes page `page` (1-indexed, most-recently-
// burned first, homeRenderLimit records per page) of the burned-token
// listing -- the only place a burned token's appearance, burner, and
// block survive, since Burn itself erases the live token entirely (see
// Burn's own comment on why). Same table shape as
// renderMintedListPage's, with Owner swapped for Burned By/Block and no
// links back to a token page, since burned tokens don't have one
// anymore.
func renderBurnedListPage(b *strings.Builder, page int) {
	total := len(burnedIDs)
	if total == 0 {
		return
	}
	totalPages := (total + homeRenderLimit - 1) / homeRenderLimit
	if page < 1 {
		page = 1
	}
	if page > totalPages {
		page = totalPages
	}
	startK := (page - 1) * homeRenderLimit
	endK := startK + homeRenderLimit
	if endK > total {
		endK = total
	}

	b.WriteString("\n## Burned tokens\n\n")
	if totalPages > 1 {
		b.WriteString(ufmt.Sprintf("_page %d of %d — %d burned total_\n\n", page, totalPages, total))
	}
	b.WriteString("| Image | Index | Name | Burned By | Block |\n|---|---|---|---|---|\n")
	for k := startK; k < endK; k++ {
		tid := burnedIDs[total-1-k] // k=0 is most recently burned
		raw := burnedRecords.Get(tid.String())
		rec, ok := raw.(burnRecord)
		if !ok {
			continue
		}
		metadata := burnRecordMetadata(tid, rec)
		name := metadata.Name
		if name == "" {
			name = "Untitled"
		}
		image := metadata.Image
		if image == "" {
			image = metadata.ImageData
		}
		imgCell := ""
		if image != "" {
			imgCell = ufmt.Sprintf("![%s](%s)", name, image)
		}
		b.WriteString(ufmt.Sprintf("| %s | #%s | %s | %s | %d |\n", imgCell, tid.String(), name, rec.BurnedBy, rec.BurnHeight))
	}
	b.WriteString("\n")

	renderPageLinks(b, page, totalPages, "burned/page")
}

// render404 is Render's single not-found response -- a big heading (so
// it reads clearly even embedded in gnoweb's markdown, not just as a
// plain "404") plus the same back-link phrasing used everywhere else in
// this realm's pages, for consistency.
func render404() string {
	return ufmt.Sprintf("# 404\n\n[← back to collection](%s)\n", realmRelPath)
}

func Render(path string) string {
	if path == "" {
		var b strings.Builder
		b.WriteString(nft.RenderHome())
		b.WriteString("\n## About\n\n")
		b.WriteString("Each Gem's Chain trait names a real gno.land testnet — one of the generations that carried the network forward on its way to Mainnet. Set in a ring with its own small antigravity field, every piece is a keepsake for everyone who helped build, test, and grow gno.land into what it's becoming.\n\n")
		b.WriteString("This collection is also a demonstration: every gem is generative art, assembled fresh on each read and stored entirely on-chain — no external links, nothing that can go missing. It lives on the gno.land blockchain immutably, for good. When a testnet Gem's chain eventually gives way to Mainnet, migration carries the piece forward while preserving its original provenance — when and where it was first minted.\n\n")
		b.WriteString(ufmt.Sprintf("* **Owner**: %s\n", Owner()))
		b.WriteString(ufmt.Sprintf("* **Assembled trait combinations minted**: %d\n", int64(mintedTraitCombos.Size())))
		b.WriteString(ufmt.Sprintf("* **Max possible unique combinations**: %d\n", MaxUniqueTraitCombos()))
		if MaxSupply > 0 {
			b.WriteString(ufmt.Sprintf("* **Max supply**: %d\n", MaxSupply))
		} else {
			b.WriteString("* **Max supply**: unlimited\n")
		}
		if mintingOpen {
			b.WriteString("* **Minting**: open\n")
		} else {
			b.WriteString("* **Minting**: closed\n")
		}
		if mintPriceUgnot > 0 {
			b.WriteString(ufmt.Sprintf("* **Mint price**: %d ugnot\n", mintPriceUgnot))
		} else {
			b.WriteString("* **Mint price**: free\n")
		}
		if maxMintsPerWallet > 0 {
			b.WriteString(ufmt.Sprintf("* **Max mints per wallet**: %d\n", maxMintsPerWallet))
		} else {
			b.WriteString("* **Max mints per wallet**: unlimited\n")
		}
		b.WriteString(ufmt.Sprintf("* **Reveal delay**: %d blocks after each token's own mint\n", int64(RevealDelayBlocks)))
		if migrationSnapshotSize > 0 {
			b.WriteString(ufmt.Sprintf("* **Migration claims**: %d/%d claimed\n", migrationClaimedCount, migrationSnapshotSize))
		}
		if len(burnedIDs) > 0 {
			b.WriteString(ufmt.Sprintf("* **Burned**: %d — [view burned tokens →](%s:burned)\n", len(burnedIDs), realmRelPath))
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
		b.WriteString(ufmt.Sprintf("# %s — minted tokens\n\n[← back to collection](%s)\n", nft.Name(), realmRelPath))
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
		b.WriteString(ufmt.Sprintf("# %s — burned tokens\n\n[← back to collection](%s)\n", nft.Name(), realmRelPath))
		renderBurnedListPage(&b, page)
		return b.String()
	}
	if len(parts) == 2 && parts[0] == "token" {
		tid := grc721.TokenID(parts[1])
		owner, err := nft.OwnerOf(tid)
		if err != nil {
			return render404()
		}
		metadata, _ := currentMetadata(tid)
		var b strings.Builder
		b.WriteString(ufmt.Sprintf("# %s #%s\n\n[← back to collection](%s)\n\n", nft.Name(), tid.String(), realmRelPath))
		image := metadata.Image
		if image == "" {
			image = metadata.ImageData
		}
		name := metadata.Name
		if name == "" {
			name = "Untitled"
		}
		if image != "" {
			b.WriteString(ufmt.Sprintf("![%s](%s)\n\n", name, bigTokenImage(image)))
		}

		b.WriteString("## Details\n\n")
		b.WriteString(ufmt.Sprintf("* **Collection**: %s\n", nft.Name()))
		b.WriteString(ufmt.Sprintf("* **Name**: %s\n", name))
		b.WriteString(ufmt.Sprintf("* **Index**: #%s\n", tid.String()))
		if metadata.Description != "" {
			b.WriteString(ufmt.Sprintf("* **Description**: %s\n", metadata.Description))
		}
		b.WriteString(ufmt.Sprintf("* **Owner**: %s\n", owner))
		// No separate "minted at block" line here -- Provenance()'s
		// OriginalMintHeight already shows up as "Original Mint Height"
		// in the Traits section below, and duplicating it in Details was
		// redundant.
		if _, hadReveal := sealedData.Get(tid.String()).(traitPreset); hadReveal {
			revealed := "no"
			if IsRevealed(tid) {
				revealed = "yes"
			}
			b.WriteString(ufmt.Sprintf("* **Revealed**: %s (age %d blocks)\n", revealed, Age(tid)))
		}

		// Provenance fields (how this piece got here -- a fresh mint on
		// this chain, or carried forward from an earlier one) are real
		// data about the token's history, not a trait of the piece
		// itself, so they get their own section instead of sitting
		// inside "Traits" alongside Chain/Shape/Color/Metal/Status.
		var traits, provenance []grc721.Trait
		for _, attr := range metadata.Attributes {
			switch attr.TraitType {
			case "Original Chain", "Original Token ID", "Original Mint Height", "Migrated From":
				provenance = append(provenance, attr)
			default:
				traits = append(traits, attr)
			}
		}
		if len(traits) > 0 {
			b.WriteString("\n## Traits\n\n")
			for _, attr := range traits {
				b.WriteString(ufmt.Sprintf("* **%s**: %s\n", attr.TraitType, attr.Value))
			}
		}
		if len(provenance) > 0 {
			b.WriteString("\n## Provenance\n\n")
			for _, attr := range provenance {
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
