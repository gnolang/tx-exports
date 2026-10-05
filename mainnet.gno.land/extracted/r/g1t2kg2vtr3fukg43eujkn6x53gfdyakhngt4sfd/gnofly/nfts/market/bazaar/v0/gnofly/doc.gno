// Package gnofly is the market of gnofly's planes: a fixed-price book where
// a plane's owner lists it, anyone buys it, and each sale pays the planes
// realm's royalty (RoyaltyInfo: 5% to the gnofly treasury) out of the price.
//
// It is a wrapper, not a collection: it mints nothing. The planes are the
// tokens of gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/nfts/planes,
// moved with that realm's TransferFrom. A seller first approves this realm
// there (Approve for one plane, or SetApprovalForAll); List then moves the
// plane here, in escrow, Buy hands it to the buyer and Cancel back to the
// seller.
//
// Its calls and reads have the shapes Bazaar's site (bazaar.gnomi.fun)
// uses on a collection package (List, UpdatePrice, Cancel, Buy, Transfer;
// ListOpen, ItemLine, TokensOf, Minted), so that it can be registered there
// later, under the slug of its last path element. It is not registered, and
// pays Bazaar nothing.
//
// It is version v0 of the market (the path's v0). SetPaused stops new
// listings for a move to a newer one; Cancel and Buy keep working, so no
// plane is ever stuck here.
//
// Every write is a direct call from a wallet: no realm can list, buy or
// cancel in a user's name.
package gnofly
