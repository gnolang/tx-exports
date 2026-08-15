package protocol

// Adapter is the DeFi-facing contract a strategy realm wires internally.
//
// SECURITY: never put `cur realm` on this interface (Class 1a/1b). Never
// accept a caller-supplied Adapter in a public crossing function without a
// concrete-type assert (Class 3). Vaults construct their own adapter.
//
// Adding a protocol = implement Adapter in a new /p/ package, then a thin
// /r/ strategy realm that owns a Book and calls the adapter on harvest.
type Adapter interface {
	// Name is a stable id ("mock", "gnoswap", later "lending", …).
	Name() string
	// Want is the deposit asset: "ugnot" or a GRC20 token id.
	Want() string
	// Pending is harvestable profit in want units, before fees.
	Pending() int64
}

// Meta is registry metadata. Stored as values, never as realm handles.
type Meta struct {
	ID       string
	Name     string
	Protocol string
	PkgPath  string
	Want     string
}

// Kind constants keep registry filters stable as new adapters land.
const (
	KindMock    = "mock"
	KindGnoswap = "gnoswap"
)
