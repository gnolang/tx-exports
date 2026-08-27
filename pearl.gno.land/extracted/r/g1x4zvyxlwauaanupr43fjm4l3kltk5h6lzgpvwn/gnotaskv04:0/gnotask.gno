package gnotaskv04

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

const (
	StatusAwaitingProvider = "AwaitingProvider"
	StatusActive           = "Active"
	StatusSubmitted        = "Submitted"
	StatusChangesRequested = "ChangesRequested"
	StatusDisputed         = "Disputed"
	StatusPaid             = "Paid"
	StatusRefunded         = "Refunded"
	StatusCancelled        = "Cancelled"

	NativeRewardDenom      = "ugnot"
	MinReviewWindowSeconds = int64(24 * 60 * 60)
	MaxReviewWindowSeconds = int64(30 * 24 * 60 * 60)
)

// Order is one independently funded fixed-price PhaseOrder. A Project may
// reference several Orders off-chain, but this Realm never pools future-stage
// money or promises that another Order will be funded.
type Order struct {
	ID                      string
	Employer                address
	Provider                address
	Operator                address
	SpecHash                string
	RewardAmount            int64
	RewardDenom             string
	DeliveryDueAt           time.Time
	ReviewWindowSeconds     int64
	ReviewDeadline          time.Time
	Status                  string
	RevisionRequests        int
	EvidenceHash            string
	ReviewHash              string
	DisputeHash             string
	ResolutionHash          string
	DisputeOpenedBy         address
	EmployerCancelConfirmed bool
	ProviderCancelConfirmed bool
	Escrowed                bool
	ReleaseReason           string
}

var (
	orders   = make(map[string]*Order)
	orderIDs []string
)

func requireDirectUser(cur realm) address {
	previous := cur.Previous()
	if !previous.IsUserCall() {
		panic("direct user call required")
	}
	return previous.Address()
}

func requireOrder(orderID string) *Order {
	order := orders[orderID]
	if order == nil {
		panic("order not found")
	}
	return order
}

func requireEmployer(order *Order, caller address) {
	if order.Employer != caller {
		panic("only employer")
	}
}

func requireProvider(order *Order, caller address) {
	if order.Provider != caller {
		panic("only selected provider")
	}
}

func requireParty(order *Order, caller address) {
	if order.Employer != caller && order.Provider != caller {
		panic("only order party")
	}
}

func requireOrderID(orderID string) {
	if len(orderID) == 0 || len(orderID) > 64 {
		panic("invalid order id")
	}
	for index := 0; index < len(orderID); index++ {
		char := orderID[index]
		valid := char >= 'a' && char <= 'z' || char >= '0' && char <= '9' || char == '-' || char == '_'
		if !valid {
			panic("invalid order id")
		}
	}
}

func requireHash(value, field string) {
	if len(value) != 64 {
		panic(field + " must be a lowercase sha256 hash")
	}
	for index := 0; index < len(value); index++ {
		char := value[index]
		if !(char >= '0' && char <= '9' || char >= 'a' && char <= 'f') {
			panic(field + " must be a lowercase sha256 hash")
		}
	}
}

func requireExactEscrow(rewardAmount int64, rewardDenom string) {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != rewardDenom || sent[0].Amount != rewardAmount {
		panic("exact reward must be attached")
	}
}

func settleEscrow(cur realm, order *Order, recipient address, reason, terminalStatus string) {
	if !order.Escrowed {
		panic("reward is not escrowed")
	}
	order.Escrowed = false
	order.ReleaseReason = reason
	order.Status = terminalStatus
	coins := chain.Coins{{Denom: order.RewardDenom, Amount: order.RewardAmount}}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), recipient, coins)
}

// CreateOrder locks the exact GNOT price for one mutually confirmed
// gnotask-spec-v3 Agreement. The Operator is fixed before funding and cannot
// be replaced during a dispute.
func CreateOrder(
	cur realm,
	orderID string,
	specHash string,
	rewardAmount int64,
	rewardDenom string,
	deliveryDueUnix int64,
	reviewWindowSeconds int64,
	provider address,
	operator address,
) {
	employer := requireDirectUser(cur)
	requireOrderID(orderID)
	if orders[orderID] != nil {
		panic("order already exists")
	}
	requireHash(specHash, "spec hash")
	if rewardAmount <= 0 {
		panic("reward must be positive")
	}
	if rewardDenom != NativeRewardDenom {
		panic("only ugnot rewards are supported")
	}
	if deliveryDueUnix <= time.Now().Unix() {
		panic("delivery deadline must be in the future")
	}
	if reviewWindowSeconds < MinReviewWindowSeconds || reviewWindowSeconds > MaxReviewWindowSeconds {
		panic("invalid review window")
	}
	if !provider.IsValid() || provider == employer {
		panic("invalid provider")
	}
	if !operator.IsValid() || operator == employer || operator == provider {
		panic("invalid operator")
	}
	requireExactEscrow(rewardAmount, rewardDenom)

	orders[orderID] = &Order{
		ID:                  orderID,
		Employer:            employer,
		Provider:            provider,
		Operator:            operator,
		SpecHash:            specHash,
		RewardAmount:        rewardAmount,
		RewardDenom:         rewardDenom,
		DeliveryDueAt:       time.Unix(deliveryDueUnix, 0),
		ReviewWindowSeconds: reviewWindowSeconds,
		Status:              StatusAwaitingProvider,
		Escrowed:            true,
	}
	orderIDs = append(orderIDs, orderID)
	chain.Emit("OrderCreated",
		"order_id", orderID,
		"employer", employer.String(),
		"provider", provider.String(),
		"operator", operator.String(),
		"spec_hash", specHash,
	)
	chain.Emit("FundingLocked",
		"order_id", orderID,
		"amount", strconv.FormatInt(rewardAmount, 10),
		"denom", rewardDenom,
		"delivery_due_unix", strconv.FormatInt(deliveryDueUnix, 10),
	)
}

// CancelBeforeProviderAcceptance refunds the Employer if the selected
// Provider has not yet accepted the funded Order from the bound address.
func CancelBeforeProviderAcceptance(cur realm, orderID string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	requireEmployer(order, caller)
	if order.Status != StatusAwaitingProvider {
		panic("provider has already accepted the order")
	}
	settleEscrow(cur, order, order.Employer, "employer_cancelled_before_provider_acceptance", StatusCancelled)
	chain.Emit("OrderCancelled", "order_id", orderID)
	chain.Emit("RewardRefunded", "order_id", orderID, "reason", order.ReleaseReason)
}

// AcceptOrder is the selected Provider's own on-chain address confirmation.
func AcceptOrder(cur realm, orderID string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	requireProvider(order, caller)
	if order.Status != StatusAwaitingProvider {
		panic("order is not awaiting provider")
	}
	order.Status = StatusActive
	chain.Emit("ProviderAccepted", "order_id", orderID, "provider", caller.String())
}

// ConfirmMutualCancel records either party's direct confirmation. It moves no
// money until both bound addresses have confirmed and no submission exists.
func ConfirmMutualCancel(cur realm, orderID string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	if order.Status != StatusActive || order.EvidenceHash != "" {
		panic("mutual cancellation is only available before first submission")
	}
	requireParty(order, caller)
	if caller == order.Employer {
		order.EmployerCancelConfirmed = true
	} else {
		order.ProviderCancelConfirmed = true
	}
	chain.Emit("MutualCancelConfirmed", "order_id", orderID, "party", caller.String())
	if !order.EmployerCancelConfirmed || !order.ProviderCancelConfirmed {
		return
	}
	settleEscrow(cur, order, order.Employer, "mutual_cancel_before_submission", StatusCancelled)
	chain.Emit("OrderCancelled", "order_id", orderID)
	chain.Emit("RewardRefunded", "order_id", orderID, "reason", order.ReleaseReason)
}

func SubmitEvidence(cur realm, orderID, evidenceHash string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	requireProvider(order, caller)
	if order.Status != StatusActive && order.Status != StatusChangesRequested {
		panic("order does not accept evidence")
	}
	now := time.Now()
	if order.Status == StatusActive && !now.Before(order.DeliveryDueAt) {
		panic("delivery deadline reached")
	}
	if order.Status == StatusChangesRequested && (order.ReviewDeadline.IsZero() || !now.Before(order.ReviewDeadline)) {
		panic("revision deadline reached")
	}
	requireHash(evidenceHash, "evidence hash")
	order.EvidenceHash = evidenceHash
	order.ReviewDeadline = now.Add(time.Duration(order.ReviewWindowSeconds) * time.Second)
	order.Status = StatusSubmitted
	chain.Emit("WorkSubmitted",
		"order_id", orderID,
		"provider", caller.String(),
		"evidence_hash", evidenceHash,
		"review_deadline_unix", strconv.FormatInt(order.ReviewDeadline.Unix(), 10),
	)
}

func Review(cur realm, orderID string, accept bool, reviewHash string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	requireEmployer(order, caller)
	if order.Status != StatusSubmitted {
		panic("order is not submitted")
	}
	requireHash(reviewHash, "review hash")
	now := time.Now()
	if !accept && (order.ReviewDeadline.IsZero() || !now.Before(order.ReviewDeadline)) {
		panic("review deadline reached")
	}
	order.ReviewHash = reviewHash
	if accept {
		settleEscrow(cur, order, order.Provider, "employer_accepted", StatusPaid)
		chain.Emit("OrderAccepted", "order_id", orderID, "review_hash", reviewHash)
		chain.Emit("RewardReleased", "order_id", orderID, "provider", order.Provider.String(), "reason", order.ReleaseReason)
		return
	}
	if order.RevisionRequests >= 1 {
		panic("revision limit reached")
	}
	order.RevisionRequests++
	order.ReviewDeadline = now.Add(time.Duration(order.ReviewWindowSeconds) * time.Second)
	order.Status = StatusChangesRequested
	chain.Emit("ChangesRequested", "order_id", orderID, "review_hash", reviewHash)
}

// OpenDispute must happen before the current review or revision deadline. The
// Disputed status freezes review-timeout claims, refunds, and Review calls.
func OpenDispute(cur realm, orderID, disputeHash string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	requireParty(order, caller)
	if order.Status != StatusSubmitted && order.Status != StatusChangesRequested {
		panic("order is not disputable")
	}
	if order.ReviewDeadline.IsZero() || !time.Now().Before(order.ReviewDeadline) {
		panic("dispute deadline reached")
	}
	requireHash(disputeHash, "dispute hash")
	order.DisputeHash = disputeHash
	order.DisputeOpenedBy = caller
	order.Status = StatusDisputed
	chain.Emit("DisputeOpened", "order_id", orderID, "opened_by", caller.String(), "dispute_hash", disputeHash)
}

// ResolveDispute deliberately supports only all-or-nothing outcomes in v0.4.
func ResolveDispute(cur realm, orderID string, releaseToProvider bool, resolutionHash string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	if caller != order.Operator {
		panic("only operator")
	}
	if order.Status != StatusDisputed {
		panic("order is not disputed")
	}
	requireHash(resolutionHash, "resolution hash")
	order.ResolutionHash = resolutionHash
	if releaseToProvider {
		settleEscrow(cur, order, order.Provider, "dispute_released_to_provider", StatusPaid)
		chain.Emit("DisputeResolved", "order_id", orderID, "outcome", "release_all", "resolution_hash", resolutionHash)
		chain.Emit("RewardReleased", "order_id", orderID, "provider", order.Provider.String(), "reason", order.ReleaseReason)
		return
	}
	settleEscrow(cur, order, order.Employer, "dispute_refunded_to_employer", StatusRefunded)
	chain.Emit("DisputeResolved", "order_id", orderID, "outcome", "refund_all", "resolution_hash", resolutionHash)
	chain.Emit("RewardRefunded", "order_id", orderID, "reason", order.ReleaseReason)
}

func ClaimAfterReviewDeadline(cur realm, orderID string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	requireProvider(order, caller)
	if order.Status != StatusSubmitted {
		panic("order is not awaiting review")
	}
	if order.ReviewDeadline.IsZero() || time.Now().Before(order.ReviewDeadline) {
		panic("review deadline not reached")
	}
	settleEscrow(cur, order, order.Provider, "review_timeout", StatusPaid)
	chain.Emit("RewardReleased", "order_id", orderID, "provider", order.Provider.String(), "reason", order.ReleaseReason)
}

func RefundExpiredOrder(cur realm, orderID string) {
	caller := requireDirectUser(cur)
	order := requireOrder(orderID)
	requireEmployer(order, caller)
	if order.Status != StatusActive && order.Status != StatusChangesRequested {
		panic("order is not refundable after delivery timeout")
	}
	deadline := order.DeliveryDueAt
	if order.Status == StatusChangesRequested {
		deadline = order.ReviewDeadline
	}
	if deadline.IsZero() || time.Now().Before(deadline) {
		panic("delivery deadline not reached")
	}
	settleEscrow(cur, order, order.Employer, "delivery_timeout", StatusRefunded)
	chain.Emit("RewardRefunded", "order_id", orderID, "reason", order.ReleaseReason)
}

func OrderCount() int {
	return len(orderIDs)
}

// GetOrderState is a compact query response consumed by the v0.4 API verifier.
func GetOrderState(orderID string) string {
	order := requireOrder(orderID)
	disputeOpenedBy := ""
	if order.DisputeOpenedBy.IsValid() {
		disputeOpenedBy = order.DisputeOpenedBy.String()
	}
	reviewDeadlineUnix := int64(0)
	if !order.ReviewDeadline.IsZero() {
		reviewDeadlineUnix = order.ReviewDeadline.Unix()
	}
	return strings.Join([]string{
		order.ID,
		order.Employer.String(),
		order.Provider.String(),
		order.Operator.String(),
		order.Status,
		order.SpecHash,
		strconv.FormatInt(order.RewardAmount, 10),
		order.RewardDenom,
		strconv.FormatInt(order.DeliveryDueAt.Unix(), 10),
		strconv.FormatInt(order.ReviewWindowSeconds, 10),
		strconv.FormatInt(reviewDeadlineUnix, 10),
		strconv.Itoa(order.RevisionRequests),
		order.EvidenceHash,
		order.ReviewHash,
		order.DisputeHash,
		order.ResolutionHash,
		disputeOpenedBy,
		strconv.FormatBool(order.EmployerCancelConfirmed),
		strconv.FormatBool(order.ProviderCancelConfirmed),
		strconv.FormatBool(order.Escrowed),
		order.ReleaseReason,
	}, "|")
}

func Render(path string) string {
	orderID := strings.TrimPrefix(path, "/")
	if orderID == "" {
		return "# GnoTask v0.4\n\nIndependently funded GNOT service Orders.\n\nOn-chain Orders: **" + strconv.Itoa(len(orderIDs)) + "**"
	}
	order := requireOrder(orderID)
	escrow := "Released"
	if order.Escrowed {
		escrow = "Locked in Realm"
	}
	return "# Order `" + order.ID + "`\n\n" +
		"- Status: **" + order.Status + "**\n" +
		"- Escrow: **" + escrow + "**\n" +
		"- Employer: `" + order.Employer.String() + "`\n" +
		"- Provider: `" + order.Provider.String() + "`\n" +
		"- Operator: `" + order.Operator.String() + "`\n" +
		"- Price: **" + strconv.FormatInt(order.RewardAmount, 10) + " " + order.RewardDenom + "**\n" +
		"- Spec hash: `" + order.SpecHash + "`"
}
