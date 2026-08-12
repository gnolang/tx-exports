package padv3

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
	// 50 GNOT â€” testnet-friendly; raise for production.
	// Keep below the ugnot needed to exhaust CurveSupply on the virtual CPMM.
	GraduationThreshold int64 = 50_000_000

	// Fees: 1.20% total. Of the fee: 40% creator, 40% protocol, 20% LP/k remainder.
	FeeBPS             int64 = 120
	CreatorFeeShareBPS int64 = 4000
	ProtocolFeeShareBPS int64 = 4000

	// Anti-spam create bond (1 GNOT). Refunded if min unique buyers hit before expire.
	CreateBondUgnot      int64 = 1_000_000
	BondRefundBuyers     int   = 5
	BondRefundMaxHeights int64 = 100_000 // ~ loosely long window; chain-dependent

	// Anti-snipe: first N heights after create, max buy as % of total supply (BPS of TotalSupply).
	AntiSnipeHeights   int64 = 20
	AntiSnipeMaxBuyBPS int64 = 500 // 5% of total supply per tx in first windows

	// Status
	StatusCurve     = 0
	StatusGraduated = 1

	// Trade history cap for per-token price charts (ring buffer).
	MaxTradeHistory = 128
	// Trade sides stored in history
	TradeSideBuy  = 0
	TradeSideSell = 1
	TradeSideOpen = 2 // initial listing mark

	DenomUgnot = "ugnot"
)
