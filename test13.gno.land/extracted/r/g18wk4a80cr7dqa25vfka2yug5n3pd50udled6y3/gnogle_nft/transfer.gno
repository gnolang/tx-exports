package gnogle_nft

import (
	"chain"
	"strconv"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
	"gno.land/p/nt/avl/v0"
)

// operators holds realm-wide operator approvals: "owner:operator" -> bool.
// One approval covers ALL of the owner's tokens across ALL collections — so a
// user enables a marketplace once. The marketplace realm is just an operator.
var operators avl.Tree

func opKey(owner, operator address) string { return owner.String() + ":" + operator.String() }

// SetApprovalForAll grants/revokes an operator (e.g. a marketplace realm) the
// right to transfer all of the caller's tokens. This is how a user "enables
// trading" with a marketplace — and how upgrading the market stays NFT-safe:
// the new market is just a new operator to approve; tokens never move realms.
func SetApprovalForAll(cur realm, operator address, approved bool) {
	owner := cur.Previous().Address()
	if !operator.IsValid() {
		panic("invalid operator address")
	}
	operators.Set(opKey(owner, operator), approved)
	chain.Emit("ApprovalForAll", "owner", owner.String(), "operator", operator.String(),
		"approved", strconv.FormatBool(approved))
}

// IsApprovedForAll reports whether operator may move all of owner's tokens.
func IsApprovedForAll(owner, operator address) bool {
	v, ok := operators.Get(opKey(owner, operator))
	return ok && v.(bool)
}

// TransferFrom moves a token from `from` to `to`. The caller
// (cur.Previous().Address()) must be the owner OR an approved operator. This is
// the single entry point the marketplace realm uses to settle trades.
func TransferFrom(cur realm, collID string, from, to address, tokenID string) {
	caller := cur.Previous().Address()
	coll := mustGetCollection(collID)
	tid := grc721.TokenID(tokenID)

	owner, err := coll.nft.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	if owner != from {
		panic("from is not the current owner")
	}
	if caller != from && !IsApprovedForAll(from, caller) {
		panic("caller is not the owner or an approved operator")
	}

	// Authorized at the realm level; call grc721 with caller=owner so its own
	// ownership check passes.
	if err := coll.nft.TransferFrom(from, from, to, tid); err != nil {
		panic(err)
	}
	chain.Emit("Transfer", "collection", collID, "tokenId", tokenID,
		"from", from.String(), "to", to.String())
}
