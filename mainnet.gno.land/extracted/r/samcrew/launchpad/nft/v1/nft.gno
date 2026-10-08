// Package nft is the Launchpad collection ledger. Each collection is a GRC721
// token whose transfer mode, royalties and metadata rules are fixed at
// creation. Collections are created, and their tokens minted, only by issuer
// realms: the Launchpad drops realm and any realm the config admin adds.
// Holders move, approve and burn their own tokens. The ledger has no admin of
// its own: nothing here can move a holder's token or change a collection's
// terms, and a paused lane stops only new collections and new mints.
package nft

import (
	"chain"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/samcrew/launchpad/currency/v1"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/samcrew/launchpad/config/v1"
)

const (
	dropsPath            = "gno.land/r/samcrew/launchpad/drops/v1"
	marketPath           = "gno.land/r/samcrew/launchpad/market/v1"
	ModeOpen             = "open"
	ModeRoyaltyProtected = "royalty_protected"
	ModeSoulbound        = "soulbound"
	StatusActive         = "active"
	StatusBurned         = "burned"
	StatusRevoked        = "revoked"
)

// Info is a collection's public record. The creator may edit the profile
// fields until FreezeProfile, hand the creator role over and seal the supply;
// everything else is immutable.
type Info struct {
	ID             string // "C<n>"
	GRC721ID       string
	Issuer         address // the only realm that mints into the collection
	Creator        address
	Originator     address // the creator at creation, whoever holds the role now
	PendingCreator address
	Name           string
	Symbol         string
	Description    string
	Image          string
	Banner         string
	Website        string
	Mode           string
	Revocable      bool  // soulbound only: the creator may revoke a token
	MaxSupply      int64 // zero means an uncapped open edition
	Sealed         bool  // no token can ever be minted again
	Minted         int64 // includes retired tokens; numbers are never reused
	ProfileFrozen  bool
}

type collection struct {
	key        string // tree key: fixed width, in creation order
	info       Info
	token      *grc721.Token
	ledger     *grc721.PrivateLedger
	metadata   metadata
	traitsRoot string    // Merkle root of the token traits, set once
	royalties  []royalty // at most maxRoyaltyReceivers
	royaltyBPS int64
	markets    []address // royalty-protected only, at most maxMarkets
	retired    avl.Tree  // token number -> StatusBurned | StatusRevoked
}

var (
	lastID      seqid.ID
	collections avl.Tree // collection key -> *collection
	holdings    avl.Tree // owner -> *avl.Tree of "<collection key>/<number key>" -> custody ID
	lastCustody seqid.ID // the last custody ID given
)

// isIssuer reports whether a realm may create collections and mint into its
// own: the drops realm always, and every realm on config's add-only list.
func isIssuer(who address) bool {
	return who == chain.PackageAddress(dropsPath) || config.IsIssuer(config.LedgerNFT, who)
}

// gate stops a new collection or a new mint while its lane is paused, so the
// pauser is a brake on every issuer config may add, whatever that issuer
// checks. The drops realm is not asked twice: it applies the same gate itself,
// with the currency it charges, before it calls here.
func gate(issuer address, lane string) {
	if issuer != chain.PackageAddress(dropsPath) && config.IsPaused(lane) {
		panic("launchpad/nft: lane paused")
	}
}

// callingRealm returns the realm that called; a wallet is refused.
func callingRealm(cur realm) address {
	if !cur.IsCurrent() || cur.Previous().IsUserCall() {
		panic("launchpad/nft: issuer realm only")
	}
	return cur.Previous().Address()
}

// actor returns the immediate caller. Coins a wallet attaches to a direct call
// would stay in this realm, so they are refused; a calling realm keeps whatever
// its own caller sent.
func actor(cur realm) address {
	if !cur.IsCurrent() {
		panic("launchpad/nft: stale realm context")
	}
	if cur.Previous().IsUserCall() {
		currency.AssertNoCoins(0, cur)
	}
	return cur.Previous().Address()
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}

func checkProfile(description, image, banner, website string) {
	check(meta.Description(description))
	check(meta.Image(image))
	check(meta.Image(banner))
	check(meta.Website(website))
}

func mustCollection(id string) *collection {
	if len(id) >= 2 && len(id) <= 21 && id[0] == 'C' && id[1] != '0' {
		if n, err := strconv.ParseUint(id[1:], 10, 64); err == nil {
			if c := collections.Get(seqid.ID(n).String()); c != nil {
				return c.(*collection)
			}
		}
	}
	panic("launchpad/nft: unknown collection")
}

func tokenID(number int64) grc721.TokenID {
	if number <= 0 {
		panic("launchpad/nft: invalid token number")
	}
	return grc721.TokenID(strconv.FormatInt(number, 10))
}

func holdingKey(c *collection, number int64) string {
	return c.key + "/" + seqid.ID(number).String()
}

// hold and release keep the holdings index equal to ownership: one tree per
// owner, so a page of an account's tokens costs the same wherever it starts.
func hold(owner address, c *collection, number int64) {
	mine, _ := holdings.Get(owner.String()).(*avl.Tree)
	if mine == nil {
		mine = avl.NewTree()
		holdings.Set(owner.String(), mine)
	}
	mine.Set(holdingKey(c, number), int64(lastCustody.Next()))
}

// renew gives a held token a new custody ID, as a move does: a change of its
// single-token approval starts a new custody too.
func renew(owner address, c *collection, number int64) {
	holdings.Get(owner.String()).(*avl.Tree).Set(holdingKey(c, number), int64(lastCustody.Next()))
}

func release(owner address, c *collection, number int64) {
	mine := holdings.Get(owner.String()).(*avl.Tree)
	mine.Remove(holdingKey(c, number))
	if mine.Size() == 0 {
		holdings.Remove(owner.String())
	}
}

// Create registers a collection for a creator the calling issuer realm has
// authenticated and charged. The issuer is recorded on the collection and no
// other realm can mint into it. royalties is "address:bps;address:bps" with
// addresses in strictly ascending order, or empty; the metadata arguments are
// those of newMetadata.
func Create(cur realm, creator address, name, symbol, description, image,
	banner, website, mode string, revocable bool, maxSupply int64,
	metadataMode, baseURI, placeholderURI, commitment, provenance,
	royalties string) string {
	issuer := callingRealm(cur)
	if !isIssuer(issuer) {
		panic("launchpad/nft: issuer realm only")
	}
	gate(issuer, config.LaneCollection)
	if !meta.ValidAddress(creator) || maxSupply < 0 ||
		(mode != ModeOpen && mode != ModeRoyaltyProtected && mode != ModeSoulbound) ||
		(revocable && mode != ModeSoulbound) {
		panic("launchpad/nft: invalid collection terms")
	}
	check(meta.Name(name))
	check(meta.Ticker(symbol))
	if config.IsReserved(symbol) {
		panic("launchpad/nft: reserved symbol")
	}
	checkProfile(description, image, banner, website)
	c := &collection{metadata: newMetadata(metadataMode, baseURI, placeholderURI,
		commitment, provenance, creator)}
	c.royalties, c.royaltyBPS = parseRoyalties(royalties, mode)
	if mode == ModeRoyaltyProtected {
		c.markets = []address{chain.PackageAddress(marketPath)}
	}
	n := lastID.Next()
	id := "C" + strconv.FormatUint(uint64(n), 10)
	c.key = n.String()
	c.token, c.ledger = grc721.NewToken(name, symbol, n, cur)
	c.info = Info{
		ID: id, GRC721ID: c.token.ID(), Issuer: issuer, Creator: creator,
		Originator: creator, Name: name, Symbol: symbol, Description: description, Image: image,
		Banner: banner, Website: website, Mode: mode, Revocable: revocable,
		MaxSupply: maxSupply,
	}
	collections.Set(c.key, c)
	chain.Emit("CollectionCreated", "collection", id, "token", c.token.ID(),
		"issuer", issuer.String(), "creator", creator.String(),
		"name", name, "symbol", symbol, "mode", mode,
		"revocable", strconv.FormatBool(revocable),
		"max_supply", strconv.FormatInt(maxSupply, 10),
		"metadata", metadataMode, "base_uri", baseURI,
		"placeholder_uri", placeholderURI, "base_uri_commitment", commitment,
		"provenance", provenance, "royalties", royalties,
		"description", description, "image", image, "banner", banner,
		"website", website)
	return id
}

// MintTo issues the next token number. Only the collection's issuer calls it,
// after its own accounting of stages and payment. The ledger mints to whoever
// the issuer names: it is the issuer's duty to mint a soulbound token only to
// the wallet that asked for it.
func MintTo(cur realm, id string, recipient address) int64 {
	issuer := callingRealm(cur)
	c := mustCollection(id)
	if issuer != c.info.Issuer {
		panic("launchpad/nft: the collection's issuer only")
	}
	gate(issuer, config.LaneNFTDrops)
	if !meta.ValidAddress(recipient) || c.info.Sealed ||
		(c.info.MaxSupply > 0 && c.info.Minted >= c.info.MaxSupply) {
		panic("launchpad/nft: mint denied")
	}
	number := sm.Add(c.info.Minted, 1)
	check(c.ledger.Mint(recipient, tokenID(number)))
	c.info.Minted = number
	hold(recipient, c, number)
	return number
}

// operator reports whether who may be approved for, or move, a token of c.
// Soulbound tokens never move. A royalty-protected token moves only through a
// realm on the collection's market list. The ledger cannot make a realm pay:
// the creator who lists one vouches that it pays the collection's royalties.
func operator(c *collection, who address) bool {
	switch c.info.Mode {
	case ModeOpen:
		return true
	case ModeRoyaltyProtected:
		for _, market := range c.markets {
			if who == market {
				return true
			}
		}
	}
	return false
}

func denied(c *collection) {
	if c.info.Mode == ModeSoulbound {
		panic("launchpad/nft: soulbound tokens cannot move")
	}
	panic("launchpad/nft: royalty-protected tokens move only through an allowed market")
}

// TransferFrom moves a token when the collection's mode lets the caller move
// one, and the caller owns it or is approved for it.
func TransferFrom(cur realm, id string, from, to address, number int64) {
	who := actor(cur)
	c := mustCollection(id)
	if !operator(c, who) {
		denied(c)
	}
	if !meta.ValidAddress(to) {
		panic("launchpad/nft: invalid recipient")
	}
	check(c.ledger.TransferFrom(who, from, to, tokenID(number)))
	release(from, c, number)
	hold(to, c, number)
}

// Approve lets one account move one token; an empty address clears it. A
// soulbound token takes no approval at all, a royalty-protected one only a
// listed market.
func Approve(cur realm, id string, to address, number int64) {
	who := actor(cur)
	c := mustCollection(id)
	if c.info.Mode == ModeSoulbound || (to != "" && !operator(c, to)) {
		denied(c)
	}
	if to != "" && !meta.ValidAddress(to) {
		panic("launchpad/nft: invalid operator")
	}
	before := GetApproved(id, number)
	check(c.ledger.Approve(who, to, tokenID(number)))
	if to != before {
		renew(ownerOf(c, number), c, number)
	}
}

// SetApprovalForAll lets, or stops letting, one account move every token the
// caller holds in the collection.
func SetApprovalForAll(cur realm, id string, to address, approved bool) {
	who := actor(cur)
	c := mustCollection(id)
	if !operator(c, to) {
		denied(c)
	}
	if !meta.ValidAddress(to) {
		panic("launchpad/nft: invalid operator")
	}
	check(c.ledger.SetApprovalForAll(who, to, approved))
}

func ownerOf(c *collection, number int64) address {
	owner, err := c.token.OwnerOf(tokenID(number))
	check(err)
	return owner
}

func retire(c *collection, owner address, number int64, status string) {
	tid := tokenID(number)
	check(c.ledger.Burn(tid))
	c.retired.Set(tid.String(), status)
	release(owner, c, number)
}

// Burn is the holder's alone, in every mode. No creator, operator or admin
// can destroy a token somebody else holds, except through Revoke.
func Burn(cur realm, id string, number int64) {
	who := actor(cur)
	c := mustCollection(id)
	if who != ownerOf(c, number) {
		panic("launchpad/nft: holder only")
	}
	retire(c, who, number, StatusBurned)
}

// Revoke retires a credential. It exists only for soulbound collections
// created as revocable, a term every holder could read before claiming. A
// holder who burns first leaves a burned token, not a revoked one.
func Revoke(cur realm, id string, number int64, reason string) {
	c := creatorOf(cur, id)
	if c.info.Mode != ModeSoulbound || !c.info.Revocable {
		panic("launchpad/nft: not a revocable collection")
	}
	switch reason {
	case "expired", "fraud", "eligibility_lost", "issuer_error", "other":
	default:
		panic("launchpad/nft: invalid revocation reason")
	}
	holder := ownerOf(c, number)
	retire(c, holder, number, StatusRevoked)
	chain.Emit("Revoked", "collection", id,
		"number", strconv.FormatInt(number, 10), "holder", holder.String(),
		"reason", reason)
}

// creatorOf returns the collection when the caller is its creator.
func creatorOf(cur realm, id string) *collection {
	who := actor(cur)
	c := mustCollection(id)
	if who != c.info.Creator {
		panic("launchpad/nft: creator only")
	}
	return c
}

// ProposeCreator starts handing the creator role to another account. Nothing
// changes until that account accepts; an empty address withdraws the offer.
func ProposeCreator(cur realm, id string, next address) {
	c := creatorOf(cur, id)
	if next != "" && (!meta.ValidAddress(next) || next == c.info.Creator) {
		panic("launchpad/nft: invalid next creator")
	}
	c.info.PendingCreator = next
	chain.Emit("CreatorProposed", "collection", id, "next", next.String())
}

// AcceptCreator makes the caller the creator it was proposed as.
func AcceptCreator(cur realm, id string) {
	who := actor(cur)
	c := mustCollection(id)
	if c.info.PendingCreator == "" || who != c.info.PendingCreator {
		panic("launchpad/nft: proposed creator only")
	}
	c.info.Creator, c.info.PendingCreator = who, ""
	chain.Emit("CreatorChanged", "collection", id, "creator", who.String())
}

// SetIssuer moves the collection's minting to another issuer realm, for
// instance a later version of the one that created it. Only the creator can
// choose it, and only among realms allowed to issue.
func SetIssuer(cur realm, id, pkgPath string) {
	c := creatorOf(cur, id)
	if len(pkgPath) < 12 || len(pkgPath) > 200 || pkgPath[:11] != "gno.land/r/" {
		panic("launchpad/nft: invalid issuer")
	}
	next := chain.PackageAddress(pkgPath)
	if !isIssuer(next) || next == c.info.Issuer {
		panic("launchpad/nft: invalid issuer")
	}
	c.info.Issuer = next
	chain.Emit("IssuerChanged", "collection", id, "issuer", next.String(),
		"path", pkgPath)
}

// SealSupply ends minting for good, whatever the cap was.
func SealSupply(cur realm, id string) {
	c := creatorOf(cur, id)
	if c.info.Sealed {
		panic("launchpad/nft: supply already sealed")
	}
	c.info.Sealed = true
	chain.Emit("SupplySealed", "collection", id,
		"minted", strconv.FormatInt(c.info.Minted, 10))
}

func profileOwner(cur realm, id string) *collection {
	c := creatorOf(cur, id)
	if c.info.ProfileFrozen {
		panic("launchpad/nft: profile frozen")
	}
	return c
}

func SetProfile(cur realm, id, description, image, banner, website string) {
	c := profileOwner(cur, id)
	checkProfile(description, image, banner, website)
	c.info.Description, c.info.Image = description, image
	c.info.Banner, c.info.Website = banner, website
	chain.Emit("ProfileChanged", "collection", id, "description", description,
		"image", image, "banner", banner, "website", website)
}

func FreezeProfile(cur realm, id string) {
	profileOwner(cur, id).info.ProfileFrozen = true
	chain.Emit("ProfileFrozen", "collection", id)
}

func GetInfo(id string) Info { return mustCollection(id).info }
func Count() int64           { return int64(collections.Size()) }

func BalanceOf(id string, owner address) int64 {
	if !meta.ValidAddress(owner) {
		panic("launchpad/nft: invalid owner")
	}
	n, err := mustCollection(id).token.BalanceOf(owner)
	check(err)
	return n
}

func OwnerOf(id string, number int64) address { return ownerOf(mustCollection(id), number) }

func TotalSupply(id string) int64 { return mustCollection(id).token.TotalSupply() }

// GetApproved returns the empty address when nobody is approved.
func GetApproved(id string, number int64) address {
	a, err := mustCollection(id).token.GetApproved(tokenID(number))
	if err == grc721.ErrTokenIdNotApproved {
		return ""
	}
	check(err)
	return a
}

func IsApprovedForAll(id string, owner, operator address) bool {
	if !meta.ValidAddress(owner) {
		panic("launchpad/nft: invalid owner")
	}
	if !meta.ValidAddress(operator) {
		panic("launchpad/nft: invalid operator")
	}
	return mustCollection(id).token.IsApprovedForAll(owner, operator)
}

func statusOf(c *collection, number int64) string {
	if number <= 0 || number > c.info.Minted {
		panic("launchpad/nft: invalid token number")
	}
	if status := c.retired.Get(strconv.FormatInt(number, 10)); status != nil {
		return status.(string)
	}
	return StatusActive
}

// Epoch returns the ID of a token's current custody: a new one at every move
// and every change of its single-token approval (the same approval again
// changes nothing), never one given before; 0 for a retired token. A market
// binds an order to it, so the order dies with the custody it was made under.
func Epoch(id string, number int64) int64 {
	c := mustCollection(id)
	if statusOf(c, number) != StatusActive {
		return 0
	}
	return holdings.Get(ownerOf(c, number).String()).(*avl.Tree).Get(holdingKey(c, number)).(int64)
}

func StatusOf(id string, number int64) string { return statusOf(mustCollection(id), number) }

// TokenURI answers for every minted number, retired or not: the metadata of a
// burned token is still part of the collection's public record.
func TokenURI(id string, number int64) string {
	c := mustCollection(id)
	statusOf(c, number)
	return c.metadata.tokenURI(number)
}

func Render(path string) string {
	if path == "" {
		return "# Launchpad NFT collections\n\n" +
			strconv.Itoa(collections.Size()) + " collections.\n"
	}
	c := mustCollection(path)
	return "# " + meta.EscapeMarkdown(c.info.Name) + "\n\n" +
		"Mode: " + c.info.Mode + "\n\n" +
		"Minted: " + strconv.FormatInt(c.info.Minted, 10) + "\n"
}
