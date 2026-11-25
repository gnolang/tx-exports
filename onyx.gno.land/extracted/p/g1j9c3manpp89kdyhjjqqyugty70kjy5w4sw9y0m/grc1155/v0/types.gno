package grc1155

import (
	"errors"

	"gno.land/p/nt/avl/v0"
)

// TokenID identifies one token type inside a Token. Ids accepted by write
// paths are restricted to [A-Za-z0-9_.-], so a stored id is always safe to
// render in markdown and safe to embed in the composite storage keys this
// package derives from it. A TokenID is only a string conversion — reads do
// not re-validate it, so consumers rendering a caller-supplied id must apply
// the same charset check themselves (URI does).
type TokenID string

func (t TokenID) String() string { return string(t) }

// A Teller is a capability that acts as some account whenever it writes.
// IsCanonicalTeller confirms a Teller was minted by this package — an embedding
// forgery fails the check — but it does NOT reveal which account the Teller acts
// as: a caller-scoped CallerTeller and the admin-grade ImpersonateTeller (which
// acts as an arbitrary address) are both canonical. So it is an authenticity
// check on the implementation, not an authorization guard on the acting account;
// a caller accepting a Teller from outside must still establish, out of band, what
// account that Teller is entitled to act as. And because the write methods take
// the caller's own cur/rlm as an argument, a consumer that accepts a Teller from
// outside must run IsCanonicalTeller BEFORE handing that rlm to it — a forged
// Teller receiving a live rlm could act as the consumer's realm.
// safeTransferFrom/safeBatchTransferFrom are omitted: EIP-1155's receiver check
// needs a registry, and aliasing it would imply false safety.
type Teller interface {
	GetName() string
	GetSymbol() string
	ID() string
	URI(tid TokenID) string
	TotalSupply(tid TokenID) int64
	BalanceOf(owner address, tid TokenID) (int64, error)
	BalanceOfBatch(owners []address, tids []TokenID) ([]int64, error)
	IsApprovedForAll(owner, operator address) bool

	SetApprovalForAll(_ int, rlm realm, operator address, approved bool) error
	TransferFrom(_ int, rlm realm, from, to address, tid TokenID, amount int64) error
	BatchTransferFrom(_ int, rlm realm, from, to address, tids []TokenID, amounts []int64) error
}

// Extension hooks fire on every mint/transfer/burn. This is a trust grant to the
// issuer, not an EIP-1155 feature: only the issuer can attach one (RegisterExtension
// holds the PrivateLedger), but once attached the hook runs arbitrary issuer code on
// every movement, a panic in OnMint/OnTransfer/OnBurn aborts the transaction before
// the movement is announced — an implicit veto over transfers — and gas scales
// linearly with the extension count. Hooks run after the ledger write so they observe
// the post-movement state; only a caller that recovers from the panic keeps that write.
// For batch operations the hooks fire once per batch entry, in batch order — and
// only after EVERY entry has been written, so entry 0's hook already observes the
// full batch applied, not a partially-applied one.
// Holders of a collection's tokens are therefore trusting the issuer not to freeze or
// tax movement through this surface. Hooks take no rlm params (they cannot capture cur);
// attach only via RegisterExtension.
type Extension interface {
	ExtensionKind() string // unique; duplicates rejected at register
	OnMint(to address, tid TokenID, amount int64)
	OnTransfer(from, to address, tid TokenID, amount int64)
	OnBurn(from address, tid TokenID, amount int64)
}

type ExtensionView interface {
	ExtensionKind() string
	TokenID() string // core Token.ID
}

type Token struct {
	id         string // raw creation pkgpath + "." + symbol
	name       string
	symbol     string
	defaultURI string
	ledger     *PrivateLedger
	// origRealm is the PkgPath of the realm that created the token, captured
	// unforgeably in NewToken. A frame-relative teller only works there.
	origRealm string
}

type PrivateLedger struct {
	token             *Token
	supplies          avl.Tree // TokenID -> int64 total supply; entry removed at zero
	balances          avl.Tree // "owner:tokenID" -> int64; entry removed at zero
	uris              avl.Tree // TokenID -> per-token URI override
	operatorApprovals avl.Tree // "owner:operator" -> bool
	extensions        []Extension
}

var (
	ErrInvalidTokenID             = errors.New("invalid token id")
	ErrInvalidAddress             = errors.New("invalid address")
	ErrCallerIsNotOwnerOrApproved = errors.New("caller is not token owner or approved")
	ErrApprovalToCurrentOwner     = errors.New("approval to current owner")
	ErrCannotTransferToSelf       = errors.New("cannot send transfer to self")
	ErrInsufficientBalance        = errors.New("insufficient balance")
	ErrInvalidAmount              = errors.New("invalid amount")
	ErrLengthMismatch             = errors.New("batch length mismatch")
	ErrEmptyBatch                 = errors.New("empty batch")
	ErrBatchTooLarge              = errors.New("batch too large")
	ErrInvalidURI                 = errors.New("invalid uri")
	ErrOverflow                   = errors.New("integer overflow")
	ErrReadonly                   = errors.New("teller is readonly")
	ErrSpoofedRealm               = errors.New("rlm does not match the current crossing frame")
	ErrForeignCallerTeller        = errors.New("frame-relative teller used outside the token's realm")
	ErrNotRealm                   = errors.New("rlm must be a realm (got EOA/origin)")
	ErrInvalidName                = errors.New("invalid token name (empty, too long, or contains control chars)")
	ErrInvalidSymbol              = errors.New("invalid token symbol (empty, too long, or contains chars outside [A-Za-z0-9_-])")
)

const (
	MaxTokenIDLen = 64
	MaxBatchSize  = 64
	MaxURILen     = 256
	// maxPageSize bounds HoldingsOf/TokenIDs page reads.
	maxPageSize = 50
)

// Symbol charset matches grc20reg slug (embedded in Token.ID / events).
const (
	MaxNameLen   = 64
	MaxSymbolLen = 11
)

const (
	// NewToken announces every token creation; see NewToken for why it is a
	// complete provenance signal.
	NewTokenEvent = "NewToken"
	// Mint and burn emit TransferSingle/TransferBatch with an empty from/to
	// address respectively (EIP-1155). Their "operator" attribute is empty —
	// the ledger has no spender for those ops; transfers carry the spender.
	TransferSingleEvent = "TransferSingle"
	TransferBatchEvent  = "TransferBatch"
	ApprovalForAllEvent = "ApprovalForAll"
	URIEvent            = "URI"
)

var zeroAddress = address("")

type fnTeller struct {
	accountFn func(_ int, rlm realm) address
	// homeGuard marks a frame-relative teller, whose writes are confined to
	// the token's own realm. See fnTeller.guardHome.
	homeGuard bool
	*Token
}

var _ Teller = (*fnTeller)(nil)

// IsCanonicalTeller reports whether t was minted by this package, rejecting Tellers
// forged by embedding *fnTeller in a wrapper. It does NOT discriminate by capability
// grade: CallerTeller, ReadonlyTeller, RealmTeller, RealmSubTeller and the admin-grade
// ImpersonateTeller all return true. Do not treat a true result as proof that a Teller
// is a caller-scoped capability — establish the acting account separately.
func IsCanonicalTeller(t Teller) bool {
	_, ok := t.(*fnTeller)
	return ok
}
