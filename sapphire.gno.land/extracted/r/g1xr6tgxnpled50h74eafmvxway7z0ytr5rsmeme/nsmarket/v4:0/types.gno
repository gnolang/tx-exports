// nsmarket — names for sale, without anybody holding anything.
//
// HOW A SALE WORKS, and why it is built this way.
//
// The seller keeps their name. Listing does not move it here: it records
// an asking price and relies on the GRC-721 approval the seller has
// already granted this realm. Ownership does not change until somebody
// buys, and the seller can walk away at any moment by revoking the
// approval — at which point the listing simply stops working.
//
// The buyer's money is never held either. Buy is ONE call: it checks the
// listing still stands, moves the name, pays the seller, takes the fee,
// refunds any overpayment. All of it inside the transaction the buyer
// signed. If any part fails the whole thing reverts and nothing moved.
//
// Which means: at no point does this realm hold somebody else's name or
// somebody else's money. That is not a nice-to-have. An escrow that
// holds either one is a different kind of business, with a different set
// of rules, run by people with licences.
//
// THIS REALM HAS NO VAULT PRIVILEGES. It is not in nsdata's trusted set
// and does not ask to be. Every transfer goes through nslogic's ordinary
// GRC-721 path, which means it can only move a name the owner has
// explicitly approved — the same permission any other marketplace would
// need. However wrong the code below turns out to be, the worst it can
// do is fail.
package nsmarket

import (
	"gno.land/p/nt/avl/v0"
)

// A listing. Kept small on purpose: the seller pays to store it, and
// everything derivable is derived rather than copied. The seller's
// address is here because the name can change hands outside this realm
// and a stale seller must be caught, not trusted.
type Listing struct {
	seller address
	price  int64 // ugnot
	listed int64 // unix seconds
}

var (
	// Keyed by token id, "label*domain".
	listings avl.Tree
	sold     int64 // completed sales, for the honest version of a stat
)

const (
	maxPage     = 200
	minPrice    = int64(1)         // zero would be a giveaway, not a sale
	maxPrice    = int64(1) << 52   // guards the fee arithmetic from overflow
	ugnot       = "ugnot"
)
