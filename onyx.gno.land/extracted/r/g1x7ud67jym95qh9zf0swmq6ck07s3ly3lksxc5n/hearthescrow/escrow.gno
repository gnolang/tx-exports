package hearthescrow

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	nextID        seqid.ID
	escrows       *avl.Tree // seqid.ID.String() -> *Escrow
	addressIndex  *avl.Tree // address.String() -> []uint64
	stats         Stats
	realmPkgPath  string
	realmLinkBase string
)

func init() {
	escrows = avl.NewTree()
	addressIndex = avl.NewTree()
	realmPkgPath = unsafe.CurrentRealm().PkgPath()
	if realmPkgPath == "" {
		realmPkgPath = "gno.land/r/g1x7ud67jym95qh9zf0swmq6ck07s3ly3lksxc5n/hearthescrow"
	}
	realmLinkBase = strings.TrimPrefix(realmPkgPath, runtime.ChainDomain())
	if realmLinkBase == "" {
		realmLinkBase = "/r/g1x7ud67jym95qh9zf0swmq6ck07s3ly3lksxc5n/hearthescrow"
	}
}

// CreateEscrow locks the attached ugnot deposit into a new milestone escrow.
// milestoneTitles and milestoneBps are comma-separated lists of equal length;
// basis points must each be positive and sum to exactly 10000 (100%).
// Pass an empty arbiter address ("") if no dispute arbiter is desired.
func CreateEscrow(
	cur realm,
	title string,
	recipient address,
	arbiter address,
	deadlineHeight int64,
	milestoneTitles string,
	milestoneBps string,
) uint64 {
	if !cur.Previous().IsUserCall() {
		panic(ErrDirectUserCallRequired)
	}

	depositor := cur.Previous().Address()
	title = strings.TrimSpace(title)
	if len(title) == 0 || len(title) > MaxTitleLen {
		panic(ErrInvalidTitle)
	}
	if !recipient.IsValid() {
		panic(ErrInvalidRecipient)
	}
	if recipient == depositor {
		panic(ErrSelfEscrow)
	}
	if arbiter != "" {
		if !arbiter.IsValid() || arbiter == depositor || arbiter == recipient {
			panic(ErrInvalidArbiter)
		}
	}

	nowHeight := runtime.ChainHeight()
	if deadlineHeight <= nowHeight {
		panic(ErrInvalidDeadline)
	}

	milestones := parseMilestones(milestoneTitles, milestoneBps)

	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != DenomUGNOT || sent[0].Amount <= 0 {
		panic(ErrInvalidDeposit)
	}
	amount := sent[0].Amount
	if amount > MaxEscrowAmount {
		panic(ErrDepositTooLarge)
	}

	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if b.GetCoin(realmAddr, DenomUGNOT) < stats.TotalLocked+amount {
		panic(ErrInsufficientRealmBalance)
	}

	id := uint64(nextID.Next())
	e := &Escrow{
		ID:             id,
		Title:          title,
		Depositor:      depositor,
		Recipient:      recipient,
		Arbiter:        arbiter,
		TotalAmount:    amount,
		CreatedHeight:  nowHeight,
		DeadlineHeight: deadlineHeight,
		Status:         StatusActive,
		Milestones:     milestones,
	}

	escrows.Set(seqid.ID(id).String(), e)
	indexAddress(depositor, id)
	indexAddress(recipient, id)
	if arbiter != "" {
		indexAddress(arbiter, id)
	}

	stats.TotalEscrows++
	stats.ActiveCount++
	stats.TotalLocked += amount

	chain.Emit(
		"EscrowCreated",
		"id", strconv.FormatUint(id, 10),
		"depositor", depositor.String(),
		"recipient", recipient.String(),
		"arbiter", arbiter.String(),
		"amount", strconv.FormatInt(amount, 10),
		"deadline", strconv.FormatInt(deadlineHeight, 10),
		"milestones", strconv.Itoa(len(milestones)),
	)

	return id
}

// SubmitMilestone lets the recipient submit a deliverable note or URI for a pending milestone.
func SubmitMilestone(cur realm, id uint64, milestoneIndex int, deliverable string) {
	e := mustGetEscrow(id)
	caller := cur.Previous().Address()
	if caller != e.Recipient {
		panic(ErrUnauthorized)
	}
	if e.Status != StatusActive {
		panic(ErrEscrowNotActive)
	}
	if milestoneIndex < 0 || milestoneIndex >= len(e.Milestones) {
		panic(ErrMilestoneOutOfRange)
	}

	deliverable = strings.TrimSpace(deliverable)
	if len(deliverable) == 0 || len(deliverable) > MaxDeliverable {
		panic(ErrInvalidDeliverable)
	}

	m := &e.Milestones[milestoneIndex]
	if m.Status != MilestonePending {
		panic(ErrMilestoneNotPending)
	}

	m.Status = MilestoneSubmitted
	m.Deliverable = deliverable
	m.SubmittedHeight = runtime.ChainHeight()

	chain.Emit(
		"MilestoneSubmitted",
		"id", strconv.FormatUint(id, 10),
		"milestone", strconv.Itoa(milestoneIndex),
		"recipient", caller.String(),
	)
}

// ApproveMilestone lets the depositor approve a milestone and release its ugnot tranche to the recipient.
// Approving the final unapproved milestone sweeps any integer-division remainder so zero dust is trapped.
func ApproveMilestone(cur realm, id uint64, milestoneIndex int) int64 {
	e := mustGetEscrow(id)
	caller := cur.Previous().Address()
	if caller != e.Depositor {
		panic(ErrUnauthorized)
	}
	if e.Status != StatusActive {
		panic(ErrEscrowNotActive)
	}
	if milestoneIndex < 0 || milestoneIndex >= len(e.Milestones) {
		panic(ErrMilestoneOutOfRange)
	}

	m := &e.Milestones[milestoneIndex]
	if m.Status == MilestoneApproved {
		panic(ErrMilestoneAlreadyApproved)
	}

	remaining := e.RemainingAmount()
	if remaining <= 0 {
		panic(ErrNothingToRelease)
	}

	unapprovedBefore := len(e.Milestones) - e.ApprovedCount()
	var payout int64
	if unapprovedBefore == 1 {
		payout = remaining
	} else {
		payout = (e.TotalAmount * m.Bps) / BasisPointsTotal
		if payout > remaining {
			payout = remaining
		}
	}

	nowHeight := runtime.ChainHeight()
	// Effects before interactions (CEI)
	m.Status = MilestoneApproved
	m.ApprovedHeight = nowHeight
	m.PaidAmount = payout
	e.ReleasedAmount += payout
	stats.TotalLocked -= payout
	stats.TotalReleased += payout

	completed := unapprovedBefore == 1
	if completed {
		e.Status = StatusCompleted
		e.ClosedHeight = nowHeight
		stats.ActiveCount--
		stats.CompletedCount++
	}

	chain.Emit(
		"MilestoneApproved",
		"id", strconv.FormatUint(id, 10),
		"milestone", strconv.Itoa(milestoneIndex),
		"payout", strconv.FormatInt(payout, 10),
		"recipient", e.Recipient.String(),
	)
	if completed {
		chain.Emit(
			"EscrowCompleted",
			"id", strconv.FormatUint(id, 10),
			"total_released", strconv.FormatInt(e.ReleasedAmount, 10),
		)
	}

	if payout > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), e.Recipient, chain.NewCoins(chain.NewCoin(DenomUGNOT, payout)))
	}

	return payout
}

// OpenDispute freezes an active escrow for arbiter resolution. Either depositor or recipient may call it.
func OpenDispute(cur realm, id uint64, reason string) {
	e := mustGetEscrow(id)
	caller := cur.Previous().Address()
	if caller != e.Depositor && caller != e.Recipient {
		panic(ErrUnauthorized)
	}
	if e.Status != StatusActive {
		panic(ErrEscrowNotActive)
	}
	if e.Arbiter == "" {
		panic(ErrNoArbiter)
	}
	if e.RemainingAmount() <= 0 {
		panic(ErrNothingToRelease)
	}

	reason = strings.TrimSpace(reason)
	if len(reason) == 0 || len(reason) > MaxNoteLen {
		panic(ErrInvalidDisputeReason)
	}

	nowHeight := runtime.ChainHeight()
	e.Status = StatusDisputed
	e.Dispute = &DisputeRecord{
		OpenedBy:     caller,
		Reason:       reason,
		OpenedHeight: nowHeight,
	}
	stats.ActiveCount--
	stats.DisputedCount++

	chain.Emit(
		"DisputeOpened",
		"id", strconv.FormatUint(id, 10),
		"opened_by", caller.String(),
		"arbiter", e.Arbiter.String(),
	)
}

// ResolveDispute lets the designated arbiter split all remaining locked funds between
// recipient (recipientBps out of 10000) and depositor (the remainder).
func ResolveDispute(cur realm, id uint64, recipientBps int64, resolutionNote string) (int64, int64) {
	e := mustGetEscrow(id)
	caller := cur.Previous().Address()
	if e.Arbiter == "" || caller != e.Arbiter {
		panic(ErrUnauthorized)
	}
	if e.Status != StatusDisputed {
		panic(ErrEscrowNotDisputed)
	}
	if recipientBps < 0 || recipientBps > BasisPointsTotal {
		panic(ErrInvalidSplitBps)
	}

	resolutionNote = strings.TrimSpace(resolutionNote)
	if len(resolutionNote) > MaxNoteLen {
		panic(ErrInvalidResolutionNote)
	}

	remaining := e.RemainingAmount()
	if remaining <= 0 {
		panic(ErrNothingToRelease)
	}

	recipientShare := (remaining * recipientBps) / BasisPointsTotal
	depositorShare := remaining - recipientShare
	nowHeight := runtime.ChainHeight()

	// Effects before interactions (CEI)
	e.Status = StatusResolved
	e.ReleasedAmount += recipientShare
	e.RefundedAmount += depositorShare
	e.ClosedHeight = nowHeight
	if e.Dispute != nil {
		e.Dispute.ResolvedHeight = nowHeight
		e.Dispute.RecipientBps = recipientBps
		e.Dispute.RecipientPayout = recipientShare
		e.Dispute.DepositorRefund = depositorShare
		e.Dispute.ResolutionNote = resolutionNote
	}

	stats.TotalLocked -= remaining
	stats.TotalReleased += recipientShare
	stats.TotalRefunded += depositorShare
	stats.DisputedCount--
	stats.ResolvedCount++

	chain.Emit(
		"DisputeResolved",
		"id", strconv.FormatUint(id, 10),
		"arbiter", caller.String(),
		"recipient_bps", strconv.FormatInt(recipientBps, 10),
		"recipient_payout", strconv.FormatInt(recipientShare, 10),
		"depositor_refund", strconv.FormatInt(depositorShare, 10),
	)

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	if recipientShare > 0 {
		b.SendCoins(realmAddr, e.Recipient, chain.NewCoins(chain.NewCoin(DenomUGNOT, recipientShare)))
	}
	if depositorShare > 0 {
		b.SendCoins(realmAddr, e.Depositor, chain.NewCoins(chain.NewCoin(DenomUGNOT, depositorShare)))
	}

	return recipientShare, depositorShare
}

// ClaimRefund lets the depositor reclaim all remaining unapproved funds once deadlineHeight is reached.
// Cannot be called while a dispute is open.
func ClaimRefund(cur realm, id uint64) int64 {
	e := mustGetEscrow(id)
	caller := cur.Previous().Address()
	if caller != e.Depositor {
		panic(ErrUnauthorized)
	}
	if e.Status != StatusActive {
		panic(ErrEscrowNotActive)
	}
	if runtime.ChainHeight() < e.DeadlineHeight {
		panic(ErrDeadlineNotReached)
	}

	remaining := e.RemainingAmount()
	if remaining <= 0 {
		panic(ErrNothingToRelease)
	}

	nowHeight := runtime.ChainHeight()
	// Effects before interactions (CEI)
	e.Status = StatusRefunded
	e.RefundedAmount += remaining
	e.ClosedHeight = nowHeight
	stats.TotalLocked -= remaining
	stats.TotalRefunded += remaining
	stats.ActiveCount--
	stats.RefundedCount++

	chain.Emit(
		"RefundClaimed",
		"id", strconv.FormatUint(id, 10),
		"depositor", e.Depositor.String(),
		"refunded", strconv.FormatInt(remaining, 10),
	)

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), e.Depositor, chain.NewCoins(chain.NewCoin(DenomUGNOT, remaining)))

	return remaining
}

// GetEscrow returns a read-only copy of an escrow by ID, or nil if not found.
func GetEscrow(id uint64) *Escrow {
	raw := escrows.Get(seqid.ID(id).String())
	if raw == nil {
		return nil
	}
	src := raw.(*Escrow)
	cp := *src
	cp.Milestones = make([]Milestone, len(src.Milestones))
	copy(cp.Milestones, src.Milestones)
	if src.Dispute != nil {
		d := *src.Dispute
		cp.Dispute = &d
	}
	return &cp
}

// GetStats returns a snapshot of protocol-wide accounting and counts.
func GetStats() Stats {
	return stats
}

// GetAddressEscrowIDs returns a copy of escrow IDs associated with addr.
func GetAddressEscrowIDs(addr address) []uint64 {
	raw := addressIndex.Get(addr.String())
	if raw == nil {
		return nil
	}
	src := raw.([]uint64)
	out := make([]uint64, len(src))
	copy(out, src)
	return out
}

func mustGetEscrow(id uint64) *Escrow {
	raw := escrows.Get(seqid.ID(id).String())
	if raw == nil {
		panic(ErrEscrowNotFound)
	}
	return raw.(*Escrow)
}

func indexAddress(addr address, id uint64) {
	key := addr.String()
	var ids []uint64
	if raw := addressIndex.Get(key); raw != nil {
		ids = raw.([]uint64)
	}
	ids = append(ids, id)
	addressIndex.Set(key, ids)
}

func parseMilestones(titlesCSV string, bpsCSV string) []Milestone {
	rawTitles := strings.Split(titlesCSV, ",")
	rawBps := strings.Split(bpsCSV, ",")
	if len(rawTitles) == 0 || len(rawTitles) > MaxMilestones || len(rawTitles) != len(rawBps) {
		panic(ErrInvalidMilestones)
	}

	milestones := make([]Milestone, len(rawTitles))
	var sumBps int64
	for i := range rawTitles {
		t := strings.TrimSpace(rawTitles[i])
		if len(t) == 0 || len(t) > MaxMilestoneLen {
			panic(ErrInvalidMilestones)
		}
		b, err := strconv.ParseInt(strings.TrimSpace(rawBps[i]), 10, 64)
		if err != nil || b <= 0 || b > BasisPointsTotal {
			panic(ErrInvalidMilestones)
		}
		sumBps += b
		milestones[i] = Milestone{
			Index:  i,
			Title:  t,
			Bps:    b,
			Status: MilestonePending,
		}
	}

	if sumBps != BasisPointsTotal {
		panic(ErrInvalidMilestones)
	}

	return milestones
}
