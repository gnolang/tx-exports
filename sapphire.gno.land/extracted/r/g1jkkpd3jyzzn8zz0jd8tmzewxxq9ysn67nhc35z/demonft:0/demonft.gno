// Package demonft is a minimal GRC721-like collection realm used to
// demonstrate/exercise gnomarket's non-custodial trade flow end to end —
// including what happens to a listing when the underlying token moves
// *outside* the marketplace (a direct Transfer, a gift, a trade elsewhere).
// Nothing here is escrowed by the marketplace at any point, so a listing
// surviving an out-of-band transfer is expected, not a bug — see
// nftmarketv2's own PruneStale doc comment. Open mint, no rich metadata
// beyond what SetMetadata provides: keep those concerns in a real
// collection, not in this fixture.
package demonft

import (
	"encoding/base64"
	"errors"

	"gno.land/p/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/market"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/nftmarketv2"
)

var (
	owners            = avl.NewTree() // tid -> address
	tokenURIs         = avl.NewTree() // tid -> string (data: URI, OpenSea-style JSON metadata)
	tokenApprovals    = avl.NewTree() // tid -> address (single-token approval)
	operatorApprovals = avl.NewTree() // "owner|operator" -> bool (blanket approval)
)

const (
	collectionName   = "Demo NFT"
	collectionSymbol = "DEMO"
)

// Name, Symbol, and TokenCount are plain package-level functions (not
// methods on an internal object) specifically so a generic chain scanner —
// like gnomarket's own Collections/NFTs browser pages, or anyone else's —
// can call them directly via vm/qeval on this collection's own path,
// without needing to know an exported variable name to call a method on.
func Name() string      { return collectionName }
func Symbol() string    { return collectionSymbol }
func TokenCount() int64 { return int64(owners.Size()) }

var placeholderColors = []string{"steelblue", "seagreen", "indianred", "goldenrod", "mediumorchid", "darkslategray"}

// buildMetadataURI returns a self-contained data: URI JSON metadata blob
// (OpenSea metadata shape) whose image is itself an inline data: URI SVG —
// no network fetch needed to display it. Both are base64-encoded: a data:
// URI's payload must otherwise be percent-encoded for any character outside
// a narrow safe set, and this fixture has no URL-encoder handy, so base64
// sidesteps that entirely rather than risk producing an invalid URI.
func buildMetadataURI(tid, name string) string {
	sum := 0
	for _, b := range []byte(tid) {
		sum += int(b)
	}
	color := placeholderColors[sum%len(placeholderColors)]
	svg := ufmt.Sprintf(
		`<svg xmlns='http://www.w3.org/2000/svg' width='300' height='300'><rect width='300' height='300' fill='%s'/><text x='150' y='150' font-size='28' fill='white' text-anchor='middle' dy='.3em' font-family='sans-serif'>%s</text></svg>`,
		color, name,
	)
	image := "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
	metadata := ufmt.Sprintf(`{"name":"%s","description":"gnomarket demo collection","image":"%s"}`, name, image)
	return "data:application/json;base64," + base64.StdEncoding.EncodeToString([]byte(metadata))
}

// SetMetadata sets (or overwrites) tid's display name/image. Open to any
// caller — this is a test fixture, not a real collection's admin surface.
func SetMetadata(cur realm, tid, name string) {
	if !owners.Has(tid) {
		panic(errNoSuchToken.Error())
	}
	tokenURIs.Set(tid, buildMetadataURI(tid, name))
}

var (
	errNoSuchToken   = errors.New("no such token")
	errNotAuthorized = errors.New("caller is not the owner or an approved operator")
)

// Mint is an open, unrestricted mint — fine for a test fixture, never do
// this in a real collection.
func Mint(cur realm, to address, tid string) {
	if owners.Has(tid) {
		panic("token already exists: " + tid)
	}
	owners.Set(tid, to)
}

func OwnerOf(tid string) (address, error) {
	owner, ok := owners.Get(tid).(address)
	if !ok {
		return "", errNoSuchToken
	}
	return owner, nil
}

func TokenURI(tid string) (string, error) {
	if !owners.Has(tid) {
		return "", errNoSuchToken
	}
	uri, _ := tokenURIs.Get(tid).(string)
	return uri, nil
}

func operatorKey(owner, operator address) string {
	return owner.String() + "|" + operator.String()
}

// Approve grants `to` permission to transfer tid on the caller's behalf.
// Caller must be tid's current owner.
func Approve(cur realm, to address, tid string) {
	caller := cur.Previous().Address()
	owner, ok := owners.Get(tid).(address)
	if !ok {
		panic(errNoSuchToken.Error())
	}
	if caller != owner {
		panic(errNotAuthorized.Error())
	}
	tokenApprovals.Set(tid, to)
}

// GetApproved returns the address currently approved to move tid, or ""
// if none.
func GetApproved(tid string) (address, error) {
	if !owners.Has(tid) {
		return "", errNoSuchToken
	}
	approved, _ := tokenApprovals.Get(tid).(address)
	return approved, nil
}

// SetApprovalForAll grants or revokes blanket approval for operator over
// all of the caller's tokens in this collection — this is what a seller
// calls to approve the marketplace once, rather than approving each token
// individually.
func SetApprovalForAll(cur realm, operator address, approved bool) {
	caller := cur.Previous().Address()
	key := operatorKey(caller, operator)
	if approved {
		operatorApprovals.Set(key, true)
	} else {
		operatorApprovals.Remove(key)
	}
}

// IsApprovedForAll reports whether operator holds blanket approval over
// all of owner's tokens in this collection.
func IsApprovedForAll(owner, operator address) bool {
	return operatorApprovals.Has(operatorKey(owner, operator))
}

// transfer is the single internal authorization+mutation path shared by
// Transfer, TransferFrom, and the marketplace adapter below. Authorizes the
// caller if they're the token's current owner, hold a single-token
// approval for it, or hold blanket operator approval from the owner — this
// three-way check is what lets an approved third party (like a
// marketplace) move a token the owner never transferred to them. Clears
// any single-token approval on success, since it shouldn't carry over to
// a new owner.
func transfer(caller, from, to address, tid string) error {
	owner, ok := owners.Get(tid).(address)
	if !ok {
		return errNoSuchToken
	}
	if owner != from {
		return errNotAuthorized
	}
	approved, _ := tokenApprovals.Get(tid).(address)
	if caller != owner && caller != approved && !IsApprovedForAll(owner, caller) {
		return errNotAuthorized
	}
	owners.Set(tid, to)
	tokenApprovals.Remove(tid)
	return nil
}

// TransferFrom moves tid from `from` to `to`. Caller must be from's current
// owner, or an address from has approved via Approve or SetApprovalForAll
// — the standard entrypoint any approved third party (including the
// marketplace) uses.
func TransferFrom(cur realm, from, to address, tid string) {
	caller := cur.Previous().Address()
	if err := transfer(caller, from, to, tid); err != nil {
		panic(err.Error())
	}
}

// Transfer sends the caller's own token to `to`. Convenience sugar for
// TransferFrom where from is the caller themselves. This is the function
// used to simulate an out-of-band move (a trade/gift off this marketplace)
// that the marketplace's own listing state has no way to observe.
func Transfer(cur realm, to address, tid string) {
	caller := cur.Previous().Address()
	if err := transfer(caller, caller, to, tid); err != nil {
		panic(err.Error())
	}
}

// marketAdapter satisfies market.NFT on top of this collection's own ledger.
// TransferFrom derives its caller from cur.Previous() itself, per market.NFT's
// contract, rather than trusting an argument — see gno.land/p/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/market
// for why that's what makes it safe to hand to an untrusted marketplace realm:
// the marketplace can only ever move a token it has genuinely been approved
// for, exactly as this same authorization check would treat any other
// approved third party.
type marketAdapter struct{}

func (marketAdapter) Name() string                        { return Name() }
func (marketAdapter) OwnerOf(tid string) (address, error) { return OwnerOf(tid) }
func (marketAdapter) TokenURI(tid string) (string, error) { return TokenURI(tid) }
func (marketAdapter) GetApproved(tid string) (address, error) {
	return GetApproved(tid)
}
func (marketAdapter) IsApprovedForAll(owner, operator address) bool {
	return IsApprovedForAll(owner, operator)
}
func (marketAdapter) TransferFrom(cur realm, from, to address, tid string) error {
	caller := cur.Previous().Address()
	return transfer(caller, from, to, tid)
}

var _ market.NFT = marketAdapter{}

// RegisterWithMarketplace registers this collection with the gnomarket
// marketplace. Callable by anyone since it only ever hands over a value
// whose TransferFrom re-derives and re-checks the caller itself — the
// marketplace still can't move a token it hasn't genuinely been approved
// for, see market.NFT's doc comment.
func RegisterWithMarketplace(cur realm) string {
	return nftmarketv2.RegisterCollection(cross(cur), marketAdapter{})
}
