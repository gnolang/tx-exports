// Package stable is the permanent, never-redeployed half of the Gems
// split-realm design -- the third iteration of this spike (gems ->
// gems2 -> gems3), built out to full scope per request (2026-09-14):
//
//   - Ownership + transfers + burn (Approve/TransferFrom/
//     SafeTransferFrom/SetApprovalForAll/Burn) -- an NFT people can't
//     move or sell isn't real. Burning RELEASES that token's trait
//     combination back into the available pool (a deliberate choice,
//     not an oversight -- see Burn's own comment) and its storage
//     deposit refunds automatically via gno's own storage-accounting
//     the moment the freed bytes are deleted, no custom refund logic
//     needed.
//   - mintedTraitCombos (trait-uniqueness history) lives HERE now, not
//     in the swappable version realm -- so a future version redeploy
//     can never accidentally re-mint an already-used combination.
//   - A full gnoweb Render(), matching the original single-realm
//     design's home page / page/N / token/ID / burned pages exactly,
//     table gallery and pagination included.
//   - Pricing/whitelist now supports a MERKLE PROOF allowlist
//     (whitelistMerkleRoot) alongside the existing per-wallet
//     override, so a large campaign list (hundreds of wallets) costs
//     ONE root hash on-chain instead of one avl.Tree node per wallet --
//     confirmed live (2026-09-14) that a single wallet's avl.Tree entry
//     here costs ~0.22 GNOT in real storage deposit; 441 wallets that
//     way would have been ~99 GNOT. The real wallet list lives in a
//     file next to the mint page instead; each wallet proves its own
//     (address, bps) pair against the on-chain root at mint time.
//
// Mint MECHANICS (trait assembly, art rendering, chain roster) still
// live in the paired version realm (e.g. gems3/v1) and can be
// redeployed and re-approved at will, with zero holder migration,
// because ownership/pricing/whitelist/uniqueness-history never move.
package stable

import (
	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/avl"
	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
	"gno.land/p/nt/ufmt/v0"
)

const (
	CollectionName   = "Gems"
	CollectionSymbol = "GEMS"

	// realmRelPath is this realm's own gnoweb-relative path, baked in
	// as a compile-time constant -- see the original single-realm
	// design's own comment on why (chain/runtime/unsafe.CurrentRealm()
	// resolves differently when called nested inside Render than when
	// called directly). Must be updated by hand if this realm is ever
	// redeployed to a new path.
	realmRelPath = "/r/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/gems3/stable"

	homeRenderLimit = 10
	pageWindow      = 2
	tokenPageImageSize = "420"
)

var (
	nft *grc721.MetadataNFT

	// collectionOwner is the only address allowed to change pricing,
	// the whitelist, or which version realm is approved.
	collectionOwner address = "g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku"

	// approvedVersion is the full pkgpath of the ONE realm currently
	// allowed to call RecordMint.
	approvedVersion string

	mintPriceUgnot int64 = 1_000_000

	// whitelistBps: per-wallet price overrides, for a handful of
	// one-off grants -- cheap for a few wallets, not meant for a large
	// campaign list (see whitelistMerkleRoot for that).
	whitelistBps avl.Tree

	// whitelistMerkleRoot: hex-encoded root of a Merkle tree whose
	// leaves are sha256hex(address + "|" + bps) for every (wallet, bps)
	// pair in a large allowlist. "" means no Merkle allowlist is
	// active. See EffectivePrice for how a caller proves membership.
	whitelistMerkleRoot string

	// mintedIDs is an append-only record of every token minted here, in
	// mint order.
	mintedIDs []grc721.TokenID

	// mintedTraitCombos is the PERMANENT (well -- see Burn) record of
	// which exact trait combinations have been minted, moved here from
	// the version realm so uniqueness history survives any future
	// version redeploy. Reserved by RecordMint, released by Burn.
	mintedTraitCombos avl.Tree // combo key -> true

	// tokenComboKeys remembers which comboKey RecordMint reserved for
	// each token, so Burn can release the EXACT same key -- comboKey is
	// an opaque string built by whichever version realm minted the
	// token (from its own raw trait indices, not anything stable can
	// reconstruct from display metadata), so it has to be stored
	// verbatim rather than recomputed.
	tokenComboKeys avl.Tree // tid.String() -> comboKey string

	// mintCountByWallet tracks mints per recipient, moved here for the
	// same reason -- a version swap must not reset anyone's cap usage.
	mintCountByWallet avl.Tree // address.String() -> int64

	// mintingOpenMirror/maxMintsPerWalletMirror are DISPLAY-ONLY copies
	// of settings the approved version realm actually enforces -- gno
	// doesn't allow circular imports, so stable (which v1 imports)
	// cannot import v1 back to read its live mintingOpen/
	// maxMintsPerWallet directly. The version realm calls
	// ReportMintingOpen/ReportMaxMintsPerWallet (version-gated, same
	// pattern as RecordMint) whenever it changes them, purely so
	// Render() here can show accurate values without a circular
	// dependency.
	mintingOpenMirror       = true
	maxMintsPerWalletMirror int64 = 3

	// burnedRecords/burnedIDs are a permanent record of every token
	// this realm has ever burned.
	burnedRecords avl.Tree // tid.String() -> burnRecord
	burnedIDs     []grc721.TokenID
)

// traitPreset mirrors the version realm's own traitPreset field-for-
// field -- needed here only to reconstruct a burned token's display
// metadata on demand (see burnRecordMetadata), the same trick the
// original single-realm design used to avoid storing a second copy of
// the rendered image.
type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
}

// burnRecord is a permanent snapshot of one burned token.
type burnRecord struct {
	BurnedBy   address
	BurnHeight int64
	Metadata   grc721.Metadata
}

func init(cur realm) {
	nft = grc721.NewNFTWithMetadata(0, cur, CollectionName, CollectionSymbol)
}

/* ------------------------------ standard reads ------------------------------ */

func Name() string      { return CollectionName }
func Symbol() string    { return CollectionSymbol }
func TokenCount() int64 { return nft.TokenCount() }

func OwnerOf(tid grc721.TokenID) (address, error)      { return nft.OwnerOf(tid) }
func BalanceOf(owner address) (int64, error)           { return nft.BalanceOf(owner) }
func TokenMetadata(tid grc721.TokenID) (grc721.Metadata, error) { return nft.TokenMetadata(tid) }
func TokenURI(tid grc721.TokenID) (string, error)       { return nft.TokenURI(tid) }
func GetApproved(tid grc721.TokenID) (address, error)   { return nft.GetApproved(tid) }
func IsApprovedForAll(owner, operator address) bool     { return nft.IsApprovedForAll(owner, operator) }

func ApprovedVersion() string { return approvedVersion }
func Owner() address          { return collectionOwner }
func MintPrice() int64        { return mintPriceUgnot }

func MintedIDs() []grc721.TokenID { return mintedIDs }
func TotalBurned() int64          { return int64(len(burnedIDs)) }

func MintingOpen() bool         { return mintingOpenMirror }
func MaxMintsPerWallet() int64  { return maxMintsPerWalletMirror }

func MintsByWallet(owner address) int64 {
	n, _ := mintCountByWallet.Get(owner.String()).(int64)
	return n
}

func IsTraitComboAvailable(comboKey string) bool {
	return !mintedTraitCombos.Has(comboKey)
}

// WhitelistBps reports wallet's individual price override in basis
// points, and whether it has one (ok == false means: no individual
// override -- check the Merkle allowlist or pay standard price).
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

func WhitelistMerkleRoot() string { return whitelistMerkleRoot }

// sha256hex is the leaf/node hash used throughout: sha256, hex-encoded
// lowercase -- matches the off-chain proof-generation script exactly,
// byte for byte, or verification silently never matches.
func sha256hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// verifyMerkleProof reconstructs the root from leaf + proof (sibling
// hashes, bottom to top) and compares it to root. Pairs are combined in
// SORTED order at each step (min then max, lexicographic on the hex
// string) -- this is the standard OpenZeppelin-style convention
// specifically so neither side needs to track left/right position,
// only the set of sibling hashes, which keeps the off-chain proof
// format (and this function) simple.
func verifyMerkleProof(leaf string, proof []string, root string) bool {
	computed := leaf
	for _, sibling := range proof {
		if computed <= sibling {
			computed = sha256hex(computed + sibling)
		} else {
			computed = sha256hex(sibling + computed)
		}
	}
	return computed == root
}

// EffectivePrice returns what caller actually owes for a mint right
// now. Checks, in order: (1) an individual whitelistBps override, (2)
// a valid Merkle proof for the claimed bps against whitelistMerkleRoot,
// (3) the standard mintPriceUgnot. claimedBps/proofCSV are caller-
// supplied and UNTRUSTED on their own -- only trusted once the Merkle
// proof actually verifies against the on-chain root, so a caller with
// no real proof simply falls through to standard pricing regardless of
// what they claim. proofCSV is comma-separated sibling hashes (a flat
// string, not a []string arg -- gno.land's MsgCall args are plain
// strings; this matches the same comma-joined convention
// AddToWhitelistBatch already uses).
func EffectivePrice(caller address, claimedBps int64, proofCSV string) int64 {
	if v, ok := whitelistBps.Get(caller.String()).(int64); ok {
		return mintPriceUgnot * v / 10000
	}
	if whitelistMerkleRoot != "" && claimedBps >= 0 && claimedBps <= 10000 && proofCSV != "" {
		leaf := sha256hex(caller.String() + "|" + strconv.FormatInt(claimedBps, 10))
		proof := strings.Split(proofCSV, ",")
		if verifyMerkleProof(leaf, proof, whitelistMerkleRoot) {
			return mintPriceUgnot * claimedBps / 10000
		}
	}
	return mintPriceUgnot
}

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

// SetWhitelistMerkleRoot activates (or clears, with "") a Merkle-proof
// allowlist. Owner-only. The real (address, bps) list and every proof
// are generated off-chain (see the project's whitelist-tools script)
// and published as a static file next to the mint page -- only this
// one root hash ever touches chain state, regardless of list size.
func SetWhitelistMerkleRoot(cur realm, root string) {
	assertOwner()
	whitelistMerkleRoot = root
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

// RecordMint is the ONLY way a token gets minted. Only the approved
// version realm may call it. Reserves comboKey atomically with the
// mint (panics if already taken -- the version realm should have
// pre-checked via IsTraitComboAvailable, but this is the real,
// authoritative check) and increments the recipient's mint count.
func RecordMint(cur realm, to address, tid grc721.TokenID, metadata grc721.Metadata, comboKey string) grc721.TokenID {
	assertCallerIsApprovedVersion(cur)
	if mintedTraitCombos.Has(comboKey) {
		panic("trait combination already minted")
	}
	checkErr(nft.Mint(to, tid))
	checkErr(nft.SetTokenMetadata(to, tid, metadata))
	mintedTraitCombos.Set(comboKey, true)
	tokenComboKeys.Set(tid.String(), comboKey)
	mintCountByWallet.Set(to.String(), MintsByWallet(to)+1)
	mintedIDs = append(mintedIDs, tid)
	return tid
}

// ReportMintingOpen/ReportMaxMintsPerWallet let the approved version
// realm mirror its own live settings here for display only -- see
// mintingOpenMirror's own doc comment for why this exists instead of a
// direct cross-realm read.
func ReportMintingOpen(cur realm, open bool) {
	assertCallerIsApprovedVersion(cur)
	mintingOpenMirror = open
}

func ReportMaxMintsPerWallet(cur realm, max int64) {
	assertCallerIsApprovedVersion(cur)
	maxMintsPerWalletMirror = max
}

/* -------------------------- Token-owner actions --------------------------- */

func Approve(cur realm, to address, tid grc721.TokenID) {
	checkErr(nft.Approve(callerAddress(), to, tid))
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	checkErr(nft.SetApprovalForAll(callerAddress(), operator, approved))
}

func TransferFrom(cur realm, from, to address, tid grc721.TokenID) {
	checkErr(nft.TransferFrom(callerAddress(), from, to, tid))
}

func SafeTransferFrom(cur realm, from, to address, tid grc721.TokenID) {
	checkErr(nft.SafeTransferFrom(callerAddress(), from, to, tid))
}

// Burn destroys a token. Caller must be its current owner. RELEASES the
// token's trait combination back into mintedTraitCombos (deliberate,
// per request 2026-09-14: a destroyed piece's combination becomes
// mintable again), looked up from tokenComboKeys (the exact key
// RecordMint reserved, not a reconstruction -- see that field's own
// comment on why it has to be stored verbatim). Combined with nft.Burn
// itself freeing the token's owner/metadata storage, this frees the
// maximum real bytes possible, which maximizes the automatic storage-
// deposit refund gno's own runtime sends back to whoever calls Burn
// (see lockStorageDeposit's real counterpart, refundStorageDeposit, in
// gno's own VM keeper -- no custom refund logic needed here, freeing
// bytes IS the refund mechanism).
func Burn(cur realm, tid grc721.TokenID) {
	caller := callerAddress()
	owner, err := nft.OwnerOf(tid)
	checkErr(err)
	if caller != owner {
		panic(grc721.ErrCallerIsNotOwner)
	}
	metadata, err := nft.TokenMetadata(tid)
	checkErr(err)

	key := tid.String()
	if comboKey, ok := tokenComboKeys.Get(key).(string); ok {
		mintedTraitCombos.Remove(comboKey)
		tokenComboKeys.Remove(key)
	}

	checkErr(nft.Burn(tid))

	burnedRecords.Set(key, burnRecord{
		BurnedBy:   caller,
		BurnHeight: runtime.ChainHeight(),
		Metadata:   metadata,
	})
	burnedIDs = append(burnedIDs, tid)
}

/* ------------------------------ gnoweb display ------------------------------ */

func traitsToCSV(attrs []grc721.Trait) string {
	pairs := make([]string, len(attrs))
	for i, a := range attrs {
		pairs[i] = a.TraitType + "=" + a.Value
	}
	return strings.Join(pairs, ";")
}

// TokenSummary returns tid, its current owner, and its metadata as one
// pipe-delimited line, each value base64-encoded -- same shape the
// original single-realm design used, for any off-chain UI that wants a
// gallery view without decoding Gno's own struct value syntax.
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

// CollectionSummary returns one TokenSummary line per token on the
// given page (1-indexed, newest first, homeRenderLimit per page --
// same page size Render's own listing uses), newline-separated.
// Paginated because an unbounded version runs out of gas past a few
// dozen tokens (confirmed live in the original single-realm design at
// ~21 tokens) -- each summary re-embeds a full rendered image.
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
		tid := mintedIDs[total-1-k]
		line, err := TokenSummary(tid)
		if err != nil {
			continue // burned since minting
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

const walletScanChunk = 100

// WalletSummary is CollectionSummary filtered to owner, scanning at
// most walletScanChunk of mintedIDs starting at startIdx. Returns the
// matching lines plus nextIdx to resume from; nextIdx == TokenCount()
// once nothing is left to check.
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
		tid := mintedIDs[total-1-k]
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

// BurnedTokenSummary returns a permanent snapshot of one burned token,
// same line shape as TokenSummary, with owner swapped for
// burnedBy/burnHeight.
func BurnedTokenSummary(tid grc721.TokenID) (string, error) {
	raw := burnedRecords.Get(tid.String())
	rec, ok := raw.(burnRecord)
	if !ok {
		return "", grc721.ErrInvalidTokenId
	}
	enc := base64.StdEncoding
	fields := []string{
		tid.String(),
		rec.BurnedBy.String(),
		ufmt.Sprintf("%d", rec.BurnHeight),
		enc.EncodeToString([]byte(rec.Metadata.Name)),
		enc.EncodeToString([]byte(rec.Metadata.Description)),
		enc.EncodeToString([]byte(rec.Metadata.Image)),
		enc.EncodeToString([]byte(rec.Metadata.ExternalURL)),
		enc.EncodeToString([]byte(traitsToCSV(rec.Metadata.Attributes))),
		enc.EncodeToString([]byte(rec.Metadata.BackgroundColor)),
	}
	return strings.Join(fields, "|"), nil
}

// bigTokenImage scales up image's declared width/height for display on
// its own token page -- the viewBox (and therefore every internal
// coordinate) is untouched, so the browser just renders the same piece
// bigger, nothing is re-rendered.
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
		b.WriteString(ufmt.Sprintf("_page %d of %d -- %d minted total_\n\n", page, totalPages, total))
	}
	b.WriteString("| Image | Index | Name | Owner |\n|---|---|---|---|\n")
	for k := startK; k < endK; k++ {
		tid := mintedIDs[total-1-k]
		owner, err := nft.OwnerOf(tid)
		if err != nil {
			continue // burned
		}
		metadata, _ := nft.TokenMetadata(tid)
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
		b.WriteString(ufmt.Sprintf("_page %d of %d -- %d burned total_\n\n", page, totalPages, total))
	}
	b.WriteString("| Image | Index | Name | Burned By | Block |\n|---|---|---|---|---|\n")
	for k := startK; k < endK; k++ {
		tid := burnedIDs[total-1-k]
		raw := burnedRecords.Get(tid.String())
		rec, ok := raw.(burnRecord)
		if !ok {
			continue
		}
		name := rec.Metadata.Name
		if name == "" {
			name = "Untitled"
		}
		image := rec.Metadata.Image
		if image == "" {
			image = rec.Metadata.ImageData
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

func render404() string {
	return ufmt.Sprintf("# 404\n\n[<- back to collection](%s)\n", realmRelPath)
}

func Render(path string) string {
	if path == "" {
		var b strings.Builder
		b.WriteString(nft.RenderHome())
		b.WriteString("\n## About\n\n")
		b.WriteString("Each Gem's Chain trait names a real gno.land testnet -- one of the generations that carried the network forward on its way to Mainnet. Set in a ring with its own small antigravity field, every piece is a keepsake for everyone who helped build, test, and grow gno.land into what it's becoming.\n\n")
		b.WriteString("This collection is also a demonstration: every gem is generative art, assembled fresh on each read and stored entirely on-chain -- no external links, nothing that can go missing.\n\n")
		b.WriteString(ufmt.Sprintf("* **Owner**: %s\n", Owner()))
		b.WriteString(ufmt.Sprintf("* **Assembled trait combinations minted**: %d\n", int64(mintedTraitCombos.Size())))
		b.WriteString("* **Max supply**: unlimited\n")
		if mintingOpenMirror {
			b.WriteString("* **Minting**: open\n")
		} else {
			b.WriteString("* **Minting**: closed\n")
		}
		if mintPriceUgnot > 0 {
			b.WriteString(ufmt.Sprintf("* **Mint price**: %d ugnot\n", mintPriceUgnot))
		} else {
			b.WriteString("* **Mint price**: free\n")
		}
		if maxMintsPerWalletMirror > 0 {
			b.WriteString(ufmt.Sprintf("* **Max mints per wallet**: %d\n", maxMintsPerWalletMirror))
		} else {
			b.WriteString("* **Max mints per wallet**: unlimited\n")
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
		b.WriteString(ufmt.Sprintf("# %s -- minted tokens\n\n[<- back to collection](%s)\n", nft.Name(), realmRelPath))
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
		b.WriteString(ufmt.Sprintf("# %s -- burned tokens\n\n[<- back to collection](%s)\n", nft.Name(), realmRelPath))
		renderBurnedListPage(&b, page)
		return b.String()
	}
	if len(parts) == 2 && parts[0] == "token" {
		tid := grc721.TokenID(parts[1])
		owner, err := nft.OwnerOf(tid)
		if err != nil {
			return render404()
		}
		metadata, _ := nft.TokenMetadata(tid)
		var b strings.Builder
		b.WriteString(ufmt.Sprintf("# %s #%s\n\n[<- back to collection](%s)\n\n", nft.Name(), tid.String(), realmRelPath))
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
