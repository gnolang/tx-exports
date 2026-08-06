package grc721

// IGRC721Reader is the read-only view of an NFT. Safe to receive across
// realm boundaries — has no rlm-typed methods, so a malicious impl can
// only lie about read results (data-integrity issue), not capture cur.
//
// Writes are concrete methods on *BasicNFT / *metadataNFT only — there
// is no IGRC721 writer interface. The owning realm should hold the
// concrete *metadataNFT in an unexported package var and expose public
// caller-deriving wrappers like:
//
//	func TransferFrom(cur realm, from, to address, tid TokenID) error {
//		caller := unsaferealm.PreviousRealm().Address() // chain/runtime/unsafe
//		return nft.TransferFrom(caller, from, to, tid)
//	}
//
// (cur.Previous().Address() is the more idiomatic form where every
// target network's GnoVM supports it — confirmed missing on Beta
// Mainnet's as of 2026-08, hence the unsafe fallback above; see
// basic_nft.gno's NewBasicNFT doc comment for the full rationale and
// the empirical/structural argument for why it's safe for this
// call shape specifically.)
//
// This is the Reader/Writer split — stronger than the Authority-pattern
// because the writer interface doesn't exist at all, so no realm author
// can accidentally expose it.
type IGRC721Reader interface {
	Name() string
	Symbol() string
	TokenCount() int64
	BalanceOf(owner address) (int64, error)
	OwnerOf(tid TokenID) (address, error)
	GetApproved(tid TokenID) (address, error)
	IsApprovedForAll(owner, operator address) bool
}

type (
	TokenID  string
	TokenURI string
)

func (t TokenID) String() string  { return string(t) }
func (t TokenURI) String() string { return string(t) }

const (
	MintEvent           = "Mint"
	BurnEvent           = "Burn"
	TransferEvent       = "Transfer"
	ApprovalEvent       = "Approval"
	ApprovalForAllEvent = "ApprovalForAll"
	TokenURIUpdateEvent = "TokenUriUpdate"
	MetadataUpdateEvent = "MetadataUpdate"
)

// NFTGetter returns a reader-only view of an NFT. Aggregators (such as
// a marketplace or observer) register and dispatch NFTGetters; the
// reader-only return type means even a malicious aggregator can't be
// used to leak cur.
type NFTGetter func() IGRC721Reader
