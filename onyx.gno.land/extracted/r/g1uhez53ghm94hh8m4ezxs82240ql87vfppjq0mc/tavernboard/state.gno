package tavernboard

import (
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/g1uhez53ghm94hh8m4ezxs82240ql87vfppjq0mc/tavernkit"
)

const (
	// Native coin denomination used across all escrows and reviewer stakes.
	nativeDenom = "ugnot"

	// Minimum bounty funding: 0.1 GNOT (100,000 ugnot) keeps testnet demos
	// accessible while preventing dust spam.
	MinBountyUgnot int64 = 100_000

	// Default minimum stake required per dispute reviewer: 0.05 GNOT.
	DefaultMinReviewerStakeUgnot int64 = 50_000

	// Absolute floor for per-bounty reviewer stake.
	FloorReviewerStakeUgnot int64 = 10_000

	// Default reviewer quorum size (3 independent staked reviewers).
	DefaultReviewerQuorum = 3

	// Maximum reviewer quorum size to keep dispute resolution bounded.
	MaxReviewerQuorum = 7

	// Slash share taken from dissenting reviewers' stakes (50% = 5000 bps).
	DissentSlashBps int64 = 5000

	// Maximum sponsor revision requests before builder can force quorum review.
	MaxRevisionRequests = 3

	// Review grace period: if a sponsor ignores a submitted milestone for 48h,
	// the builder may escalate directly to staked reviewer quorum.
	ReviewGracePeriod = 48 * time.Hour

	// Bounds on user strings to protect on-chain storage and gas predictability.
	MaxTitleLen     = 120
	MaxSummaryLen   = 1200
	MaxTagsLen      = 120
	MaxPitchLen     = 400
	MaxProofURLLen  = 256
	MaxNotesLen     = 800
	MaxFeedbackLen  = 500
	MaxRationaleLen = 400
	MaxDeadlineDays = 365
)

var (
	// Realm identity captured once at init(cur realm).
	realmPkgPath string
	realmAddr    address
	deployerAddr address

	// Primary persistent stores (all unexported; never returned as pointers).
	nextBountyID seqid.ID
	bounties     *avl.Tree // key: seqid.ID(id).String() -> *bounty
	profiles     *avl.Tree // key: addr.String()         -> *builderProfile

	// Aggregate counters maintained incrementally in O(1).
	statTotalBounties     int64
	statOpenBounties      int64
	statCompletedBounties int64
	statDisputesResolved  int64
	statTotalFundedUgnot  int64
	statTotalPaidUgnot    int64
	statActiveEscrowUgnot int64
	statArchivedBounties  int64
)

func init(cur realm) {
	realmPkgPath = cur.PkgPath()
	realmAddr = cur.Address()
	if cur.Previous() != nil {
		deployerAddr = cur.Previous().Address()
	}
	bounties = avl.NewTree()
	profiles = avl.NewTree()
	initRouter()
}

func bountyKey(id uint64) string {
	return seqid.ID(id).String()
}

func getBounty(id uint64) *bounty {
	if id == 0 {
		return nil
	}
	v := bounties.Get(bountyKey(id))
	if v == nil {
		return nil
	}
	return v.(*bounty)
}

func mustGetBounty(id uint64) *bounty {
	b := getBounty(id)
	if b == nil {
		panic("bounty not found: #" + strconv.FormatUint(id, 10))
	}
	return b
}

func getOrCreateProfile(addr address) *builderProfile {
	key := addr.String()
	if v := profiles.Get(key); v != nil {
		return v.(*builderProfile)
	}
	p := &builderProfile{addr: addr}
	profiles.Set(key, p)
	return p
}

func getProfileReadOnly(addr address) *builderProfile {
	if v := profiles.Get(addr.String()); v != nil {
		return v.(*builderProfile)
	}
	return nil
}

func profileToReputationInput(p *builderProfile) tavernkit.ReputationInput {
	if p == nil {
		return tavernkit.ReputationInput{}
	}
	return tavernkit.ReputationInput{
		CompletedBounties:  p.completedBounties,
		ApprovedMilestones: p.approvedMilestones,
		TotalEarnedUgnot:   p.totalEarnedUgnot,
		ReviewsAligned:     p.reviewsAligned,
		ReviewsSlashed:     p.reviewsSlashed,
		DisputesWon:        p.disputesWon,
		DisputesLost:       p.disputesLost,
	}
}

func requireLiveCaller(_ int, rlm realm) address {
	if !rlm.IsCurrent() {
		panic("spoofed realm handle")
	}
	return rlm.Previous().Address()
}

func requireDirectUserCall(_ int, rlm realm) address {
	if !rlm.IsCurrent() {
		panic("spoofed realm handle")
	}
	if !rlm.Previous().IsUserCall() {
		panic("direct user call (maketx call) required for coin transfers")
	}
	return rlm.Previous().Address()
}
