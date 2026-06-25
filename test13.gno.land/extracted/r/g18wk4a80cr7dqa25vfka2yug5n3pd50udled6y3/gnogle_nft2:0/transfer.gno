package gnogle_nft2

import (
	"chain"
	"strconv"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
	"gno.land/p/nt/avl/v0"
)

// tokenApprovals is the recommended, granular approval: a user approves an
// operator (e.g. the marketplace) for ONE specific token — the one they want to
// sell — not all of them. Key "collID/tokenID" -> approved operator address.
var tokenApprovals avl.Tree

// operators is the optional "approve for all" map ("owner:operator" -> bool).
// Kept for ERC721 completeness, but the front-end defaults to per-token Approve.
var operators avl.Tree

func tokKey(collID, tokenID string) string  { return collID + "/" + tokenID }
func opKey(owner, operator address) string  { return owner.String() + ":" + operator.String() }

// Approve grants `operator` permission to transfer ONE token. The caller must
// own that token (or be an approve-for-all operator). Pass the zero address to
// revoke. The approval is cleared automatically when the token is transferred.
func Approve(cur realm, collID, tokenID string, operator address) {
	coll := mustGetCollection(collID)
	tid := grc721.TokenID(tokenID)
	owner, err := coll.nft.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	caller := cur.Previous().Address()
	if caller != owner && !IsApprovedForAll(owner, caller) {
		panic("only the owner (or an approved operator) can approve this token")
	}
	if operator == zeroAddr {
		tokenApprovals.Remove(tokKey(collID, tokenID))
	} else {
		tokenApprovals.Set(tokKey(collID, tokenID), operator)
	}
	chain.Emit("Approval", "collection", collID, "tokenId", tokenID,
		"owner", owner.String(), "approved", operator.String())
}

// GetApproved returns the operator approved for a single token (or the zero
// address if none).
func GetApproved(collID, tokenID string) address {
	v, ok := tokenApprovals.Get(tokKey(collID, tokenID))
	if !ok {
		return zeroAddr
	}
	return v.(address)
}

// SetApprovalForAll grants/revokes an operator for ALL of the caller's tokens.
// Optional power-user convenience — the recommended flow is per-token Approve.
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

// isAuthorized reports whether `operator` may transfer (collID,tokenID) owned by
// `owner`: the owner, the per-token approved operator, or an approve-for-all
// operator.
func isAuthorized(owner, operator address, collID, tokenID string) bool {
	return operator == owner ||
		GetApproved(collID, tokenID) == operator ||
		IsApprovedForAll(owner, operator)
}

// TransferFrom moves a token from `from` to `to`. The caller must be the owner,
// the per-token approved operator, or an approve-for-all operator. The per-token
// approval is cleared on transfer (so it never carries to the new owner).
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
	if !isAuthorized(from, caller, collID, tokenID) {
		panic("caller is not the owner or an approved operator")
	}
	if err := coll.nft.TransferFrom(from, from, to, tid); err != nil {
		panic(err)
	}
	tokenApprovals.Remove(tokKey(collID, tokenID))
	chain.Emit("Transfer", "collection", collID, "tokenId", tokenID,
		"from", from.String(), "to", to.String())
}
