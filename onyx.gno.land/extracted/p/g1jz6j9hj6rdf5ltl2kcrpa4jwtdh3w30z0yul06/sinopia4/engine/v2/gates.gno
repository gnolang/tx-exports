package engine

// Optional gates (core-final round, 2026-11-12). Engine stays exactly as it
// was, so every engine written against it keeps compiling; an engine value
// that also implements CreateGate or LaunchGate gets the collection-level
// facts its plain methods cannot see. Core finds them with a type
// assertion on the registered value and runs them, like ValidateParams and
// CheckLaunch, only in the creator's own transaction (I-16), never with
// core's cur.

// Launch modes as core passes them in Collection.Mode (the same values as
// types.ModeReveal and types.ModeOpen).
const (
	ModeReveal = ""
	ModeOpen   = "open"
)

// Collection is what core tells an engine's gates about one collection.
// Plain values only: an engine never gets a reference into core state.
type Collection struct {
	ID        string  // the collection id (bare, e.g. "12")
	Creator   address // the creator core records (a wallet or a realm, K-2)
	Params    string  // already accepted by ValidateParams
	MaxSupply int64
	// Mode is the launch mode in GateLaunch (ModeReveal or ModeOpen); ""
	// in GateCreate (a Draft has no mode yet).
	Mode string
	// Soulbound: the collection's tokens can never be transferred or
	// approved (fixed at creation).
	Soulbound bool
}

// CreateGate is the create-time check with the creator: core.CreateCollection
// calls GateCreate after ValidateParams and TraitTypes accepted the params;
// an error aborts the creation ("create refused by engine: …"). This is
// where an engine checks who may use which params (e.g. that the creator
// owns the asset store the params name) instead of reading OriginCaller.
type CreateGate interface {
	GateCreate(c Collection) error
}

// LaunchGate is the launch-time check with the launch mode: core.Launch
// calls GateLaunch right after CheckLaunch passed, for both modes; an error
// aborts the launch ("launch refused by engine: …").
type LaunchGate interface {
	GateLaunch(c Collection) error
}
