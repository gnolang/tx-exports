package gnofly

// The refusals of this realm, as strings: a string constant costs its length
// in storage where an errors.New value costs about a kilobyte (see the planes
// realm's errors.gno). A panic with a string aborts the call with it.
const (
	errSpoofedRealm = "gnofly market: spoofed realm"
	errNotAdmin     = "gnofly market: caller is not an admin"
	errNotUserCall  = "gnofly market: call it directly from a wallet (maketx call or Adena)"

	errUnknownPlane = "gnofly market: no such plane"
	errNotOwner     = "gnofly market: caller does not own this plane"
	errNotSeller    = "gnofly market: caller is not the seller of this plane"
	errListed       = "gnofly market: this plane is listed"
	errNotListed    = "gnofly market: this plane is not listed"
	errOwnListing   = "gnofly market: a seller cannot buy their own listing"
	errPaused       = "gnofly market: new listings are paused"
	errBadPrice     = "gnofly market: price must be between 1000000 and 1000000000000 ugnot"
	errNotApproved  = "gnofly market: approve the market on the planes realm first (Approve or SetApprovalForAll)"
	errBadRecipient = "gnofly market: invalid recipient address"
	errNotStray     = "gnofly market: this plane is not held by the market outside a listing"
	errRegistered   = "gnofly market: already registered on Bazaar"
)
