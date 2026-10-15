// Package grc721 is a minimal, self-contained GRC-721 (NFT) token registry
// with a built-in per-token/collection royalty extension — exactly the
// surface `realm/nft/nft.gno`'s `nftToken` interface depends on, no more.
//
// This is a from-scratch reimplementation, not a copy of gno.land's own
// `gno.land/p/demo/tokens/grc721` example package: that package was
// rewritten upstream into a much more general ledger+extension
// architecture (bps-based fees, pluggable extensions registered via
// `PrivateLedger.RegisterExtension`) that doesn't match the simpler,
// single-struct shape `nft.gno` was written against (percentage-based
// royalties, direct method calls, no extension registration step). Rather
// than rewrite `nft.gno` — already tested, already run in production on
// Sapphire — around a different upstream API, this package fills in the
// original (never-committed) dependency directly.
package grc721

import (
	"errors"

	"gno.land/p/nt/avl/v0"
)

// TokenID identifies one token within a single collection/token instance.
// Uniqueness is only guaranteed within one *royaltyNFT — the caller
// (nft.gno) is responsible for keeping IDs unique per collection.
type TokenID string

func (t TokenID) String() string { return string(t) }

// TokenURI is an opaque metadata/image URI string for one token — no
// format is enforced here (see nft.gno/frontend for how it's interpreted).
type TokenURI string

// RoyaltyInfo is a simple, single-recipient royalty rule for one token:
// on a sale of `salePrice`, `Percentage`% of it (0-100) is owed to
// PaymentAddress. Mirrors EIP-2981's RoyaltyInfo, but percentage-based
// instead of basis-points, matching how nft.gno's CreateCollection already
// takes a plain 0-100 `royaltyPct`.
type RoyaltyInfo struct {
	PaymentAddress address
	Percentage     int64
}

var (
	// ErrTokenNotFound is returned for any read/write against a tokenID
	// that was never minted, or was minted and later burned.
	ErrTokenNotFound = errors.New("grc721: token not found")
	// ErrNotOwnerOrApproved is returned when the caller is neither the
	// token's current owner, a single-token approved address, nor an
	// operator approved for all of the owner's tokens.
	ErrNotOwnerOrApproved = errors.New("grc721: caller is not the owner or an approved operator")
	// ErrNotOwner is returned for owner-only actions (SetTokenURI,
	// SetTokenRoyalty) called by anyone else.
	ErrNotOwner = errors.New("grc721: caller is not the token's owner")
	// ErrAlreadyMinted is returned by Mint if the tokenID is already in use.
	ErrAlreadyMinted = errors.New("grc721: tokenID already minted")
	// ErrInvalidRecipient is returned for a mint/transfer to the zero address.
	ErrInvalidRecipient = errors.New("grc721: recipient address is invalid")
	// ErrSelfApproval is returned by SetApprovalForAll(self, self, ...) —
	// approving yourself as your own operator is meaningless and almost
	// always a caller-side mistake worth rejecting outright.
	ErrSelfApproval = errors.New("grc721: cannot approve yourself as operator")
)

// royaltyNFT is one independent GRC-721 token instance — nft.gno's
// multi-tenant factory creates one of these per user-created collection.
type royaltyNFT struct {
	name   string
	symbol string

	owners            *avl.Tree // tokenID -> address
	balances          *avl.Tree // address.String() -> int64
	tokenApprovals    *avl.Tree // tokenID -> address (single-token approve)
	operatorApprovals *avl.Tree // "owner:operator" -> bool
	tokenURIs         *avl.Tree // tokenID -> string
	royalties         *avl.Tree // tokenID -> RoyaltyInfo

	tokenCount int64 // currently-live (minted, not burned) token count
}

// NewNFTWithRoyalty creates a new, empty token instance. The first two
// parameters (a reserved int and the caller's realm) are accepted for
// parity with the realm-scoped construction pattern used elsewhere in
// this project, but neither is consulted — every piece of state this type
// needs lives in the trees below, scoped to whichever realm holds the
// returned pointer. (The realm param can't be named `cur` here since a
// crossing function's `cur` must be its *first* argument — see the
// gno.land compiler's own restriction on that name.)
func NewNFTWithRoyalty(_ int64, _ realm, name, symbol string) *royaltyNFT {
	return &royaltyNFT{
		name:              name,
		symbol:            symbol,
		owners:            avl.NewTree(),
		balances:          avl.NewTree(),
		tokenApprovals:    avl.NewTree(),
		operatorApprovals: avl.NewTree(),
		tokenURIs:         avl.NewTree(),
		royalties:         avl.NewTree(),
	}
}

func (t *royaltyNFT) Name() string     { return t.name }
func (t *royaltyNFT) Symbol() string   { return t.symbol }
func (t *royaltyNFT) TokenCount() int64 { return t.tokenCount }

func (t *royaltyNFT) BalanceOf(addr address) (int64, error) {
	v := t.balances.Get(addr.String())
	if v == nil {
		return 0, nil
	}
	return v.(int64), nil
}

func (t *royaltyNFT) OwnerOf(tid TokenID) (address, error) {
	v := t.owners.Get(string(tid))
	if v == nil {
		return "", ErrTokenNotFound
	}
	return v.(address), nil
}

func (t *royaltyNFT) TokenURI(tid TokenID) (string, error) {
	if _, err := t.OwnerOf(tid); err != nil {
		return "", err
	}
	v := t.tokenURIs.Get(string(tid))
	if v == nil {
		return "", nil
	}
	return v.(string), nil
}

func (t *royaltyNFT) SetTokenURI(caller address, tid TokenID, tURI TokenURI) (bool, error) {
	owner, err := t.OwnerOf(tid)
	if err != nil {
		return false, err
	}
	if caller != owner {
		return false, ErrNotOwner
	}
	t.tokenURIs.Set(string(tid), string(tURI))
	return true, nil
}

func (t *royaltyNFT) IsApprovedForAll(owner, operator address) bool {
	v := t.operatorApprovals.Get(owner.String() + ":" + operator.String())
	if v == nil {
		return false
	}
	return v.(bool)
}

func (t *royaltyNFT) Approve(caller, to address, tid TokenID) error {
	owner, err := t.OwnerOf(tid)
	if err != nil {
		return err
	}
	if caller != owner && !t.IsApprovedForAll(owner, caller) {
		return ErrNotOwnerOrApproved
	}
	t.tokenApprovals.Set(string(tid), to)
	return nil
}

func (t *royaltyNFT) GetApproved(tid TokenID) (address, error) {
	if _, err := t.OwnerOf(tid); err != nil {
		return "", err
	}
	v := t.tokenApprovals.Get(string(tid))
	if v == nil {
		return "", nil
	}
	return v.(address), nil
}

func (t *royaltyNFT) SetApprovalForAll(caller, operator address, approved bool) error {
	if caller == operator {
		return ErrSelfApproval
	}
	t.operatorApprovals.Set(caller.String()+":"+operator.String(), approved)
	return nil
}

// isApprovedOrOwner reports whether caller may move tid on the current
// owner's behalf: the owner themselves, an approved operator for all of
// the owner's tokens, or the single address approved for this token.
func (t *royaltyNFT) isApprovedOrOwner(caller address, tid TokenID) (owner address, ok bool, err error) {
	owner, err = t.OwnerOf(tid)
	if err != nil {
		return "", false, err
	}
	if caller == owner || t.IsApprovedForAll(owner, caller) {
		return owner, true, nil
	}
	if approved := t.tokenApprovals.Get(string(tid)); approved != nil && approved.(address) == caller {
		return owner, true, nil
	}
	return owner, false, nil
}

func (t *royaltyNFT) TransferFrom(caller, from, to address, tid TokenID) error {
	owner, ok, err := t.isApprovedOrOwner(caller, tid)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotOwnerOrApproved
	}
	if owner != from {
		return ErrNotOwner
	}
	if to == "" {
		return ErrInvalidRecipient
	}

	// A completed transfer always clears the single-token approval —
	// otherwise a stale approval from before the transfer would let the
	// old approved address move the token again after it's already
	// changed hands, which is not how any owner would expect approve to
	// behave.
	t.tokenApprovals.Remove(string(tid))
	t.owners.Set(string(tid), to)

	fromBal, _ := t.BalanceOf(from)
	t.balances.Set(from.String(), fromBal-1)
	toBal, _ := t.BalanceOf(to)
	t.balances.Set(to.String(), toBal+1)

	return nil
}

func (t *royaltyNFT) Mint(to address, tid TokenID) error {
	if v := t.owners.Get(string(tid)); v != nil {
		return ErrAlreadyMinted
	}
	if to == "" {
		return ErrInvalidRecipient
	}
	t.owners.Set(string(tid), to)
	bal, _ := t.BalanceOf(to)
	t.balances.Set(to.String(), bal+1)
	t.tokenCount++
	return nil
}

// Burn permanently destroys a token — a true delete from every tree
// backing this instance, which is what actually triggers gno.land's
// storage-deposit refund to whoever pays the tx's storage cost (see
// PROJECT_STATUS.md's "Burn button" section for the full explanation of
// why this only works if every reference is really removed, not just
// zeroed out).
func (t *royaltyNFT) Burn(tid TokenID) error {
	owner, err := t.OwnerOf(tid)
	if err != nil {
		return err
	}
	t.owners.Remove(string(tid))
	t.tokenApprovals.Remove(string(tid))
	t.tokenURIs.Remove(string(tid))
	t.royalties.Remove(string(tid))

	bal, _ := t.BalanceOf(owner)
	t.balances.Set(owner.String(), bal-1)
	t.tokenCount--
	return nil
}

// RoyaltyInfo returns (paymentAddress, amountOwed) for a sale of tid at
// salePrice. A token with no royalty set returns a zero address and 0,
// same "no royalty" signal EIP-2981 uses.
func (t *royaltyNFT) RoyaltyInfo(tid TokenID, salePrice int64) (address, int64, error) {
	if _, err := t.OwnerOf(tid); err != nil {
		return "", 0, err
	}
	v := t.royalties.Get(string(tid))
	if v == nil {
		return "", 0, nil
	}
	info := v.(RoyaltyInfo)
	return info.PaymentAddress, salePrice * info.Percentage / 100, nil
}

func (t *royaltyNFT) SetTokenRoyalty(caller address, tid TokenID, info RoyaltyInfo) error {
	owner, err := t.OwnerOf(tid)
	if err != nil {
		return err
	}
	if caller != owner {
		return ErrNotOwner
	}
	t.royalties.Set(string(tid), info)
	return nil
}
