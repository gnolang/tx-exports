// Package nsskin holds purchasable card art — the skins — as tokens of
// their own, and binds them to names.
//
// WHY THIS IS ITS OWN REALM AND NOT PART OF nsdata. SKINS.md §8 listed
// it as undecided; it is decided here, because the reasoning turned out
// to be one-sided rather than balanced.
//
//	nsdata IS PERMANENT. It cannot be replaced, ever. A second kind of
//	token in it means every mistake in the skin model is permanent too,
//	and the skin model is the newest and least settled thing here.
//
//	nsdata.OwnerOf DELIBERATELY PANICS FOR EXPIRED TOKENS so a lapsed
//	name cannot be listed anywhere. Skins do not expire. That machinery
//	is exactly wrong for them, and a conditional on token kind inside
//	the one realm that can never be fixed is the worst place for it.
//
//	A NEW REALM CAN BE REPLACED while it holds a handful of tokens. The
//	vault cannot, at any point, for any reason.
//
// So being wrong here costs a migration nobody notices. Being wrong
// inside nsdata costs forever.
//
// # A SKIN IS TWO THINGS
//
//	A DEFINITION is the artwork: a name, a sprite, an optional extension
//	lock, and the artist to pay. One per design, stored once — a
//	thousand holders of one design cost one sprite, not a thousand.
//
//	A TOKEN is somebody's copy. Editions are unlimited, because SKINS.md
//	is explicit that a cap is a floor price with extra steps and resale
//	value is never part of the pitch.
//
// # A SKIN BINDS TO ONE NAME, AND TRAVELS WITH IT
//
// This reverses an earlier recommendation of mine, and the new answer is
// better. I had argued for keeping them separate — a pointer from the
// name, reverting on sale — because names expire and skins should not.
// The objection to bundling was that a buyer sees a skinned card on a
// marketplace and receives an unskinned name.
//
// Binding solves that rather than working around it. The skin genuinely
// comes with the name, so the card is not misleading, and the small
// disclosure line the old model needed inside the artwork disappears.
// And a skin still does not die with a name: when the name goes, the
// skin comes back.
//
// # WHY ATTACHING ESCROWS THE TOKEN, WHICH IS THE WHOLE CUSTODY ANSWER
//
// The worry: a name listed on a marketplace that takes CUSTODY. If the
// skin lived in the seller's wallet, a custodial listing would hold the
// name while the skin sat somewhere else, and untangling that on expiry
// would need cooperation we cannot compel.
//
// So attaching moves the token to THIS REALM'S OWN ADDRESS. While
// attached it is in nobody's wallet: it cannot be listed, cannot be sold
// out from under the name, and a marketplace escrowing the NAME never
// touches it. The question of freeing a skin from somebody else's
// custody does not arise, because it was never in it.
//
// Taking it out again is one rule with one fallback:
//
//	WHILE THE NAME EXISTS, its CURRENT OWNER may claim the skin. That is
//	what makes it travel: buy the name, claim the skin.
//
//	IF THE NAME RECORD IS GONE — lapsed and reclaimed — whoever attached
//	it may take it back, which is the "it returns to your wallet" case.
//
// One limitation, stated rather than hidden: buy a name with a skin,
// never claim it, and let that name lapse completely, and the skin
// returns to whoever attached it. Claiming on purchase avoids it
// entirely, and the site prompts for exactly that.
package nsskin

import (
	"gno.land/p/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/grc721"
	"gno.land/p/nt/avl/v0"
)

type skin struct {
	name   string // as the shop shows it
	art    string // the sprite string, in the format nsview parses
	lock   string // an extension label, or "" for one that goes anywhere
	artist address
	// WITHDRAWN IS NOT DELETED, and the distinction is the whole
	// takedown mechanism (SKINS.md §6). Deleting a definition orphans
	// every token pointing at it. Withdrawing leaves everything in place
	// and stops it drawing — every name wearing it reverts at once, with
	// no migration and no per-name cleanup, because the card is
	// generated on every read.
	withdrawn bool
	minted    int64 // how many copies exist, and the next serial
}

// A live attachment. `registered` pins it to one REGISTRATION of the
// name, not to the label: if the name lapses and somebody else takes it,
// the timestamp changes and this binding is stale, so the new registrant
// inherits nothing.
type binding struct {
	label      string
	domain     string
	registered int64
	binder     address // who attached it, and who gets it back if the name dies
}

var (
	// Constructed in init, which is where it can be handed the realm.
	nft   *grc721.BasicNFT
	skins = avl.NewTree() // definition id -> *skin

	// token id -> definition id. Derivable by splitting the token id,
	// but stored so a lookup is a tree read rather than string surgery
	// that has to agree with the minter forever.
	tokenSkin = avl.NewTree()

	bound     = avl.NewTree() // token id      -> *binding
	nameBound = avl.NewTree() // "domain*label" -> token id

	// Whichever realm renders a skin card. Same reasoning as nsdata's:
	// the art is the most cosmetic and most-likely-to-be-revised thing
	// here, so it must not be frozen into a token contract.
	tokenURIBase = "/r/demo/nsview:skin/"

	// Day-to-day authority: define, mint, withdraw. Deliberately a plain
	// address rather than the vault's timelocked governance — this realm
	// is replaceable, so it does not need machinery built for one that
	// is not.
	admin address

	// Realms allowed to mint on somebody's behalf, which is what a shop
	// is. Empty at first: the launch batch is minted by the admin.
	trustedShop = avl.NewTree()

	// What one costs, in ugnot. Zero until an admin sets it, so a
	// misconfigured deploy gives skins away rather than charging an
	// accidental amount — the failure that costs nobody money.
	price int64
)

const (
	maxSkinName = 40
	maxSkinArt  = 2048 // a 32x32 sprite is about 1,100 bytes
	maxSkinID   = 24   // appears in every token id and every binding
)
