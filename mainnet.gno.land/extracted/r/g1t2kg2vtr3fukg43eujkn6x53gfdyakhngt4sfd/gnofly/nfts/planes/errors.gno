package planes

// The refusals of this realm, as strings. The game and arena realms keep
// theirs as error values; this one is published with a 42 KB table and every
// byte of state is paid for at deploy. Measured on a mainnet-like node, an
// errors.New value costs about 1.15 KB of storage (a pointer, a heap item and
// a struct, each with its header) where a string constant costs its length:
// twenty of them are 2 GNOT against 0.1. A panic with a string aborts the
// call with the same message.
const (
	errSpoofedRealm = "gnofly: spoofed realm"
	errNotAdmin     = "gnofly: caller is not an admin"
	errBadTable     = "gnofly: the plane table does not run from 1 to 777"
	errCorruptRow   = "gnofly: corrupt plane row"

	errUnknownPlane  = "gnofly: unknown plane"
	errNotMinted     = "gnofly: plane not minted"
	errNotPlaneOwner = "gnofly: caller does not own this plane"

	errMintClosed   = "gnofly: the mint is closed"
	errSoldOut      = "gnofly: every plane is minted"
	errCapReached   = "gnofly: this wallet minted as many planes as the cap allows"
	errNotUserCall  = "gnofly: Mint must be called directly by a user (maketx call)"
	errInvalidCount = "gnofly: mint 1 to 7 planes at a time"

	errInvalidPrice   = "gnofly: price must be between 1000000 and 10000000000 ugnot"
	errInvalidCap     = "gnofly: cap must be between 1 and 777"
	errInvalidBase    = "gnofly: image base must be an https URL ending in /, 12 to 200 characters of [A-Za-z0-9./_-:]"
	errInvalidRoyalty = "gnofly: royalty must be between 0 and 1000 basis points"
)
