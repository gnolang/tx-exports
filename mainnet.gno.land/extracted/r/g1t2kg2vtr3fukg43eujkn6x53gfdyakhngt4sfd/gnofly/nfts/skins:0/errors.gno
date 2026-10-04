package skins

// The refusals of this realm, as string constants: a string costs its length
// in storage where an errors.New value costs about 1.15 KB (see the planes
// realm). A panic with a string aborts the call with the same message.
const (
	errSpoofedRealm = "gnofly: spoofed realm"
	errNotAdmin     = "gnofly: caller is not an admin"
	errBadCatalog   = "gnofly: corrupt catalog line"

	errInvalidID     = "gnofly: id must be 1 to 32 characters of [a-z0-9-]"
	errReservedID    = "gnofly: classic is the free look of every pilot, not a skin to sell"
	errInvalidName   = "gnofly: name must be 1 to 40 characters of [A-Za-z0-9 '.!-]"
	errInvalidModel  = "gnofly: model must be 1 to 16 characters of [a-z0-9-]"
	errInvalidPilot  = "gnofly: pilot must be none or gnome"
	errInvalidColor  = "gnofly: colors must be #rrggbb in lowercase"
	errInvalidPrice  = "gnofly: price must be between 1 and 1000000000000 ugnot"
	errInvalidSupply = "gnofly: max supply must be 0 (unlimited) or more"

	errUnknownSkin  = "gnofly: unknown skin"
	errSkinUnlisted = "gnofly: this skin is not for sale"
	errSoldOut      = "gnofly: every copy of this skin is sold"
	errAlreadyOwned = "gnofly: this address already owns this skin"
	errNotUserCall  = "gnofly: Buy must be called directly by a user (maketx call)"
	errNotMinted    = "gnofly: no such skin token"
	errNotSkinOwner = "gnofly: caller does not own this skin token"
)
