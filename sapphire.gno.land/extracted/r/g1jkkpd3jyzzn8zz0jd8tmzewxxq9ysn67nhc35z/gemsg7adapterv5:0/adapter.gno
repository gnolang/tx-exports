// Package gemsg7adapterv5 is a satellite adapter registering
// gno.land/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/g7 ("Gems") with
// gnomarket, without any action from that collection's own deployer.
//
// It exists because gnomarket only trades collections whose registered
// collectionID is genuinely spoof-proof — RegisterCollection derives it
// from cur.Previous().PkgPath(), the REAL calling realm, so it can never
// be forged to claim someone else's identity. That security property
// means collectionID here is unavoidably THIS adapter's own path, not
// g7's — there is no way around that while keeping the guarantee intact,
// and it's why a seller approves THIS adapter's address on g7's real
// contract (see ApprovalTarget/ApprovalOperator below), not the
// marketplace's address directly the way a natively-registered
// collection works. The frontend checks for these two extra functions
// and falls back to the direct-approval flow when they're absent.
//
// v4 -> v5: v4 used chain/runtime/unsafe's CurrentRealm().Address() to
// find "this adapter's own address" wherever that was needed, and hit a
// real, reproducible discrepancy: a direct qeval call to IsApprovedForAll
// (or ApprovalOperator) always resolved the correct address, but the
// SAME expression, reached through nftmarketv2.List()'s nested
// market.NFT interface dispatch during .app/simulate (and thus a real
// Adena broadcast), resolved to something that made the approval check
// fail — reproduced independently via gnoclient.Client.Simulate() against
// the real seller/token, bypassing Adena and this app's own JS entirely.
// v5 removes the dependency on CurrentRealm() altogether: chain.
// PackageAddress(pkgPath) derives a realm's address as a pure hash of its
// pkgpath string (gno.DerivePkgBech32Addr under the hood — the same
// derivation gno.land itself uses when a package is first deployed),
// with no notion of "current call stack" to resolve inconsistently.
// Verified before deploying that PackageAddress(v4's own path) equals
// the real, known-correct address v4's CurrentRealm() calls returned —
// confirming this is the right formula, not a different address that
// would just move the bug.
package gemsg7adapterv5

import (
	"chain"

	grc721 "gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/grc721v2"
	market "gno.land/p/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/market"
	target "gno.land/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/g7"
	nftmarket "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/nftmarketv2"
)

// selfPkgPath is this adapter's own deploy path, known at compile time —
// used to derive this realm's own address as a pure function (see
// chain.PackageAddress), rather than resolving "the current realm"
// dynamically through however many interface-dispatch hops a given call
// happened to arrive through.
const selfPkgPath = "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/gemsg7adapterv5"

func Name() string                        { return target.Name() }
func OwnerOf(tid string) (address, error) { return target.OwnerOf(grc721.TokenID(tid)) }
func TokenURI(tid string) (string, error) { return target.TokenURI(grc721.TokenID(tid)) }

// GetApproved normalizes g7's error convention to market.NFT's: g7's real
// GetApproved returns an ERROR (ErrTokenIdNotHasApproved) when nothing is
// individually approved for a token — a valid GRC721 convention some
// collections use, but not what market.NFT's own contract promises
// ("" with a nil error for "none"), and not what nftmarket.gno's isApproved
// expects either — confirmed live: it panics on ANY error from GetApproved
// rather than falling through to check IsApprovedForAll, so an
// unmodified passthrough here aborted every single List/Buy on this
// collection with "token id not approved for anyone," even for a seller
// who'd correctly called SetApprovalForAll. Treating any error as "not
// approved this way" and letting the (also-fixed, see below)
// IsApprovedForAll check decide instead is the fix — entirely on this
// side of the boundary, since nftmarket.gno itself is immutable.
func GetApproved(tid string) (address, error) {
	approved, err := target.GetApproved(grc721.TokenID(tid))
	if err != nil {
		return "", nil
	}
	return approved, nil
}

// IsApprovedForAll ignores the `operator` the marketplace passes in — that
// is always the MARKETPLACE's own address (nftmarket.gno's isApproved
// hardcodes marketAddr = cur.Address()), but the address that actually
// calls TransferFrom on g7 is THIS ADAPTER (see TransferFrom below and
// this file's own top-of-file doc comment on why), which is also the
// address ApprovalOperator() told the seller to approve in the first
// place. Checking the passed-in operator instead would always report
// false — the seller has no way to approve an address they were never
// told about — so the only truthful answer to "is marketplace-relevant
// approval granted" is whether THIS adapter itself is approved.
func IsApprovedForAll(owner, operator address) bool {
	return target.IsApprovedForAll(owner, chain.PackageAddress(selfPkgPath))
}

// ApprovalTarget/ApprovalOperator: where a seller actually grants approval
// (g7's own path) and to whom (this adapter's own address) — g7 has no
// notion of "the marketplace," it only knows the immediate caller it's
// approving, which after the marketplace calls through this adapter is
// this adapter's address, not the marketplace's.
func ApprovalTarget() string    { return "gno.land/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/g7" }
func ApprovalOperator() address { return chain.PackageAddress(selfPkgPath) }

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

// TransferFrom crosses into g7 as THIS adapter — g7 derives its own
// caller the same spoof-proof way (cur.Previous()/unsafe.PreviousRealm()),
// so it sees this adapter as the mover, which is exactly why the seller
// had to approve this adapter's address on g7 in the first place, not the
// marketplace's. g7's own TransferFrom panics on failure rather than
// returning an error; that panic propagates through this call and through
// the marketplace's Buy() untouched, aborting the whole transaction —
// the same effective behavior as returning a non-nil error.
func (marketAdapter) TransferFrom(cur realm, from, to address, tid string) error {
	target.TransferFrom(cross(cur), from, to, grc721.TokenID(tid))
	return nil
}

var _ market.NFT = marketAdapter{}

func RegisterWithMarketplace(cur realm) string {
	return nftmarket.RegisterCollection(cross(cur), marketAdapter{})
}
