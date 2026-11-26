package tollgate

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	StatusActive    = "active"
	StatusPaused    = "paused"
	StatusClosed    = "closed"
	StatusPending   = "pending"
	StatusDisputed  = "disputed"
	StatusFinalized = "finalized"
	StatusRefunded  = "refunded"

	RailMeteredPass  = "metered-pass"
	RailSubscription = "subscription"
	RailX402Direct   = "x402-direct"

	VoucherDomain = "tollgate-voucher-v1"

	maxRenderRows   = 25
	maxNameLen      = 80
	maxURLLen       = 200
	maxDescLen      = 400
	maxReasonLen    = 240
	minExpiryBlocks = int64(20)
	maxExpiryBlocks = int64(2000000)
	maxUnitsPerTx   = int64(1000000)
	maxAmountPerTx  = int64(1000000000000000) // 1e15 ugnot
	maxInt64        = int64(1<<63 - 1)
)

type serviceRecord struct {
	id                  uint64
	slug                string
	name                string
	description         string
	endpointURL         string
	owner               address
	payTo               address
	unitPriceUgnot      int64
	subPriceUgnot       int64
	subBlocks           int64
	subQuota            int64
	challengeBlocks     int64
	paused              bool
	createdHeight       int64
	totalCalls          int64
	escrowedRevenue     int64 // real on-chain settled pass + subscription ugnot
	x402AttestedRevenue int64 // provider-attested external x402 ugnot
}

type passRecord struct {
	id              uint64
	serviceID       uint64
	buyer           address
	depositUgnot    int64
	spentUgnot      int64
	pendingUgnot    int64
	maxPerCallUgnot int64
	expiryHeight    int64
	openedHeight    int64
	closed          bool
	usedSessionKey  bool
	sessionKeyAddr  address
	voucherPubKey   string // optional 64-char lowercase hex Ed25519 pubkey
	settledCalls    int64
}

type subRecord struct {
	id             uint64
	serviceID      uint64
	buyer          address
	paidUgnot      int64
	quotaTotal     int64
	quotaUsed      int64
	startHeight    int64
	expiryHeight   int64
	usedSessionKey bool
	sessionKeyAddr address
	voucherPubKey  string // optional 64-char lowercase hex Ed25519 pubkey
}

type settlementRecord struct {
	id            uint64
	serviceID     uint64
	passID        uint64
	buyer         address
	provider      address
	units         int64
	grossUgnot    int64
	discountBps   int64
	netUgnot      int64
	nonce         string
	resourceHash  string
	commitment    string
	claimedHeight int64
	challengeEnd  int64
	status        string
	disputeReason string
	receiptID     uint64
	buyerSigned   bool
}

type receiptRecord struct {
	id           uint64
	rail         string
	serviceID    uint64
	passID       uint64
	subID        uint64
	settlementID uint64
	buyer        address
	provider     address
	units        int64
	amountUgnot  int64
	nonce        string
	resourceHash string
	commitment   string
	txHash       string
	height       int64
	buyerSigned  bool
}

// Public read-only value views (no mutable pointers ever exposed).

type ServiceView struct {
	ID                  uint64
	Slug                string
	Name                string
	Description         string
	EndpointURL         string
	Owner               address
	PayTo               address
	UnitPriceUgnot      int64
	SubPriceUgnot       int64
	SubBlocks           int64
	SubQuota            int64
	ChallengeBlocks     int64
	Paused              bool
	CreatedHeight       int64
	TotalCalls          int64
	EscrowedRevenue     int64
	X402AttestedRevenue int64
}

type PassView struct {
	ID              uint64
	ServiceID       uint64
	Buyer           address
	DepositUgnot    int64
	SpentUgnot      int64
	PendingUgnot    int64
	AvailableUgnot  int64
	MaxPerCallUgnot int64
	ExpiryHeight    int64
	OpenedHeight    int64
	Closed          bool
	UsedSessionKey  bool
	SessionKeyAddr  address
	VoucherPubKey   string
	SettledCalls    int64
}

type SubscriptionView struct {
	ID             uint64
	ServiceID      uint64
	Buyer          address
	PaidUgnot      int64
	QuotaTotal     int64
	QuotaUsed      int64
	QuotaRemaining int64
	StartHeight    int64
	ExpiryHeight   int64
	Active         bool
	VoucherPubKey  string
}

type SettlementView struct {
	ID            uint64
	ServiceID     uint64
	PassID        uint64
	Buyer         address
	Provider      address
	Units         int64
	GrossUgnot    int64
	DiscountBps   int64
	NetUgnot      int64
	Nonce         string
	ResourceHash  string
	Commitment    string
	ClaimedHeight int64
	ChallengeEnd  int64
	Status        string
	DisputeReason string
	ReceiptID     uint64
	BuyerSigned   bool
}

type ReceiptView struct {
	ID               uint64
	Rail             string
	ServiceID        uint64
	PassID           uint64
	SubID            uint64
	SettlementID     uint64
	SettlementStatus string
	Buyer            address
	Provider         address
	Units            int64
	AmountUgnot      int64
	Nonce            string
	ResourceHash     string
	Commitment       string
	TxHash           string
	Height           int64
	BuyerSigned      bool
}

// All realm state is strictly unexported (zero GLOBAL001 violations).
var (
	services         = avl.NewTree()
	slugIndex        = avl.NewTree()
	passes           = avl.NewTree()
	subs             = avl.NewTree()
	settlements      = avl.NewTree()
	receipts         = avl.NewTree()
	receiptHashIndex = avl.NewTree()
	nonceUsed        = avl.NewTree()

	nextServiceID    seqid.ID
	nextPassID       seqid.ID
	nextSubID        seqid.ID
	nextSettlementID seqid.ID
	nextReceiptID    seqid.ID

	activePassesCount      int64
	totalDepositedUgnot    int64
	totalSettledUgnot      int64
	totalRefundedUgnot     int64
	totalX402AnchoredUgnot int64
	totalSubRevenueUgnot   int64
)
