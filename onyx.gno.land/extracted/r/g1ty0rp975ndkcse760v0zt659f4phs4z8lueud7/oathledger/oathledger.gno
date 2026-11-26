// Package oathledger implements OathLedger: a trustless, multi-milestone native GNOT
// escrow protocol with M-of-N peer-reviewer quorums, trustless quorum dispute resolution,
// deadline auto-refunds, and an immutable Proof-of-Contribution builder reputation ledger.
package oathledger

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strings"
	"time"

	"gno.land/p/g1ty0rp975ndkcse760v0zt659f4phs4z8lueud7/escrowmath"
	"gno.land/p/nt/avl/v0"
)

var (
	pacts               avl.Tree // padID(id) -> *Pact
	builders            avl.Tree // address.String() -> *BuilderProfile
	nextPactID          int64 = 1
	totalEscrowedUgnot  int64
	activeLockedUgnot   int64
	totalReleasedUgnot  int64
	completedPactsCount int64
	disputedPactsCount  int64
)

// CreatePact locks native ugnot from the sponsor into the realm with deterministic
// milestone splits and an M-of-N reviewer quorum.
//
// Security note: Only direct user calls (maketx call) are accepted so unsafe.OriginSend()
// accurately reflects real ugnot transferred to this realm (prevents phantom-send drains).
func CreatePact(
	cur realm,
	title string,
	summary string,
	milestoneTitlesCSV string,
	splitsBpsCSV string,
	reviewersCSV string,
	quorum int,
	deadlineHours int64,
) int64 {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}

	title = strings.TrimSpace(title)
	summary = strings.TrimSpace(summary)
	if title == "" || len(title) > 120 {
		panic("title must be 1..120 characters")
	}
	if summary == "" || len(summary) > 600 {
		panic("summary must be 1..600 characters")
	}
	if deadlineHours <= 0 || deadlineHours > 24*180 {
		panic("deadlineHours must be between 1 and 4320 (180 days)")
	}

	sent := unsafe.OriginSend()
	var totalUgnot int64
	for _, c := range sent {
		if c.Denom == "ugnot" {
			totalUgnot += c.Amount
		}
	}
	if totalUgnot <= 0 {
		panic("must send positive ugnot to fund escrow")
	}

	splits, err := escrowmath.ParseSplitsBps(splitsBpsCSV)
	if err != nil {
		panic(err.Error())
	}
	rawTitles := strings.Split(milestoneTitlesCSV, ",")
	if len(rawTitles) != len(splits) {
		panic("milestone titles count must match splits count")
	}

	amounts, err := escrowmath.ComputeMilestoneAmounts(totalUgnot, splits)
	if err != nil {
		panic(err.Error())
	}

	reviewers := parseUniqueReviewers(reviewersCSV)
	if err := escrowmath.ValidateQuorum(quorum, len(reviewers)); err != nil {
		panic(err.Error())
	}

	milestones := make([]*Milestone, len(splits))
	for i := range splits {
		mt := strings.TrimSpace(rawTitles[i])
		if mt == "" {
			panic("milestone title cannot be empty")
		}
		milestones[i] = &Milestone{
			Index:       i,
			Title:       mt,
			SplitBps:    splits[i],
			AmountUgnot: amounts[i],
			Status:      MilestonePending,
		}
	}

	now := time.Now()
	id := nextPactID
	nextPactID++

	pact := &Pact{
		ID:         id,
		Title:      title,
		Summary:    summary,
		Sponsor:    cur.Previous().Address(),
		Reviewers:  reviewers,
		Quorum:     quorum,
		TotalUgnot: totalUgnot,
		Status:     StatusOpen,
		Milestones: milestones,
		CreatedAt:  now,
		Deadline:   now.Add(time.Duration(deadlineHours) * time.Hour),
	}

	pacts.Set(padID(id), pact)
	totalEscrowedUgnot += totalUgnot
	activeLockedUgnot += totalUgnot
	return id
}

// ClaimPact allows a builder (other than the sponsor) to claim an open pact.
func ClaimPact(cur realm, pactID int64) {
	pact := mustGetPact(pactID)
	if pact.Status != StatusOpen {
		panic("pact is not open")
	}
	if time.Now().After(pact.Deadline) {
		panic("pact deadline has passed")
	}

	caller := cur.Previous().Address()
	if caller == pact.Sponsor {
		panic("sponsor cannot claim own pact")
	}

	pact.Builder = caller
	pact.Status = StatusActive
	getOrCreateBuilder(caller)
}

// SubmitMilestone lets the assigned builder attach verifiable proof (commit/URL/hash) for a milestone.
func SubmitMilestone(cur realm, pactID int64, milestoneIdx int, proofURI string) {
	pact := mustGetPact(pactID)
	if pact.Status != StatusActive {
		panic("pact is not active")
	}
	if cur.Previous().Address() != pact.Builder {
		panic("only assigned builder can submit milestone proof")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(pact.Milestones) {
		panic("invalid milestone index")
	}
	proofURI = strings.TrimSpace(proofURI)
	if proofURI == "" || len(proofURI) > 256 {
		panic("proofURI must be 1..256 characters")
	}

	ms := pact.Milestones[milestoneIdx]
	if ms.Status != MilestonePending {
		panic("milestone already submitted or paid")
	}

	ms.Status = MilestoneSubmitted
	ms.ProofURI = proofURI
	ms.SubmittedAt = time.Now()
}

// ApproveMilestone casts a reviewer vote for a submitted milestone.
// The instant M-of-N quorum is reached, native ugnot is atomically sent to the builder
// via chain/banker and the builder's permanent Proof-of-Contribution XP is updated.
func ApproveMilestone(cur realm, pactID int64, milestoneIdx int) {
	pact := mustGetPact(pactID)
	if pact.Status != StatusActive {
		panic("pact is not active")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(pact.Milestones) {
		panic("invalid milestone index")
	}

	reviewer := cur.Previous().Address()
	if !hasAddress(pact.Reviewers, reviewer) {
		panic("caller is not a designated reviewer")
	}

	ms := pact.Milestones[milestoneIdx]
	if ms.Status != MilestoneSubmitted {
		panic("milestone is not awaiting review")
	}
	if hasAddress(ms.Approvals, reviewer) {
		panic("reviewer already approved this milestone")
	}

	ms.Approvals = append(ms.Approvals, reviewer)
	if len(ms.Approvals) < pact.Quorum {
		return
	}

	// Quorum reached -> settle milestone atomically (checks-effects-interactions)
	now := time.Now()
	ms.Status = MilestonePaid
	ms.PaidAt = now
	pact.ReleasedUgnot += ms.AmountUgnot
	activeLockedUgnot -= ms.AmountUgnot
	totalReleasedUgnot += ms.AmountUgnot

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), pact.Builder, chain.NewCoins(chain.NewCoin("ugnot", ms.AmountUgnot)))

	prof := getOrCreateBuilder(pact.Builder)
	onTime := !now.After(pact.Deadline)
	prof.MilestonesCompleted++
	prof.TotalEarnedUgnot += ms.AmountUgnot
	prof.XP += escrowmath.CalculatePoCXP(ms.AmountUgnot, onTime, !pact.HadDispute)

	allPaid := true
	for _, m := range pact.Milestones {
		if m.Status != MilestonePaid {
			allPaid = false
			break
		}
	}
	if allPaid {
		pact.Status = StatusCompleted
		completedPactsCount++
		prof.PactsCompleted++
	}
}

// RaiseDispute freezes an active pact so the reviewer quorum can arbitrate remaining escrow.
func RaiseDispute(cur realm, pactID int64, reason string) {
	pact := mustGetPact(pactID)
	if pact.Status != StatusActive {
		panic("only active pacts can be disputed")
	}
	caller := cur.Previous().Address()
	if caller != pact.Sponsor && caller != pact.Builder {
		panic("only sponsor or builder can raise a dispute")
	}
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > 300 {
		panic("dispute reason must be 1..300 characters")
	}

	pact.Status = StatusDisputed
	pact.DisputeReason = reason
	pact.HadDispute = true
	disputedPactsCount++

	prof := getOrCreateBuilder(pact.Builder)
	prof.DisputesCount++
}

// VoteDisputeResolution lets designated reviewers settle a disputed pact without any central admin.
// Once M-of-N reviewers vote for the same builderShareBps (0..10000), remaining ugnot is
// atomically distributed between builder and sponsor.
func VoteDisputeResolution(cur realm, pactID int64, builderShareBps int64) {
	pact := mustGetPact(pactID)
	if pact.Status != StatusDisputed {
		panic("pact is not in dispute")
	}
	if builderShareBps < 0 || builderShareBps > escrowmath.BpsDenominator {
		panic("builderShareBps must be 0..10000")
	}

	reviewer := cur.Previous().Address()
	if !hasAddress(pact.Reviewers, reviewer) {
		panic("caller is not a designated reviewer")
	}
	for _, v := range pact.DisputeVotes {
		if v.Reviewer == reviewer {
			panic("reviewer already voted on dispute")
		}
	}

	pact.DisputeVotes = append(pact.DisputeVotes, DisputeVote{
		Reviewer:        reviewer,
		BuilderShareBps: builderShareBps,
	})

	matches := 0
	for _, v := range pact.DisputeVotes {
		if v.BuilderShareBps == builderShareBps {
			matches++
		}
	}
	if matches < pact.Quorum {
		return
	}

	remaining := pact.TotalUgnot - pact.ReleasedUgnot
	builderAmt, sponsorAmt, err := escrowmath.ComputeDisputeSplit(remaining, builderShareBps)
	if err != nil {
		panic(err.Error())
	}

	pact.Status = StatusResolved
	pact.ReleasedUgnot += builderAmt
	activeLockedUgnot -= remaining
	totalReleasedUgnot += builderAmt

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if builderAmt > 0 {
		b.SendCoins(cur.Address(), pact.Builder, chain.NewCoins(chain.NewCoin("ugnot", builderAmt)))
		prof := getOrCreateBuilder(pact.Builder)
		prof.TotalEarnedUgnot += builderAmt
	}
	if sponsorAmt > 0 {
		b.SendCoins(cur.Address(), pact.Sponsor, chain.NewCoins(chain.NewCoin("ugnot", sponsorAmt)))
	}
}

// ReclaimExpired allows the sponsor to safely reclaim any unpaid ugnot after the deadline.
func ReclaimExpired(cur realm, pactID int64) {
	pact := mustGetPact(pactID)
	if cur.Previous().Address() != pact.Sponsor {
		panic("only sponsor can reclaim expired escrow")
	}
	if pact.Status != StatusOpen && pact.Status != StatusActive {
		panic("pact cannot be reclaimed in current state")
	}
	if !time.Now().After(pact.Deadline) {
		panic("pact deadline has not passed yet")
	}

	remaining := pact.TotalUgnot - pact.ReleasedUgnot
	pact.Status = StatusExpired
	activeLockedUgnot -= remaining

	if remaining > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), pact.Sponsor, chain.NewCoins(chain.NewCoin("ugnot", remaining)))
	}
}

// GetPactCount returns total number of created pacts.
func GetPactCount() int64 {
	return nextPactID - 1
}

// GetBuilderXP returns a builder's on-chain Proof-of-Contribution XP.
func GetBuilderXP(addr address) int64 {
	v := builders.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(*BuilderProfile).XP
}

func mustGetPact(id int64) *Pact {
	v := pacts.Get(padID(id))
	if v == nil {
		panic("pact not found")
	}
	return v.(*Pact)
}

func getOrCreateBuilder(addr address) *BuilderProfile {
	key := addr.String()
	if v := builders.Get(key); v != nil {
		return v.(*BuilderProfile)
	}
	p := &BuilderProfile{Address: addr}
	builders.Set(key, p)
	return p
}

func parseUniqueReviewers(csv string) []address {
	parts := strings.Split(strings.TrimSpace(csv), ",")
	out := make([]address, 0, len(parts))
	for _, raw := range parts {
		s := strings.TrimSpace(raw)
		if s == "" {
			continue
		}
		a := address(s)
		if !a.IsValid() {
			panic("invalid reviewer address: " + s)
		}
		if !hasAddress(out, a) {
			out = append(out, a)
		}
	}
	return out
}
