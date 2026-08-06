// Package nftminter is a single-collection GRC721 NFT minter realm.
//
// Minting is public and free — anyone can call Mint, no allowlist, no
// payment. Metadata is predetermined: the owner curates an ordered queue
// of preset tokens (AddPresetToken), and Mint just hands out the next
// unclaimed one — the caller supplies no metadata and cannot influence
// or later change what they receive (metadata-editing functions are
// collection-owner-only, not token-owner). Metadata is stored fully
// on-chain per token, following the OpenSea metadata standard.
//
// The realm's public functions deliberately mirror the standard GRC721
// shape (Mint/OwnerOf/TokenURI/SafeTransferFrom/BalanceOf/...) so that
// tooling built against any GRC721 collection — a marketplace, an
// explorer/observer — can interact with this one without special-casing
// it. See gno.land/p/g1w7kytlgsgstspzlpy4fdtd9uqf0ga2dzud4wzv/grc721 for
// the underlying token implementation.
package nftminter

import (
	unsaferealm "chain/runtime/unsafe"
	"encoding/base64"
	"strings"

	"gno.land/p/g1w7kytlgsgstspzlpy4fdtd9uqf0ga2dzud4wzv/grc721"
	"gno.land/p/g1w7kytlgsgstspzlpy4fdtd9uqf0ga2dzud4wzv/avl"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	CollectionName   = "Tardigrades in Gnoland"
	CollectionSymbol = "TARDIGRADE"

	// MaxSupply caps total mints; 0 means unlimited.
	MaxSupply = 69
)

var (
	// nft holds the collection's token state. Concrete type on purpose
	// (see grc721.IGRC721Reader's doc comment): there is no writer
	// interface, so every mutation must go through one of this realm's
	// own cur-validating wrappers below.
	nft *grc721.MetadataNFT

	// collectionOwner curates the preset queue and can edit token
	// metadata — minting itself is public and needs no authorization.
	// Deploy-time constant: the address that published this realm.
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
	collectionOwner address = "g1w7kytlgsgstspzlpy4fdtd9uqf0ga2dzud4wzv"

	nextID seqid.ID

	// presets is the owner-curated queue of not-yet-minted token
	// metadata, in mint order. presetsIn is the index the next
	// AddPresetToken call writes to; presetsOut is the index Mint
	// consumes next — the gap between them is the queue's contents.
	presets    avl.Tree // seqid string -> presetEntry
	presetsIn  seqid.ID
	presetsOut seqid.ID

	// mintedIDs is every token ID ever minted, in mint order, including
	// burned ones (OwnerOf simply errors for those — callers iterating
	// this list should skip whatever it rejects). Exists purely to make
	// "list the whole collection" / "list what address X owns" possible
	// without needing to reach into grc721's internal owners tree, which
	// isn't exposed for iteration.
	mintedIDs []grc721.TokenID
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

func TokenURI(tid grc721.TokenID) (string, error) {
	return nft.TokenURI(tid)
}

func TokenMetadata(tid grc721.TokenID) (grc721.Metadata, error) {
	return nft.TokenMetadata(tid)
}

func GetApproved(tid grc721.TokenID) (address, error) {
	return nft.GetApproved(tid)
}

func IsApprovedForAll(owner, operator address) bool {
	return nft.IsApprovedForAll(owner, operator)
}

// PresetQueueLength reports how many not-yet-minted preset tokens are
// queued up — i.e. how many more times Mint can succeed before it needs
// AddPresetToken to be called again.
func PresetQueueLength() int64 {
	return int64(presets.Size())
}

// Getter returns a reader-only view of the collection, safe to register
// with cross-realm aggregators (marketplace, observer) without risking
// a captured cur.
func Getter() grc721.NFTGetter {
	return nft.Getter()
}

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
	metadata, err := nft.TokenMetadata(tid)
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

// assertOwner panics unless the caller is the collection owner — this
// realm's own equivalent of ownable.Ownable.AssertOwnedBy, see
// collectionOwner's doc comment for why it's not that package.
func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("unauthorized: caller is not the collection owner")
	}
}

/* ------------------------------- Minting ---------------------------------- */

// Mint creates a new token owned by `to`, assigns it the next
// not-yet-claimed preset in the queue (see AddPresetToken), and returns
// its token ID. Public — anyone can call this, no authorization check,
// no payment. Panics if the preset queue is empty — queue more with
// AddPresetToken first.
//
// Deliberately takes no metadata of any kind from the caller: the point
// of the preset queue is that whoever ends up minting a token can't
// choose or influence what it looks like.
func Mint(cur realm, to address) grc721.TokenID {
	if MaxSupply > 0 && nft.TokenCount() >= MaxSupply {
		panic("max supply reached")
	}

	outKey := presetsOut.String()
	preset, ok := presets.Get(outKey).(presetEntry)
	if !ok {
		panic("no preset tokens queued — call AddPresetToken first")
	}
	presets.Remove(outKey)
	presetsOut.Next()

	tid := grc721.TokenID(nextID.String())
	checkErr(nft.Mint(to, tid))
	checkErr(nft.SetTokenMetadata(to, tid, grc721.Metadata{
		Name:            preset.Name,
		Description:     preset.Description,
		Image:           preset.Image,
		ExternalURL:     preset.ExternalURL,
		BackgroundColor: preset.BackgroundColor,
		Attributes:      preset.Attributes,
	}))
	nextID.Next()
	mintedIDs = append(mintedIDs, tid)

	return tid
}

// AddPresetToken queues one predetermined token's metadata for a future
// Mint call to hand out, in the order added. Owner-only — this is the
// only way preset metadata enters the collection; nothing else can
// influence what an eventual Mint call produces.
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
// queue to empty. Owner-only. Already-minted tokens are unaffected —
// this only touches what Mint would hand out next.
func ClearPresetQueue(cur realm) {
	assertOwner()
	presets = avl.Tree{}
	presetsIn = 0
	presetsOut = 0
}

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

// SetTokenMetadata overwrites a token's on-chain metadata wholesale.
// Owner-only (see tokenOwnerAsCaller) — not callable by whoever holds
// the token. Takes the full grc721.Metadata struct, so — unlike
// UpdateTokenMetadata below — it can only be invoked programmatically
// (e.g. from another realm), not via a plain gnokey/MsgCall transaction;
// see Mint's doc comment.
func SetTokenMetadata(cur realm, tid grc721.TokenID, metadata grc721.Metadata) {
	assertOwner()
	checkErr(nft.SetTokenMetadata(tokenOwnerAsCaller(tid), tid, metadata))
}

// UpdateTokenMetadata rewrites the name/description/image/externalURL
// fields of a token's on-chain metadata, preserving its Attributes and
// other fields. Owner-only (see tokenOwnerAsCaller).
func UpdateTokenMetadata(cur realm, tid grc721.TokenID, name, description, image, externalURL string) {
	assertOwner()
	metadata, err := nft.TokenMetadata(tid)
	checkErr(err)
	metadata.Name = name
	metadata.Description = description
	metadata.Image = image
	metadata.ExternalURL = externalURL
	checkErr(nft.SetTokenMetadata(tokenOwnerAsCaller(tid), tid, metadata))
}

// AddTokenAttribute appends one trait to a token's on-chain metadata.
// Owner-only (see tokenOwnerAsCaller).
func AddTokenAttribute(cur realm, tid grc721.TokenID, traitType, value, displayType string) {
	assertOwner()
	metadata, err := nft.TokenMetadata(tid)
	checkErr(err)
	metadata.Attributes = append(metadata.Attributes, grc721.Trait{
		TraitType:   traitType,
		Value:       value,
		DisplayType: displayType,
	})
	checkErr(nft.SetTokenMetadata(tokenOwnerAsCaller(tid), tid, metadata))
}

// ClearTokenAttributes removes all traits from a token's on-chain
// metadata. Owner-only (see tokenOwnerAsCaller).
func ClearTokenAttributes(cur realm, tid grc721.TokenID) {
	assertOwner()
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
		b.WriteString(ufmt.Sprintf("* **Presets queued**: %d\n", PresetQueueLength()))
		if MaxSupply > 0 {
			b.WriteString(ufmt.Sprintf("* **Max supply**: %d\n", MaxSupply))
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
		metadata, _ := nft.TokenMetadata(tid)
		var b strings.Builder
		b.WriteString(ufmt.Sprintf("# %s #%s\n\n", nft.Name(), tid.String()))
		b.WriteString(ufmt.Sprintf("* **Owner**: %s\n", owner))
		if metadata.Name != "" {
			b.WriteString(ufmt.Sprintf("* **Name**: %s\n", metadata.Name))
		}
		if metadata.Description != "" {
			b.WriteString(ufmt.Sprintf("* **Description**: %s\n", metadata.Description))
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
