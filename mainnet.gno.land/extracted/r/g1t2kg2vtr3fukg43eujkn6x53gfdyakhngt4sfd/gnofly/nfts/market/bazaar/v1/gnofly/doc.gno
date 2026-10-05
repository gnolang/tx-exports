// Package gnofly is the wrapper that puts gnofly's planes on Bazaar
// (bazaar.gnomi.fun), the NFT marketplace of gno.land.
//
// Bazaar lists the collections registered on its factory, bazaarv5, and sends
// its site's List, Buy and Cancel to the collection's own package. This realm
// is that package for the planes: Init registers it under the slug "gnofly"
// (its last path element), and it holds the book. It mints nothing: the
// planes are the tokens of
// gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/nfts/planes,
// moved with that realm's TransferFrom. A seller first approves this realm
// there (Approve, or SetApprovalForAll once); List then moves the plane here,
// in escrow, Buy hands it to the buyer and Cancel back to the seller.
//
// A sale pays, out of its price: Bazaar's fee (read from the factory: its
// ProtocolBps less the holder discount, split between its sinks), the planes
// realm's royalty (5% to the gnofly treasury), and the rest to the seller.
//
// It is version v1 of the market; v0 is the same book without Bazaar, which
// cannot register. SetPaused stops new listings for a move to a newer version;
// Cancel and Buy keep working, so no plane is ever stuck here.
//
// Every write is a direct call from a wallet: no realm can list, buy or
// cancel in a user's name.
package gnofly
