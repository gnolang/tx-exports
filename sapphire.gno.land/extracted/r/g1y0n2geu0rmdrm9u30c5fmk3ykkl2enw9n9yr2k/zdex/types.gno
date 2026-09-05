package zdex

const (
	nativeDenom = "ugnot"
	bpsDen      = int64(10000)

	defaultFeeBps  = int64(30)  // 0.30% on ordinary pools
	launchFeeBps   = int64(100) // 1.00% on launched markets
	maxFeeBps      = int64(1000)
	minLiquidity   = int64(1000)

	// Launch safety — tighter than zSwap, which mints creator tokens unlocked.
	maxCreatorKeepBps  = int64(2000)  // 20%
	minVestBlocks      = int64(28800) // ~1 day at 3s blocks
	minLockBlocks      = int64(28800)
	defaultSnipeBlocks = int64(1000)
	defaultSnipeMaxBps = int64(200) // 2% of real token reserve per tx
	maxSnipeMaxBps     = int64(1000)

	// Fee split of the swap fee: remainder stays in the pool as LP fee.
	launchCreatorFeeBps  = int64(4000) // 40% of fee → creator (0.40% of notional at 1% fee)
	launchProtocolFeeBps = int64(1000) // 10% of fee → protocol
	poolProtocolFeeBps   = int64(1667) // ~1/6 of fee, Uniswap-v2 protocol fee
)

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
	AccruedU     int64
	AccruedT     int64
	UnlockHeight int64 // LP may be removed at/after this height; 0 = unlocked
	SnipeUntil   int64
	SnipeMaxBps  int64
	Launched     bool
	Internal     bool // token minted by this realm
}

type Position struct {
	LP int64
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
