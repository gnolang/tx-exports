// Package hearthbounty implements the HearthBounty on-chain micro-bounty
// escrow, verifiable proof registry, reputation leaderboard, and native
// gnoweb interactive interface on Gno.land.
package hearthbounty

import (
	"strings"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
)

// Bounty holds the canonical on-chain state of a micro-bounty.
type bountyRecord struct {
	ID               uint64
	Title            string
	Spec             string
	Category         hearthcore.Category
	Status           hearthcore.Status
	Sponsor          address
	Claimant         address
	ClaimNote        string
	EscrowUgnot      int64
	InitialUgnot     int64
	PayoutUgnot      int64
	RefundUgnot      int64
	TopUpCount       uint64
	DeadlineBlocks   int64
	CreatedHeight    int64
	ClaimedHeight    int64
	DeadlineHeight   int64
	SubmittedHeight  int64
	SettledHeight    int64
	ProofURL         string
	ProofDigest      string
	ProofSummary     string
	SubmissionCount  uint64
	RevisionFeedback string
	Rating           uint8
	ReviewNote       string
	DisputeReason    string
	DisputeOpenedBy  address
}

// profileRecord stores a builder or autonomous AI agent profile and on-chain stats.
type profileRecord struct {
	Address          address
	Handle           string
	Bio              string
	Skills           string
	AgentEndpoint    string
	IsAgent          bool
	PostedCount      uint64
	ClaimedCount     uint64
	SettledCount     uint64
	SponsoredSettled uint64
	EarnedUgnot      int64
	SponsoredUgnot   int64
	RatingSum        uint64
	RatingCount      uint64
	RegisteredHeight int64
}

// BountyView is an immutable value-copy projection of a bounty safe for external callers.
type BountyView struct {
	ID               uint64
	Title            string
	Spec             string
	Category         hearthcore.Category
	Status           hearthcore.Status
	Sponsor          address
	Claimant         address
	ClaimNote        string
	EscrowUgnot      int64
	InitialUgnot     int64
	PayoutUgnot      int64
	RefundUgnot      int64
	TopUpCount       uint64
	DeadlineBlocks   int64
	CreatedHeight    int64
	ClaimedHeight    int64
	DeadlineHeight   int64
	SubmittedHeight  int64
	SettledHeight    int64
	ProofURL         string
	ProofDigest      string
	ProofSummary     string
	SubmissionCount  uint64
	RevisionFeedback string
	Rating           uint8
	ReviewNote       string
	DisputeReason    string
	DisputeOpenedBy  address
}

// ProfileView is an immutable value-copy projection of a builder or AI agent profile.
type ProfileView struct {
	Address          address
	Handle           string
	Bio              string
	Skills           string
	AgentEndpoint    string
	IsAgent          bool
	Tier             hearthcore.Tier
	PostedCount      uint64
	ClaimedCount     uint64
	SettledCount     uint64
	SponsoredSettled uint64
	EarnedUgnot      int64
	SponsoredUgnot   int64
	RatingSum        uint64
	RatingCount      uint64
	RegisteredHeight int64
}

// BoardStats summarizes global protocol activity and escrow invariants.
type BoardStats struct {
	TotalBounties     int
	OpenCount         int
	ClaimedCount      int
	SubmittedCount    int
	DisputedCount     int
	SettledCount      int
	CancelledCount    int
	ProfileCount      int
	AgentCount        int
	TotalEscrowUgnot  int64
	TotalSettledUgnot int64
	TotalRefundUgnot  int64
}

// All state variables are unexported so no external package can mutate realm state directly.
var (
	arbiter           address
	realmWebBase      string
	bountySeq         seqid.ID
	bounties          *avl.Tree // seqid string -> *bountyRecord
	profiles          *avl.Tree // address string -> *profileRecord
	openCount         int
	claimedCount      int
	submittedCount    int
	disputedCount     int
	settledCount      int
	cancelledCount    int
	agentCount        int
	totalEscrowUgnot  int64
	totalSettledUgnot int64
	totalRefundUgnot  int64
	router            *mux.Router
)

func init(cur realm) {
	arbiter = cur.Previous().Address()
	realmWebBase = deriveWebBase(cur.PkgPath())
	bounties = avl.NewTree()
	profiles = avl.NewTree()
	initRouter()
}

func deriveWebBase(pkgPath string) string {
	idx := strings.Index(pkgPath, "/")
	if idx == -1 {
		return "/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v0"
	}
	return pkgPath[idx:]
}

func bountyKey(id uint64) string {
	return seqid.ID(id).String()
}

func getBountyRecord(id uint64) (*bountyRecord, bool) {
	if id == 0 {
		return nil, false
	}
	raw := bounties.Get(bountyKey(id))
	if raw == nil {
		return nil, false
	}
	return raw.(*bountyRecord), true
}

func getOrCreateProfile(addr address, height int64) *profileRecord {
	key := string(addr)
	if raw := profiles.Get(key); raw != nil {
		return raw.(*profileRecord)
	}
	p := &profileRecord{
		Address:          addr,
		Handle:           hearthcore.ShortAddr(addr),
		RegisteredHeight: height,
	}
	profiles.Set(key, p)
	return p
}

func toBountyView(b *bountyRecord) BountyView {
	return BountyView{
		ID:               b.ID,
		Title:            b.Title,
		Spec:             b.Spec,
		Category:         b.Category,
		Status:           b.Status,
		Sponsor:          b.Sponsor,
		Claimant:         b.Claimant,
		ClaimNote:        b.ClaimNote,
		EscrowUgnot:      b.EscrowUgnot,
		InitialUgnot:     b.InitialUgnot,
		PayoutUgnot:      b.PayoutUgnot,
		RefundUgnot:      b.RefundUgnot,
		TopUpCount:       b.TopUpCount,
		DeadlineBlocks:   b.DeadlineBlocks,
		CreatedHeight:    b.CreatedHeight,
		ClaimedHeight:    b.ClaimedHeight,
		DeadlineHeight:   b.DeadlineHeight,
		SubmittedHeight:  b.SubmittedHeight,
		SettledHeight:    b.SettledHeight,
		ProofURL:         b.ProofURL,
		ProofDigest:      b.ProofDigest,
		ProofSummary:     b.ProofSummary,
		SubmissionCount:  b.SubmissionCount,
		RevisionFeedback: b.RevisionFeedback,
		Rating:           b.Rating,
		ReviewNote:       b.ReviewNote,
		DisputeReason:    b.DisputeReason,
		DisputeOpenedBy:  b.DisputeOpenedBy,
	}
}

func toProfileView(p *profileRecord) ProfileView {
	return ProfileView{
		Address:          p.Address,
		Handle:           p.Handle,
		Bio:              p.Bio,
		Skills:           p.Skills,
		AgentEndpoint:    p.AgentEndpoint,
		IsAgent:          p.IsAgent,
		Tier:             hearthcore.ComputeTier(p.SettledCount, p.EarnedUgnot, p.RatingSum, p.RatingCount),
		PostedCount:      p.PostedCount,
		ClaimedCount:     p.ClaimedCount,
		SettledCount:     p.SettledCount,
		SponsoredSettled: p.SponsoredSettled,
		EarnedUgnot:      p.EarnedUgnot,
		SponsoredUgnot:   p.SponsoredUgnot,
		RatingSum:        p.RatingSum,
		RatingCount:      p.RatingCount,
		RegisteredHeight: p.RegisteredHeight,
	}
}

func decrementStatusCount(st hearthcore.Status) {
	switch st {
	case hearthcore.StatusOpen:
		openCount--
	case hearthcore.StatusClaimed:
		claimedCount--
	case hearthcore.StatusSubmitted:
		submittedCount--
	case hearthcore.StatusDisputed:
		disputedCount--
	case hearthcore.StatusSettled:
		settledCount--
	case hearthcore.StatusCancelled:
		cancelledCount--
	}
}

func incrementStatusCount(st hearthcore.Status) {
	switch st {
	case hearthcore.StatusOpen:
		openCount++
	case hearthcore.StatusClaimed:
		claimedCount++
	case hearthcore.StatusSubmitted:
		submittedCount++
	case hearthcore.StatusDisputed:
		disputedCount++
	case hearthcore.StatusSettled:
		settledCount++
	case hearthcore.StatusCancelled:
		cancelledCount++
	}
}

func transitionStatus(b *bountyRecord, next hearthcore.Status) {
	if b.Status == next {
		return
	}
	decrementStatusCount(b.Status)
	b.Status = next
	incrementStatusCount(next)
}
