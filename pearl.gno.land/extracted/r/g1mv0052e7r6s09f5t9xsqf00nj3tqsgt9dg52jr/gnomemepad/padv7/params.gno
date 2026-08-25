package padv7

// Protocol parameters (MVP). Tunable before deploy; post-deploy treated as constants
// unless a future governance path is added with timelock.

const (
	// Token economics
	TotalSupply int64 = 1_000_000_000
	CurveSupply int64 = 800_000_000 // sold on bonding curve
	PoolSeed    int64 = 200_000_000 // locked into CPMM at graduation

	// Virtual constant-product seed (Pump-style)
	VirtualUgnot0 int64 = 30_000_000      // 30 GNOT virtual
	VirtualToken0 int64 = 1_073_000_191   // virtual token side

	// Graduation when net ugnot raised into the curve reaches this.
	// padv4 testnet default: 50 GNOT. padv5 deploy script patches to 100 GNOT.
	// Keep below the ugnot needed to exhaust CurveSupply on the virtual CPMM.
	GraduationThreshold int64 = 100_000_000

	// Fees: 1.20% total. Of the fee: 40% creator, 40% protocol, 20% LP/k remainder.
	FeeBPS             int64 = 120
	CreatorFeeShareBPS int64 = 4000
	ProtocolFeeShareBPS int64 = 4000

	// Anti-spam create bond (1 GNOT padv4). padv5 deploy patches to 2 GNOT.
	CreateBondUgnot      int64 = 2_000_000
	BondRefundBuyers     int   = 5
	BondRefundMinRaised  int64 = 10_000_000 // â‰¥5 GNOT raised
	BondRefundMaxHeights int64 = 100_000

	// Anti-snipe: first N heights, max cumulative tokens per address (BPS of TotalSupply).
	AntiSnipeHeights   int64 = 30
	AntiSnipeMaxBuyBPS int64 = 300 // 5% per address in window

	// Status
	StatusCurve     = 0
	StatusGraduated = 1

	// Trade history ring buffer (padv4: 128; padv5 deploy patches to 256).
	MaxTradeHistory = 256
	// Trade sides stored in history
	TradeSideBuy  = 0
	TradeSideSell = 1
	TradeSideOpen = 2 // initial listing mark

	DenomUgnot = "ugnot"
)
