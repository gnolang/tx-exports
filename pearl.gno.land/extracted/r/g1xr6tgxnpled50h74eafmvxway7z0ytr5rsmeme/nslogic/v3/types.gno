// Package nslogic is the swappable "business rules" half of the split
// (NOTES.md §9t). It holds every piece of policy that might reasonably
// change — pricing, character validation, payment/refund, freeze rules,
// transfer restrictions — and no persistent records of its own.
//
// Every mutation here ends by calling into nsdata's narrow Record/Raw
// API via cross(cur). nsdata trusts whichever address is currently wired
// up as trustedLogic to have done its own authorization checks
// correctly, so THIS realm is where "is the caller allowed to do this"
// actually lives. If a bug is found here, admin deploys a fixed nslogic
// and re-points the vault at it (ProposeTrustedLogicGrant, then
// ExecutePending after the timelock) — no data migration,
// records and config untouched.
//
// Deliberately reads config fresh from nsdata on every call rather than
// caching it. The one thing that cannot be read fresh is a COMPILED
// regex — avl trees store the pattern string, not the compiled object —
// so that one value is cached, and the cache is validated against
// nsdata on every use.
package nslogic


const (
	ugnot    = "ugnot"
	bpsDenom = 10_000
)


