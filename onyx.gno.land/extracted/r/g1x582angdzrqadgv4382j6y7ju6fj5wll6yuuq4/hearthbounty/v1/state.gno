// Package hearthbounty implements the HearthBounty v1 micro-bounty escrow,
// per-contributor top-up custody, deterministic review/dispute timeouts,
// verifiable proof registry, reputation leaderboard, and gnoweb UI on Gno.land.
package hearthbounty

import (
	"strings"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	// EscrowTokenKey identifies the official 1:1 ugnot-backed wrapped GNOT
	// token registered in gno.land/r/nt/grc20reg/v0.
	EscrowTokenKey = "gno.land/r/gnoland/wugnot.wugnot"

	// MinTopUpUgnot matches the 0.10 GNOT floor so dust spam cannot grief donor ledgers.
	MinTopUpUgnot int64 = hearthcore.MinRewardUgnot

	// MaxEscrowUgnot caps a single bounty's escrow (1,000,000 GNOT) to prevent int64 overflow.
	MaxEscrowUgnot int64 = 1000000000000

	// MaxExternalDonors bounds deterministic donor iteration during cancel/dispute refunds.
	MaxExternalDonors = 20

	// BoardPageSize caps rendered rows per gnoweb page well below the 1 MiB ceiling.
	BoardPageSize = 20
)

type bountyRecord struct {
	ID                    uint64
	Title                 string
	Spec                  string
	Category              hearthcore.Category
	Status                hearthcore.Status
	Sponsor               address
	Claimant              address
	ClaimNote             string
	EscrowUgnot           int64
	InitialUgnot          int64
	SponsorFundedUgnot    int64
	ExternalTopUpUgnot    int64
	DonorShares           *avl.Tree // non-sponsor address string -> int64 ugnot
	PayoutUgnot           int64
	RefundUgnot           int64
	TopUpCount            uint64
	DeadlineBlocks        int64
	CreatedHeight         int64
	ClaimedHeight         int64
	DeadlineHeight        int64
	SubmittedHeight       int64
	ReviewDeadlineHeight  int64
	DisputedHeight        int64
	DisputeDeadlineHeight int64
	SettledHeight         int64
	ProofURL              string
	ProofDigest           string
	ProofSummary          string
	SubmissionCount       uint64
	RevisionFeedback      string
	Rating                uint8
	ReviewNote            string
	DisputeReason         string
	DisputeOpenedBy       address
}

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
	ID                    uint64
	Title                 string
	Spec                  string
	Category              hearthcore.Category
	Status                hearthcore.Status
	Sponsor               address
	Claimant              address
	ClaimNote             string
	EscrowUgnot           int64
	InitialUgnot          int64
	SponsorFundedUgnot    int64
	ExternalTopUpUgnot    int64
	ExternalDonorCount    int
	PayoutUgnot           int64
	RefundUgnot           int64
	TopUpCount            uint64
	DeadlineBlocks        int64
	CreatedHeight         int64
	ClaimedHeight         int64
	DeadlineHeight        int64
	SubmittedHeight       int64
	ReviewDeadlineHeight  int64
	DisputedHeight        int64
	DisputeDeadlineHeight int64
	SettledHeight         int64
	ProofURL              string
	ProofDigest           string
	ProofSummary          string
	SubmissionCount       uint64
	RevisionFeedback      string
	Rating                uint8
	ReviewNote            string
	DisputeReason         string
	DisputeOpenedBy       address
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
	realmAddress      address
	realmPkgPath      string
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
	realmAddress = cur.Address()
	realmPkgPath = cur.PkgPath()
	realmWebBase = deriveWebBase(realmPkgPath)
	if deployer := cur.Previous().Address(); deployer.IsValid() {
		arbiter = deployer
	}
	bounties = avl.NewTree()
	profiles = avl.NewTree()
	initRouter()
}

func deriveWebBase(pkgPath string) string {
	idx := strings.Index(pkgPath, "/")
	if idx == -1 {
		return "/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v1"
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
	donorCount := 0
	if b.DonorShares != nil {
		donorCount = b.DonorShares.Size()
	}
	return BountyView{
		ID:                    b.ID,
		Title:                 b.Title,
		Spec:                  b.Spec,
		Category:              b.Category,
		Status:                b.Status,
		Sponsor:               b.Sponsor,
		Claimant:              b.Claimant,
		ClaimNote:             b.ClaimNote,
		EscrowUgnot:           b.EscrowUgnot,
		InitialUgnot:          b.InitialUgnot,
		SponsorFundedUgnot:    b.SponsorFundedUgnot,
		ExternalTopUpUgnot:    b.ExternalTopUpUgnot,
		ExternalDonorCount:    donorCount,
		PayoutUgnot:           b.PayoutUgnot,
		RefundUgnot:           b.RefundUgnot,
		TopUpCount:            b.TopUpCount,
		DeadlineBlocks:        b.DeadlineBlocks,
		CreatedHeight:         b.CreatedHeight,
		ClaimedHeight:         b.ClaimedHeight,
		DeadlineHeight:        b.DeadlineHeight,
		SubmittedHeight:       b.SubmittedHeight,
		ReviewDeadlineHeight:  b.ReviewDeadlineHeight,
		DisputedHeight:        b.DisputedHeight,
		DisputeDeadlineHeight: b.DisputeDeadlineHeight,
		SettledHeight:         b.SettledHeight,
		ProofURL:              b.ProofURL,
		ProofDigest:           b.ProofDigest,
		ProofSummary:          b.ProofSummary,
		SubmissionCount:       b.SubmissionCount,
		RevisionFeedback:      b.RevisionFeedback,
		Rating:                b.Rating,
		ReviewNote:            b.ReviewNote,
		DisputeReason:         b.DisputeReason,
		DisputeOpenedBy:       b.DisputeOpenedBy,
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

func decrementSponsoredCredit(addr address, amount int64) {
	if amount <= 0 {
		return
	}
	if raw := profiles.Get(string(addr)); raw != nil {
		p := raw.(*profileRecord)
		if p.SponsoredUgnot >= amount {
			p.SponsoredUgnot -= amount
		} else {
			p.SponsoredUgnot = 0
		}
	}
}
