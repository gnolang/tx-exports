package mockfarm

// Farm is a test / day-one yield source. Accrue credits pending profit;
// Harvest takes it. Swap this out for a GnoSwap adapter without touching Book.
type Farm struct {
	pending int64
}

// New returns an empty farm.
func New() *Farm { return &Farm{} }

// Name implements protocol.Adapter.
func (f *Farm) Name() string { return "mock" }

// Want implements protocol.Adapter. The ugnot vault uses native coins.
func (f *Farm) Want() string { return "ugnot" }

// Pending implements protocol.Adapter.
func (f *Farm) Pending() int64 {
	if f == nil {
		return 0
	}
	return f.pending
}

// Accrue adds simulated yield. Anyone donating into a vault can call the
// vault's Donate path, which ends here.
func (f *Farm) Accrue(amount int64) {
	if amount <= 0 {
		panic("accrue amount must be positive")
	}
	next := f.pending + amount
	if next < f.pending {
		panic("pending overflow")
	}
	f.pending = next
}

// Harvest returns and clears pending profit.
func (f *Farm) Harvest() int64 {
	p := f.pending
	f.pending = 0
	return p
}
