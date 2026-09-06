package zdex

const (
	nativeDenom = "ugnot"
	bpsDen      = int64(10000)

	defaultFeeBps = int64(30)  // 0.30% — standard AMM pool
	launchFeeBps  = int64(100) // kept for existing launched pools only
	maxFeeBps     = int64(100) // 1.00% hard cap (DEX listing)
	minLiquidity  = int64(1000)
	minListUgnot  = int64(1_000_000) // 1 GNOT minimum to open a pool

	// DEX fee tiers (bps of notional). Protocol takes poolProtocolFeeBps of the fee.
	feeTierLow  = int64(5)   // 0.05%
	feeTierMid  = int64(30)  // 0.30%
	feeTierHigh = int64(100) // 1.00%

	// Launch safety — tighter than zSwap, which mints creator tokens unlocked.
	maxCreatorKeepBps  = int64(2000)  // 20%
	minVestBlocks      = int64(28800) // ~1 day at 3s blocks
	minLockBlocks      = int64(28800)
	defaultSnipeBlocks = int64(1000)
	defaultSnipeMaxBps = int64(200) // 2% of real token reserve per tx
	maxSnipeMaxBps     = int64(1000)

	// Fee split of the swap fee: remainder stays in the pool as LP fee.
	// DEX model: no creator cut on CreatePool. Protocol ~1/6 of the swap fee.
	launchCreatorFeeBps  = int64(4000) // legacy launched pools only
	launchProtocolFeeBps = int64(1000) // legacy launched pools only
	poolProtocolFeeBps   = int64(1667) // ~1/6 of fee → protocol; ~5/6 → LPs

	ptsScale             = int64(1_000_000_000)
	defaultEpochBlocks   = int64(28800) // ~1 day
	defaultFeeShareBps   = int64(8000)  // 80% of protocol ugnot → points pot
)

func validSwapFee(bps int64) bool {
	return bps == feeTierLow || bps == feeTierMid || bps == feeTierHigh
}

type Pool struct {
	ID           string
	Token        string // GRC20 registry key or internal key; pair is always ugnot / Token
	Symbol       string
	Name         string
	ReserveU     int64 // real ugnot
	ReserveT     int64 // real token
	VirtualU     int64 // pricing offset (one-sided launch)
	TotalLP      int64
	FeeBps       int64
	Creator      address
	CreatorBps   int64 // share of fee (of the fee, not of notional)
	ProtocolBps  int64
	Decimals     int64
	AccruedCreatorU  int64
	AccruedCreatorT  int64
	AccruedProtocolU int64
	AccruedProtocolT int64
	UnlockHeight int64 // LP may be removed at/after this height; 0 = unlocked
	SnipeUntil   int64
	SnipeMaxBps  int64
	Launched     bool
	Internal     bool // token minted by this realm
	AccPoints    int64 // cumulative LP points per share * ptsScale
}

type Position struct {
	LP         int64
	RewardDebt int64 // LP * AccPoints / ptsScale at last harvest
}

type Score struct {
	Life     int64
	Epoch    int64
	EpochID  uint64
	Closed   int64
	ClaimedID uint64
}

type Order struct {
	ID         uint64
	Maker      address
	PoolID     string
	GiveUgnot  bool  // true = bid (escrow ugnot, want token)
	GiveAmt    int64 // remaining give
	WantAmt    int64 // remaining want
	ExpireH    int64 // 0 = never
	AllOrNone  bool
}

type Vesting struct {
	Symbol  string
	Owner   address
	Total   int64
	Claimed int64
	StartH  int64
	EndH    int64
}
