package milestone_escrow

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const (
	StatusPending   = "PENDING"
	StatusSubmitted = "SUBMITTED"
	StatusReleased  = "RELEASED"
	StatusDisputed  = "DISPUTED"
	StatusResolved  = "RESOLVED"
	StatusRefunded  = "REFUNDED"

	ContractActive    = "ACTIVE"
	ContractCompleted = "COMPLETED"
	ContractCancelled = "CANCELLED"

	MaxMilestonesPerContract = 12
	MaxBasisPoints           = 10000
	DenomUgnot               = "ugnot"
)

type Milestone struct {
	Index           int
	Title           string
	AmountUgnot     int64
	Status          string
	ProofURI        string
	DisputeReason   string
	ContractorPaid  int64
	ClientRefunded  int64
	CreatedAtHeight int64
	UpdatedAtHeight int64
}

type EscrowContract struct {
	ID              uint64
	Title           string
	Client          address
	Contractor      address
	Arbiter         address
	TotalUgnot      int64
	ReleasedUgnot   int64
	RefundedUgnot   int64
	Status          string
	CreatedAtHeight int64
	Milestones      []*Milestone
}

var (
	nextContractID     uint64 = 1
	contracts          []*EscrowContract
	contractsByID      = make(map[uint64]*EscrowContract)
	totalDeposited     int64
	totalReleased      int64
	totalRefunded      int64
	totalDisputesCount int
)

// CreateContract locks an exact ugnot deposit covering all milestones.
// milestoneTitlesCsv and milestoneAmountsCsv are comma-separated lists of equal length.
func CreateContract(
	cur realm,
	title string,
	contractorAddr string,
	arbiterAddr string,
	milestoneTitlesCsv string,
	milestoneAmountsCsv string,
) uint64 {
	if !cur.Previous().IsUser() {
		panic("CreateContract must be called directly by a user account")
	}

	title = strings.TrimSpace(title)
	if title == "" {
		panic("contract title must not be empty")
	}

	client := cur.Previous().Address()
	contractor := address(strings.TrimSpace(contractorAddr))
	if !contractor.IsValid() {
		panic("invalid contractor address")
	}
	if contractor == client {
		panic("client and contractor must be distinct addresses")
	}

	var arbiter address
	arbiterTrimmed := strings.TrimSpace(arbiterAddr)
	if arbiterTrimmed != "" {
		arbiter = address(arbiterTrimmed)
		if !arbiter.IsValid() {
			panic("invalid arbiter address")
		}
		if arbiter == client || arbiter == contractor {
			panic("arbiter must be distinct from client and contractor")
		}
	}

	rawTitles := strings.Split(milestoneTitlesCsv, ",")
	rawAmounts := strings.Split(milestoneAmountsCsv, ",")
	if len(rawTitles) == 0 || len(rawTitles) != len(rawAmounts) {
		panic("milestone titles and amounts must be non-empty and equal length")
	}
	if len(rawTitles) > MaxMilestonesPerContract {
		panic("too many milestones")
	}

	height := runtime.ChainHeight()
	milestones := make([]*Milestone, 0, len(rawTitles))
	var expectedTotal int64

	for i := 0; i < len(rawTitles); i++ {
		mTitle := strings.TrimSpace(rawTitles[i])
		if mTitle == "" {
			panic("milestone title must not be empty")
		}
		amt, err := strconv.ParseInt(strings.TrimSpace(rawAmounts[i]), 10, 64)
		if err != nil || amt <= 0 {
			panic("each milestone amount must be a positive integer in ugnot")
		}
		expectedTotal += amt
		milestones = append(milestones, &Milestone{
			Index:           i,
			Title:           mTitle,
			AmountUgnot:     amt,
			Status:          StatusPending,
			CreatedAtHeight: height,
			UpdatedAtHeight: height,
		})
	}

	sent := unsafe.OriginSend()
	deposited := sent.AmountOf(DenomUgnot)
	if deposited != expectedTotal {
		panic(
			"exact ugnot deposit required: expected " +
				strconv.FormatInt(expectedTotal, 10) +
				"ugnot, got " +
				strconv.FormatInt(deposited, 10) +
				"ugnot",
		)
	}

	id := nextContractID
	nextContractID++

	c := &EscrowContract{
		ID:              id,
		Title:           title,
		Client:          client,
		Contractor:      contractor,
		Arbiter:         arbiter,
		TotalUgnot:      expectedTotal,
		Status:          ContractActive,
		CreatedAtHeight: height,
		Milestones:      milestones,
	}

	contracts = append(contracts, c)
	contractsByID[id] = c
	totalDeposited += expectedTotal

	chain.Emit(
		"ContractCreated",
		"contract_id", strconv.FormatUint(id, 10),
		"client", client.String(),
		"contractor", contractor.String(),
		"total_ugnot", strconv.FormatInt(expectedTotal, 10),
		"milestones", strconv.Itoa(len(milestones)),
	)

	return id
}

// SubmitMilestone records a contractor's deliverable proof URI for a pending milestone.
func SubmitMilestone(cur realm, contractID uint64, milestoneIdx int, proofURI string) {
	c := mustGetContract(contractID)
	if c.Status != ContractActive {
		panic("contract is not active")
	}
	caller := cur.Previous().Address()
	if caller != c.Contractor {
		panic("only contractor can submit milestone deliverables")
	}

	m := mustGetMilestone(c, milestoneIdx)
	if m.Status != StatusPending {
		panic("milestone is not in PENDING status")
	}
	proofURI = strings.TrimSpace(proofURI)
	if proofURI == "" {
		panic("proof URI must not be empty")
	}

	m.ProofURI = proofURI
	m.Status = StatusSubmitted
	m.UpdatedAtHeight = runtime.ChainHeight()

	chain.Emit(
		"MilestoneSubmitted",
		"contract_id", strconv.FormatUint(contractID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"contractor", caller.String(),
		"proof_uri", proofURI,
	)
}

// ApproveMilestone releases locked ugnot for a milestone to the contractor.
func ApproveMilestone(cur realm, contractID uint64, milestoneIdx int) {
	c := mustGetContract(contractID)
	if c.Status != ContractActive {
		panic("contract is not active")
	}
	caller := cur.Previous().Address()
	if caller != c.Client {
		panic("only client can approve and release milestone")
	}

	m := mustGetMilestone(c, milestoneIdx)
	if m.Status != StatusPending && m.Status != StatusSubmitted {
		panic("milestone cannot be approved from status " + m.Status)
	}

	// Checks-Effects-Interactions: update state before transferring funds.
	amount := m.AmountUgnot
	m.Status = StatusReleased
	m.ContractorPaid = amount
	m.UpdatedAtHeight = runtime.ChainHeight()
	c.ReleasedUgnot += amount
	totalReleased += amount
	refreshContractStatus(c)

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), c.Contractor, chain.NewCoins(chain.NewCoin(DenomUgnot, amount)))

	chain.Emit(
		"MilestoneReleased",
		"contract_id", strconv.FormatUint(contractID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"to", c.Contractor.String(),
		"amount_ugnot", strconv.FormatInt(amount, 10),
	)
}

// OpenDispute freezes a pending or submitted milestone for arbiter review.
func OpenDispute(cur realm, contractID uint64, milestoneIdx int, reason string) {
	c := mustGetContract(contractID)
	if c.Status != ContractActive {
		panic("contract is not active")
	}
	if !c.Arbiter.IsValid() {
		panic("contract has no designated arbiter")
	}
	caller := cur.Previous().Address()
	if caller != c.Client && caller != c.Contractor {
		panic("only client or contractor can open a dispute")
	}

	m := mustGetMilestone(c, milestoneIdx)
	if m.Status != StatusPending && m.Status != StatusSubmitted {
		panic("milestone cannot be disputed from status " + m.Status)
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		panic("dispute reason must not be empty")
	}

	m.Status = StatusDisputed
	m.DisputeReason = reason
	m.UpdatedAtHeight = runtime.ChainHeight()
	totalDisputesCount++

	chain.Emit(
		"DisputeOpened",
		"contract_id", strconv.FormatUint(contractID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"opened_by", caller.String(),
		"reason", reason,
	)
}

// ResolveDispute lets the designated arbiter split a disputed milestone by basis points (0..10000) to contractor.
func ResolveDispute(cur realm, contractID uint64, milestoneIdx int, contractorBps int) {
	c := mustGetContract(contractID)
	if c.Status != ContractActive {
		panic("contract is not active")
	}
	caller := cur.Previous().Address()
	if !c.Arbiter.IsValid() || caller != c.Arbiter {
		panic("only designated arbiter can resolve dispute")
	}
	if contractorBps < 0 || contractorBps > MaxBasisPoints {
		panic("contractorBps must be between 0 and 10000")
	}

	m := mustGetMilestone(c, milestoneIdx)
	if m.Status != StatusDisputed {
		panic("milestone is not disputed")
	}

	amount := m.AmountUgnot
	contractorShare := (amount * int64(contractorBps)) / int64(MaxBasisPoints)
	clientRefund := amount - contractorShare

	// Update state before external coin transfers.
	m.Status = StatusResolved
	m.ContractorPaid = contractorShare
	m.ClientRefunded = clientRefund
	m.UpdatedAtHeight = runtime.ChainHeight()
	c.ReleasedUgnot += contractorShare
	c.RefundedUgnot += clientRefund
	totalReleased += contractorShare
	totalRefunded += clientRefund
	refreshContractStatus(c)

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if contractorShare > 0 {
		b.SendCoins(cur.Address(), c.Contractor, chain.NewCoins(chain.NewCoin(DenomUgnot, contractorShare)))
	}
	if clientRefund > 0 {
		b.SendCoins(cur.Address(), c.Client, chain.NewCoins(chain.NewCoin(DenomUgnot, clientRefund)))
	}

	chain.Emit(
		"DisputeResolved",
		"contract_id", strconv.FormatUint(contractID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"contractor_ugnot", strconv.FormatInt(contractorShare, 10),
		"client_refund_ugnot", strconv.FormatInt(clientRefund, 10),
	)
}

// CancelUnstarted refunds all remaining PENDING milestones to the client when no work is submitted or disputed.
func CancelUnstarted(cur realm, contractID uint64) {
	c := mustGetContract(contractID)
	if c.Status != ContractActive {
		panic("contract is not active")
	}
	caller := cur.Previous().Address()
	if caller != c.Client {
		panic("only client can cancel unstarted milestones")
	}

	var refundAmount int64
	for _, m := range c.Milestones {
		if m.Status == StatusSubmitted || m.Status == StatusDisputed {
			panic("cannot cancel while a milestone is SUBMITTED or DISPUTED")
		}
		if m.Status == StatusPending {
			refundAmount += m.AmountUgnot
		}
	}
	if refundAmount == 0 {
		panic("no pending milestones to refund")
	}

	height := runtime.ChainHeight()
	for _, m := range c.Milestones {
		if m.Status == StatusPending {
			m.Status = StatusRefunded
			m.ClientRefunded = m.AmountUgnot
			m.UpdatedAtHeight = height
		}
	}
	c.RefundedUgnot += refundAmount
	c.Status = ContractCancelled
	totalRefunded += refundAmount

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), c.Client, chain.NewCoins(chain.NewCoin(DenomUgnot, refundAmount)))

	chain.Emit(
		"ContractCancelled",
		"contract_id", strconv.FormatUint(contractID, 10),
		"client", c.Client.String(),
		"refund_ugnot", strconv.FormatInt(refundAmount, 10),
	)
}

func ContractCount() int {
	return len(contracts)
}

func LockedBalanceUgnot() int64 {
	return totalDeposited - totalReleased - totalRefunded
}

func mustGetContract(id uint64) *EscrowContract {
	c, ok := contractsByID[id]
	if !ok {
		panic("contract not found: " + strconv.FormatUint(id, 10))
	}
	return c
}

func mustGetMilestone(c *EscrowContract, idx int) *Milestone {
	if idx < 0 || idx >= len(c.Milestones) {
		panic("milestone index out of range")
	}
	return c.Milestones[idx]
}

func refreshContractStatus(c *EscrowContract) {
	for _, m := range c.Milestones {
		if m.Status == StatusPending || m.Status == StatusSubmitted || m.Status == StatusDisputed {
			return
		}
	}
	c.Status = ContractCompleted
}
