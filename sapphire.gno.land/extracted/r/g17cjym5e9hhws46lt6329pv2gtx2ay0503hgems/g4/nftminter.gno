// Package nftminter is a single-collection GRC721 NFT minter realm.
//
// Minting is public and free — anyone can call Mint, no allowlist, no
// payment. Metadata is predetermined: the owner curates a pool of preset
// tokens (AddPresetToken), and Mint hands out a uniformly-random unclaimed
// one — the caller supplies no metadata and cannot choose or later change
// what they receive (metadata-editing functions are collection-owner-only,
// not token-owner). Metadata is stored fully on-chain per token, following
// the OpenSea metadata standard.
//
// Two parallel mint paths, deliberately kept separate: Mint/AddPresetToken
// store a full precomputed image per token (presetEntry) — simple, but
// storage cost scales with token count, and the owner must curate every
// piece by hand ahead of time. MintAssembled has no curated pool at all —
// each mint randomly assembles a small trait selection (traitPreset) from
// on-chain rosters (chainRoster, gems.gno's shapeNames/metalNames/stone
// color palettes) and calls this realm's own gems.gno to render the
// actual image on every read — storage cost is dominated by gems.gno's
// own one-time deployment, not by how many tokens exist, and there is no
// owner curation step at all: every valid trait combination is mintable
// from the start. The "gem in a ring" collection this realm currently
// serves uses the assembled path exclusively; the image-preset path is
// kept fully working and untouched for reuse on a future collection that
// wants precomputed/hand-authored art instead.
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
package g4

import (
	"chain"
	"chain/banker"
	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/base64"
	"strings"

	"gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/avl"
	"gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/grc721"
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
	realmRelPath = "/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/g4"

	// homeRenderLimit caps how many minted tokens Render()'s home page
	// lists. Unlike simplenftminter.gno's generic template (aimed at
	// small one-off collections), Gems has no fixed supply and is meant
	// to run for a long time, so an uncapped listing would eventually hit
	// gnoweb's own 1 MiB markdown render ceiling and silently fall back
	// to a plain-text dump. Most-recent-first, same as gems-mint.html's
	// own client-side stream.
	homeRenderLimit = 50
)

// sealedImage is the shared placeholder every token shows until its own
// reveal delay has passed. Built from a literal SVG rather than a
// hand-encoded base64 blob so it stays readable/editable in source.
var sealedImage = "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(
	// width/height on the root svg, not just viewBox -- see gems.gno's
	// renderTokenSVG for why (gnoweb collapses an otherwise-ambiguous-size
	// embedded image down to 2x2px).
	`<svg xmlns="http://www.w3.org/2000/svg" width="170" height="170" viewBox="0 0 170 170"><rect width="170" height="170" fill="#0a0b10"/><circle cx="85" cy="78" r="50" fill="none" stroke="#5a5f6b" stroke-width="4" stroke-dasharray="4 4"/><text x="85" y="94" font-size="46" text-anchor="middle" fill="#5a5f6b" font-family="ui-monospace,monospace">?</text></svg>`,
))

var (
	// nft holds the collection's token state. Concrete type on purpose
	// (see grc721.IGRC721Reader's doc comment): there is no writer
	// interface, so every mutation must go through one of this realm's
	// own cur-validating wrappers below.
	nft *grc721.MetadataNFT

	// collectionOwner curates the preset pool and can edit token
	// metadata — minting itself is public and needs no authorization.
	// A dedicated address for this collection specifically (funded and
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
	// Mint and MintAssembled (not ClaimMigrated: closing new mints
	// shouldn't block someone completing a rightful migration claim).
	// Independent of the preset pool being empty: the owner can halt
	// minting even with presets still queued, e.g. to pause a drop.
	mintingOpen = true

	// mintPriceUgnot is the price MintAssembled charges, checked exactly
	// (not a minimum) -- see the payment check inlined in MintAssembled
	// itself. Starts at 0 (free)
	// until the owner sets a real price via SetMintPrice; Mint (the
	// image-preset path) stays free/unaffected regardless of this value,
	// per request. Deliberately a plain owner-settable number rather
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

	// presets is the owner-curated POOL of not-yet-minted token metadata.
	// presetsIn only generates unique keys now (it stopped meaning "queue
	// position" the moment Mint switched from FIFO to random pick — see
	// pickRandomIndex).
	presets   avl.Tree // seqid string -> presetEntry
	presetsIn seqid.ID

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
	// it went through Mint — ClaimMigrated sets final metadata directly
	// (a migrated token is re-establishing something already revealed on
	// its original chain, not a fresh random draw).
	mintHeight avl.Tree // tid.String() -> int64
	sealedData avl.Tree // tid.String() -> presetEntry

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
)

// presetEntry is one not-yet-minted token's predetermined metadata,
// queued by the owner ahead of time via AddPresetToken.
type presetEntry struct {
	Name            string
	Description     string
	Image           string
	ExternalURL     string
	BackgroundColor string
	Attributes      []grc721.Trait
}

// traitPreset is one not-yet-minted token's small trait selection for the
// assembled-on-read path (see gems.gno, MintAssembled) — the
// counterpart to presetEntry, but holding just enough for the shared
// on-chain generator to reconstruct the full image at TokenURI time
// instead of a whole precomputed image string. Stone isn't stored here:
// it's derived from Chain (see stoneForChain in gems.gno), same as the
// prototype that designed this collection.
type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
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
type migrationEntry struct {
	OriginalOwner      address
	OriginalChain      string
	OriginalTokenID    string
	OriginalMintHeight int64
	Preset             presetEntry
	Claimed            bool
}

// parseAttributesCSV decodes AddPresetToken's attributesCSV argument:
// "TraitType=Value" pairs separated by ";", e.g.
// "Hat=Red Beanie;Eyes=Laser;Clothing=Denim Jacket". Blank entries and
// entries missing "=" are skipped rather than erroring — keeps this
// forgiving for hand-typed input from the web console.
func parseAttributesCSV(csv string) []grc721.Trait {
	if csv == "" {
		return nil
	}
	var attrs []grc721.Trait
	for _, pair := range strings.Split(csv, ";") {
		if pair == "" {
			continue
		}
		idx := strings.Index(pair, "=")
		if idx < 0 {
			continue
		}
		attrs = append(attrs, grc721.Trait{
			TraitType: pair[:idx],
			Value:     pair[idx+1:],
		})
	}
	return attrs
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

	realRaw := sealedData.Get(tid.String())

	if real, hadReveal := realRaw.(presetEntry); hadReveal {
		if !IsRevealed(tid) {
			return stored, nil // still sealed
		}
		attrs := append([]grc721.Trait{}, real.Attributes...)
		attrs = append(attrs, provenanceAttrs(tid)...)
		return grc721.Metadata{
			Name:            real.Name,
			Description:     real.Description,
			Image:           real.Image,
			ExternalURL:     real.ExternalURL,
			BackgroundColor: real.BackgroundColor,
			Attributes:      attrs,
		}, nil
	}

	if tp, hadReveal := realRaw.(traitPreset); hadReveal {
		if !IsRevealed(tid) {
			return stored, nil // still sealed
		}
		return assembledMetadata(tid, tp), nil
	}

	// migrated token, or something else that never went through a Mint/
	// MintAssembled seal step — the stored metadata already is final.
	return stored, nil
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
		{TraitType: "Chain", Value: tp.Chain},
		{TraitType: "Stone", Value: stone},
		{TraitType: "Shape", Value: shapeNames[tp.ShapeIdx]},
		{TraitType: "Color", Value: colorName},
		{TraitType: "Metal", Value: tp.Metal},
		{TraitType: "Status", Value: status},
	}
	attrs = append(attrs, provenanceAttrs(tid)...)
	return grc721.Metadata{
		Name:            ufmt.Sprintf("Gem in a Ring #%s", tid.String()),
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

// PresetQueueLength reports how many not-yet-minted preset tokens are in
// the pool — i.e. how many more times Mint can succeed before it needs
// AddPresetToken to be called again. Kept under its original name for
// compatibility even though "queue" is no longer literally accurate —
// Mint draws randomly from this pool now, not in the order added.
func PresetQueueLength() int64 {
	return int64(presets.Size())
}

// Getter returns a reader-only view of the collection, safe to register
// with cross-realm aggregators (marketplace, observer) without risking
// a captured cur.
func Getter() grc721.NFTGetter {
	return nft.Getter()
}

/* --------------------------- Reveal mechanics ------------------------------ */

// Age returns real blocks elapsed since tid was minted (normal Mint only
// — migrated-in tokens have no seal step, hence no meaningful age), or -1
// if it doesn't exist / was never sealed.
func Age(tid grc721.TokenID) int64 {
	h := mintHeight.Get(tid.String())
	if h == nil {
		return -1
	}
	return runtime.ChainHeight() - h.(int64)
}

// IsRevealed reports whether tid's real metadata is visible yet. Tokens
// that were never sealed (migrated-in) report true — there's nothing left
// to reveal. Checks both seal types (presetEntry from Mint, traitPreset
// from MintAssembled) since either can be sitting behind sealedData.
func IsRevealed(tid grc721.TokenID) bool {
	raw := sealedData.Get(tid.String())
	_, isPreset := raw.(presetEntry)
	_, isTraitPreset := raw.(traitPreset)
	if !isPreset && !isTraitPreset {
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

// traitsToCSV is the inverse of parseAttributesCSV — used by TokenSummary
// to round-trip a token's traits through the same "TraitType=Value;..."
// format AddPresetToken accepts, keeping the encoding symmetric.
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
// token (burned tokens are silently skipped), newline-separated, in mint
// order.
func CollectionSummary() string {
	var lines []string
	for _, tid := range mintedIDs {
		line, err := TokenSummary(tid)
		if err != nil {
			continue // burned since minting
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// WalletSummary is CollectionSummary filtered to tokens currently owned
// by owner.
func WalletSummary(owner address) string {
	var lines []string
	for _, tid := range mintedIDs {
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
	return strings.Join(lines, "\n")
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
	realRaw := sealedData.Get(tid.String())

	if real, hadReveal := realRaw.(presetEntry); hadReveal {
		attrs := append([]grc721.Trait{}, real.Attributes...)
		attrs = append(attrs, provenanceAttrs(tid)...)
		return grc721.Metadata{
			Name:            real.Name,
			Description:     real.Description,
			Image:           real.Image,
			ExternalURL:     real.ExternalURL,
			BackgroundColor: real.BackgroundColor,
			Attributes:      attrs,
		}, nil
	}

	if tp, hadReveal := realRaw.(traitPreset); hadReveal {
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
// same line format, but bypasses the reveal seal entirely so a complete,
// authoritative backup can be taken at any moment — e.g. right after a
// testnet deprecation is announced, without needing to wait out
// individual tokens' remaining reveal delay first. Meant specifically for
// disaster-recovery/migration snapshots (see AddMigrationSnapshotEntry) —
// exposing this to anyone but the owner would defeat the point of
// sealing in the first place, hence `cur realm` + assertOwner rather than
// a plain query function, matching this realm's other owner-gated calls.
func RawCollectionSummary(cur realm) string {
	assertOwner()
	var lines []string
	for _, tid := range mintedIDs {
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

// pickRandomIndex returns a pseudo-random index in [0, n). Entropy comes
// from chain height, the next token ID counter, the preset-pool insertion
// counter, and the caller's address, hashed with sha256 — best-effort,
// NOT cryptographically secure randomness (a validator/block-producer who
// controls transaction ordering could in principle bias which height a
// given mint lands in). That weakness matters much less here than it
// would in a naive "random index -> immediately-visible metadata" design,
// because the delayed reveal (see RevealDelayBlocks) means even a party
// who *could* predict/steer which pool slot gets picked still can't see
// what's actually in it until after mint. The two mechanisms are meant to
// be read together, not the random pick alone.
func pickRandomIndex(n int) int {
	if n <= 1 {
		return 0
	}
	material := ufmt.Sprintf("%d:%d:%d:%s",
		runtime.ChainHeight(), uint64(nextID), uint64(presetsIn), callerAddress().String())
	sum := sha256.Sum256([]byte(material))
	var v uint64
	for i := 0; i < 8; i++ {
		v = v<<8 | uint64(sum[i])
	}
	return int(v % uint64(n))
}

// Mint creates a new token owned by `to`, assigns it a uniformly-random
// not-yet-claimed preset from the pool (see AddPresetToken and
// pickRandomIndex), and returns its token ID. Public — anyone can call
// this, no authorization check, no payment. Panics if the preset pool is
// empty — add more with AddPresetToken first.
//
// Deliberately takes no metadata of any kind from the caller: the point
// of the preset pool is that whoever ends up minting a token can't
// choose or influence what it looks like. The token's real metadata
// stays sealed behind sealedImage/a "Sealed" placeholder for
// RevealDelayBlocks blocks — see IsRevealed/Age — so it can't be seen in
// advance either, not even by the minter.
func Mint(cur realm, to address) grc721.TokenID {
	if !mintingOpen {
		panic("minting is closed")
	}
	if MaxSupply > 0 && nft.TokenCount() >= MaxSupply {
		panic("max supply reached")
	}

	n := presets.Size()
	if n == 0 {
		panic("no preset tokens queued — call AddPresetToken first")
	}
	idx := pickRandomIndex(n)
	key, val := presets.GetByIndex(idx)
	preset, ok := val.(presetEntry)
	if !ok {
		panic("no preset tokens queued — call AddPresetToken first")
	}
	presets.Remove(key)

	tid := grc721.TokenID(nextID.String())
	checkErr(nft.Mint(to, tid))
	checkErr(nft.SetTokenMetadata(to, tid, grc721.Metadata{
		Name:       "Sealed",
		Image:      sealedImage,
		Attributes: []grc721.Trait{{TraitType: "Status", Value: "Sealed"}},
	}))

	height := runtime.ChainHeight()
	mintHeight.Set(tid.String(), height)
	sealedData.Set(tid.String(), preset)
	mintProvenance.Set(tid.String(), provenanceInfo{
		OriginalChain:      runtime.ChainID(),
		OriginalTokenID:    tid.String(),
		OriginalMintHeight: height,
	})

	nextID.Next()
	mintedIDs = append(mintedIDs, tid)

	return tid
}

// AddPresetToken adds one predetermined token's metadata to the pool a
// future Mint call may draw from — Mint no longer hands these out in the
// order added (see pickRandomIndex), so "queue" is now just a name.
// Owner-only — this is the only way preset metadata enters the
// collection; nothing else can influence what an eventual Mint call
// produces. Callable at any time, including after the collection has
// already started minting — e.g. adding a newly-launched testnet
// generation's art to the pool alongside whatever's already there.
//
// attributesCSV packs an arbitrary number of traits into one primitive
// string argument — see parseAttributesCSV for the format. Required for
// this to stay callable via a real gnokey/MsgCall transaction: a []Trait
// parameter isn't an option (see Mint's doc comment on why struct/slice
// arguments make a function uncallable from a real transaction).
func AddPresetToken(cur realm, name, description, image, externalURL, backgroundColor, attributesCSV string) {
	assertOwner()
	presets.Set(presetsIn.String(), presetEntry{
		Name:            name,
		Description:     description,
		Image:           image,
		ExternalURL:     externalURL,
		BackgroundColor: backgroundColor,
		Attributes:      parseAttributesCSV(attributesCSV),
	})
	presetsIn.Next()
}

// ClearPresetQueue discards every not-yet-minted preset, resetting the
// pool to empty. Owner-only. Already-minted tokens are unaffected — this
// only touches what Mint would hand out next.
func ClearPresetQueue(cur realm) {
	assertOwner()
	presets = avl.Tree{}
	presetsIn = 0
}

// MintAssembled is Mint's counterpart for the assembled-on-read path: no
// owner-curated pool at all — every mint randomly assembles a fresh
// (chain, shape, color, metal, active) combination from the on-chain
// rosters (chainRoster/shapeNames/metalNames, with color drawn from
// whichever palette the chosen chain's stone uses), rejecting and
// re-drawing on the rare collision against a combination that's already
// been minted (see assembleUniqueTraits). No curation step means no
// control over rarity pacing or which combinations exist and when — every
// valid combination in the whole trait space is mintable from the start.
// That trade-off is deliberate, not an oversight: see the earlier
// AddTraitPreset-based design (git history) for the curated-pool
// alternative this replaced, kept there for reference. A separate
// function from Mint, rather than merging the two paths, so the original
// image-preset path above stays completely untouched for reuse on a
// future collection, per request. Public — no authorization check, no
// caller-supplied metadata of any kind — but unlike Mint, DOES require
// payment if the owner has set one (see MintPrice/SetMintPrice and the
// payment check inlined below): the caller's attached "ugnot" send must
// match the current price exactly, or the whole call reverts (including
// the attempted payment — a panic here rolls back the entire message,
// confirmed against this project's actual SDK message-processing code,
// not assumed).
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
func AddMigrationSnapshotEntry(
	cur realm,
	originalOwner address,
	originalChain, originalTokenID string,
	originalMintHeight int64,
	name, description, image, externalURL, backgroundColor, attributesCSV string,
) {
	assertOwner()
	key := originalChain + "/" + originalTokenID
	if _, exists := migrationSnapshot.Get(key).(migrationEntry); !exists {
		migrationSnapshotSize++
	}
	migrationSnapshot.Set(key, migrationEntry{
		OriginalOwner:      originalOwner,
		OriginalChain:      originalChain,
		OriginalTokenID:    originalTokenID,
		OriginalMintHeight: originalMintHeight,
		Preset: presetEntry{
			Name:            name,
			Description:     description,
			Image:           image,
			ExternalURL:     externalURL,
			BackgroundColor: backgroundColor,
			Attributes:      parseAttributesCSV(attributesCSV),
		},
	})
}

// ClaimMigrated mints a fresh token here carrying forward a previous
// chain's token, for whoever's address matches the seeded
// AddMigrationSnapshotEntry record — public, no owner involvement beyond
// having seeded the entry. Unlike Mint, the result is never sealed: a
// migrated token is re-establishing something already revealed on its
// original chain, not a fresh random draw, so hiding it here would serve
// no purpose. Its metadata carries the original preset content plus
// explicit "Original Chain" / "Original Token ID" / "Original Mint
// Height" traits (see Provenance) — that's what preserves legitimacy
// across the move. Panics if there's no matching entry, it's already been
// claimed, or the caller isn't the recorded original owner.
func ClaimMigrated(cur realm, originalChain, originalTokenID string) grc721.TokenID {
	if MaxSupply > 0 && nft.TokenCount() >= MaxSupply {
		panic("max supply reached")
	}

	key := originalChain + "/" + originalTokenID
	raw := migrationSnapshot.Get(key)
	entry, ok := raw.(migrationEntry)
	if !ok {
		panic("no migration record for that original chain/token")
	}
	if entry.Claimed {
		panic("already claimed")
	}
	caller := callerAddress()
	if caller != entry.OriginalOwner {
		panic("caller did not hold this token on the original chain")
	}

	tid := grc721.TokenID(nextID.String())
	attrs := append([]grc721.Trait{}, entry.Preset.Attributes...)
	attrs = append(attrs,
		grc721.Trait{TraitType: "Migrated From", Value: entry.OriginalChain},
		grc721.Trait{TraitType: "Original Token ID", Value: entry.OriginalTokenID},
		grc721.Trait{TraitType: "Original Mint Height", Value: ufmt.Sprintf("%d", entry.OriginalMintHeight)},
	)
	checkErr(nft.Mint(caller, tid))
	checkErr(nft.SetTokenMetadata(caller, tid, grc721.Metadata{
		Name:            entry.Preset.Name,
		Description:     entry.Preset.Description,
		Image:           entry.Preset.Image,
		ExternalURL:     entry.Preset.ExternalURL,
		BackgroundColor: entry.Preset.BackgroundColor,
		Attributes:      attrs,
	}))

	mintProvenance.Set(tid.String(), provenanceInfo{
		OriginalChain:      entry.OriginalChain,
		OriginalTokenID:    entry.OriginalTokenID,
		OriginalMintHeight: entry.OriginalMintHeight,
	})

	nextID.Next()
	mintedIDs = append(mintedIDs, tid)

	entry.Claimed = true
	migrationSnapshot.Set(key, entry)
	migrationClaimedCount++

	return tid
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
// Every metadata-editing function below asserts collection ownership
// itself first, then uses this to satisfy that inner check: the result
// is that only the collection owner can edit metadata, never whoever
// happens to hold the token, which is the whole point of a preset,
// non-customizable collection.
func tokenOwnerAsCaller(tid grc721.TokenID) address {
	owner, err := nft.OwnerOf(tid)
	checkErr(err)
	return owner
}

// isTraitPresetToken reports whether tid went through MintAssembled
// rather than Mint — its real metadata is computed fresh from a small
// trait tuple on every read (see assembledMetadata), so nft's own stored
// metadata for it is permanently just the sealed placeholder and never
// gets written to again after mint. The four metadata-editing functions
// below guard on this: editing the live stored metadata of such a token
// would silently do nothing (currentMetadata ignores it in favor of the
// re-derived value once revealed), which is a much worse failure mode
// than an explicit panic telling the owner why.
func isTraitPresetToken(tid grc721.TokenID) bool {
	_, ok := sealedData.Get(tid.String()).(traitPreset)
	return ok
}

// SetTokenMetadata overwrites a token's on-chain metadata wholesale.
// Owner-only (see tokenOwnerAsCaller) — not callable by whoever holds
// the token. Takes the full grc721.Metadata struct, so — unlike
// UpdateTokenMetadata below — it can only be invoked programmatically
// (e.g. from another realm), not via a plain gnokey/MsgCall transaction;
// see Mint's doc comment. Note: this sets the STORED metadata directly,
// bypassing the seal/reveal dance — mainly useful for migrated tokens or
// already-revealed ones; using it on a still-sealed token would reveal it
// immediately.
func SetTokenMetadata(cur realm, tid grc721.TokenID, metadata grc721.Metadata) {
	assertOwner()
	if isTraitPresetToken(tid) {
		panic("token's metadata is computed on-chain from its trait preset, not directly editable — see AddTraitPreset")
	}
	checkErr(nft.SetTokenMetadata(tokenOwnerAsCaller(tid), tid, metadata))
}

// UpdateTokenMetadata rewrites the name/description/image/externalURL
// fields of a token's metadata, preserving its Attributes and other
// fields. Owner-only (see tokenOwnerAsCaller). For any token that went
// through Mint, sealedData is the permanent source of truth for its real
// content — currentMetadata always reads from there once revealed (see
// its own doc comment for why: TokenMetadata/TokenURI take no `cur realm`
// and genuinely cannot write a one-time "reveal commit" into live
// storage on read) — so edits land there for the token's whole lifetime,
// sealed or not. Only tokens with no sealedData entry (migrated-in via
// ClaimMigrated, never sealed to begin with) edit live stored metadata
// directly.
func UpdateTokenMetadata(cur realm, tid grc721.TokenID, name, description, image, externalURL string) {
	assertOwner()
	if isTraitPresetToken(tid) {
		panic("token's metadata is computed on-chain from its trait preset, not directly editable — see AddTraitPreset")
	}
	if real, hadReveal := sealedData.Get(tid.String()).(presetEntry); hadReveal {
		real.Name = name
		real.Description = description
		real.Image = image
		real.ExternalURL = externalURL
		sealedData.Set(tid.String(), real)
		return
	}
	metadata, err := nft.TokenMetadata(tid)
	checkErr(err)
	metadata.Name = name
	metadata.Description = description
	metadata.Image = image
	metadata.ExternalURL = externalURL
	checkErr(nft.SetTokenMetadata(tokenOwnerAsCaller(tid), tid, metadata))
}

// AddTokenAttribute appends one trait to a token's metadata. Owner-only
// (see tokenOwnerAsCaller). Same sealed-vs-live routing as
// UpdateTokenMetadata.
func AddTokenAttribute(cur realm, tid grc721.TokenID, traitType, value, displayType string) {
	assertOwner()
	if isTraitPresetToken(tid) {
		panic("token's metadata is computed on-chain from its trait preset, not directly editable — see AddTraitPreset")
	}
	trait := grc721.Trait{TraitType: traitType, Value: value, DisplayType: displayType}
	if real, hadReveal := sealedData.Get(tid.String()).(presetEntry); hadReveal {
		real.Attributes = append(real.Attributes, trait)
		sealedData.Set(tid.String(), real)
		return
	}
	metadata, err := nft.TokenMetadata(tid)
	checkErr(err)
	metadata.Attributes = append(metadata.Attributes, trait)
	checkErr(nft.SetTokenMetadata(tokenOwnerAsCaller(tid), tid, metadata))
}

// ClearTokenAttributes removes all traits from a token's metadata.
// Owner-only (see tokenOwnerAsCaller). Same sealedData-vs-live routing as
// UpdateTokenMetadata — see its doc comment.
func ClearTokenAttributes(cur realm, tid grc721.TokenID) {
	assertOwner()
	if isTraitPresetToken(tid) {
		panic("token's metadata is computed on-chain from its trait preset, not directly editable — see AddTraitPreset")
	}
	if real, hadReveal := sealedData.Get(tid.String()).(presetEntry); hadReveal {
		real.Attributes = nil
		sealedData.Set(tid.String(), real)
		return
	}
	metadata, err := nft.TokenMetadata(tid)
	checkErr(err)
	metadata.Attributes = nil
	checkErr(nft.SetTokenMetadata(tokenOwnerAsCaller(tid), tid, metadata))
}

// SetTokenURI sets an (optional) off-chain pointer alongside the
// on-chain metadata. Owner-only (see tokenOwnerAsCaller).
func SetTokenURI(cur realm, tid grc721.TokenID, uri string) {
	assertOwner()
	_, err := nft.SetTokenURI(tokenOwnerAsCaller(tid), tid, grc721.TokenURI(uri))
	checkErr(err)
}

// Burn destroys a token. Caller must be its current owner.
func Burn(cur realm, tid grc721.TokenID) {
	caller := callerAddress()
	owner, err := nft.OwnerOf(tid)
	checkErr(err)
	if caller != owner {
		panic(grc721.ErrCallerIsNotOwner)
	}
	checkErr(nft.Burn(tid))
}

/* --------------------------------- Render --------------------------------- */

func Render(path string) string {
	if path == "" {
		var b strings.Builder
		b.WriteString(nft.RenderHome())
		b.WriteString(ufmt.Sprintf("* **Owner**: %s\n", Owner()))
		b.WriteString(ufmt.Sprintf("* **Presets in pool**: %d\n", PresetQueueLength()))
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

		if len(mintedIDs) > 0 {
			b.WriteString("\n## Minted so far\n\n")
			shown := 0
			truncated := false
			for i := len(mintedIDs) - 1; i >= 0; i-- {
				if shown >= homeRenderLimit {
					truncated = true
					break
				}
				tid := mintedIDs[i]
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
				if image != "" {
					b.WriteString(ufmt.Sprintf("[![%s](%s)](%s)\n", name, image, link))
				}
				b.WriteString(ufmt.Sprintf("- [#%s — %s](%s) (owner: %s)\n", tid.String(), name, link, owner))
				shown++
			}
			if truncated {
				b.WriteString(ufmt.Sprintf("\n_showing the %d most recent of %d minted._\n", shown, len(mintedIDs)))
			}
		}
		return b.String()
	}

	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "token" {
		tid := grc721.TokenID(parts[1])
		owner, err := nft.OwnerOf(tid)
		if err != nil {
			return "404\n"
		}
		metadata, _ := currentMetadata(tid)
		var b strings.Builder
		b.WriteString(ufmt.Sprintf("# %s #%s\n\n", nft.Name(), tid.String()))
		image := metadata.Image
		if image == "" {
			image = metadata.ImageData
		}
		if image != "" {
			name := metadata.Name
			if name == "" {
				name = "Untitled"
			}
			b.WriteString(ufmt.Sprintf("![%s](%s)\n\n", name, image))
		}
		b.WriteString(ufmt.Sprintf("* **Owner**: %s\n", owner))
		if metadata.Name != "" {
			b.WriteString(ufmt.Sprintf("* **Name**: %s\n", metadata.Name))
		}
		if metadata.Description != "" {
			b.WriteString(ufmt.Sprintf("* **Description**: %s\n", metadata.Description))
		}
		if _, hadReveal := sealedData.Get(tid.String()).(presetEntry); hadReveal {
			revealed := "no"
			if IsRevealed(tid) {
				revealed = "yes"
			}
			b.WriteString(ufmt.Sprintf("* **Revealed**: %s (age %d blocks)\n", revealed, Age(tid)))
		}
		if chain, otid, height, err := Provenance(tid); err == nil {
			b.WriteString(ufmt.Sprintf("* **Original chain**: %s\n", chain))
			b.WriteString(ufmt.Sprintf("* **Original token ID**: %s\n", otid))
			b.WriteString(ufmt.Sprintf("* **Original mint height**: %d\n", height))
		}
		return b.String()
	}

	return "404\n"
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
