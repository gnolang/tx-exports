// Package siege_rep is BountySiege's composable, soulbound reputation and Guild
// registry realm. Other Gno.land realms and dApps can import its read-only
// getters to verify builder XP, badges, and sponsor credibility on-chain.
package siege_rep

import "gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"

// Soulbound badge identifiers (non-transferable, recorded permanently in state).
const (
	BadgeFirstBlood          = "FirstBlood"
	BadgeSkilledSpecialist   = "SkilledSpecialist"
	BadgeMultiSponsorTrusted = "MultiSponsorTrusted"
	BadgeRaidFinisher        = "RaidFinisher"
	BadgeContestWinner       = "ContestWinner"
)

type GuildSnapshot struct {
	Bio       string
	Website   string
	UpdatedAt int64
}

type Guild struct {
	Owner     address
	Name      string
	CreatedAt int64
	// Append-only history ensures UpdateGuild never shrinks stored bytes (bytes_delta >= 0).
	History []GuildSnapshot
}

func (g *Guild) CurrentBio() string {
	if len(g.History) == 0 {
		return ""
	}
	return g.History[len(g.History)-1].Bio
}

func (g *Guild) CurrentWebsite() string {
	if len(g.History) == 0 {
		return ""
	}
	return g.History[len(g.History)-1].Website
}

type BuilderProfile struct {
	Addr                    address
	TotalXP                 int64
	XPByCategory            [bs_core.CatCount]int64
	CompletedCount          int64
	QualifiedCompletedCount int64 // missions with reward >= MinRewardForXP
	QualifiedByCategory     [bs_core.CatCount]int64
	QualifiedRaidCount      int64
	QualifiedContestCount   int64
	TotalEarnedUgnot        int64
	UniqueSponsorsCount     int64
	NoShowCount             int64
	RejectedCount           int64
	LostDisputeCount        int64
	RevisionExpiredCount    int64 // neutral for XP; tracked as separate stat
	Badges                  []string
	badgeSet                map[string]bool
}

type SponsorStats struct {
	Addr                      address
	TotalPaidUgnot            int64
	CompletedCount            int64
	ReviewedCount             int64 // non-timeout completions for honest avg review time
	TotalReviewSeconds        int64
	CancelledAfterSubmitCount int64
	TimeoutCount              int64
	LateJudgingCount          int64
	LostDisputeCount          int64
	UniqueBuildersCount       int64
}

type pairXPRecord struct {
	LastRewardUnix int64
	XPAwardCount   int64
}
