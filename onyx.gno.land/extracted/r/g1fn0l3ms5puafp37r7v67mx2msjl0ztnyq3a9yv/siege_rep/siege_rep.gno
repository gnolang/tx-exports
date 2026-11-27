package siege_rep

import (
	"chain/runtime/unsafe"
	"strings"
	"time"

	"gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"
)

var (
	deployer              address
	realmAddr             address
	authorizedCorePkgPath string

	guildsByOwner    = map[address]*Guild{}
	guildNameTaken   = map[string]bool{}
	guildOwnerList   []address

	buildersByAddr   = map[address]*BuilderProfile{}
	builderAddrList  []address

	sponsorsByAddr   = map[address]*SponsorStats{}
	sponsorAddrList  []address

	// Anti-wash-trading & uniqueness ledgers (append-only, never deleted).
	pairXP           = map[string]*pairXPRecord{}
	uniquePairSeen   = map[string]bool{}
)

func init(cur realm) {
	deployer = cur.Previous().Address()
	if deployer == "" {
		// Fallback only hit when imported lazily by gno filetest (Context == nil);
		// on-chain AddPackage always sets OriginCaller = creator.Bech32().
		deployer = address("g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv")
	}
	realmAddr = cur.Address()
}

// InitAuthorizedCore locks the single whitelisted bountysiege realm package path.
// Callable ONCE by deployer, non-payable, direct EOA only.
func InitAuthorizedCore(cur realm, corePkgPath string) {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by EOA")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("non-payable function: do not send coins")
	}
	if cur.Previous().Address() != deployer {
		panic("unauthorized: only deployer can initialize authorized core")
	}
	if authorizedCorePkgPath != "" {
		panic("authorized core already initialized")
	}
	trimmed := strings.TrimSpace(corePkgPath)
	if !strings.HasPrefix(trimmed, "gno.land/r/") || len(trimmed) > 200 {
		panic("invalid core realm package path")
	}
	authorizedCorePkgPath = trimmed
}

// RegisterGuild creates a Guild / Sponsor Space profile owned by cur.Previous().Address().
func RegisterGuild(cur realm, name, bio, website string) {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by EOA")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("non-payable function: do not send coins")
	}
	owner := cur.Previous().Address()
	if _, exists := guildsByOwner[owner]; exists {
		panic("guild already registered for this address")
	}
	if err := bs_core.ValidateText(name, bs_core.MaxGuildNameBytes, true, false); err != nil {
		panic("invalid guild name: " + err.Error())
	}
	if err := bs_core.ValidateText(bio, bs_core.MaxGuildBioBytes, false, true); err != nil {
		panic("invalid guild bio: " + err.Error())
	}
	if website != "" {
		if err := bs_core.ValidateHTTPSURL(website); err != nil {
			panic("invalid guild website: " + err.Error())
		}
	}

	cleanName := strings.TrimSpace(name)
	lowerKey := strings.ToLower(cleanName)
	if guildNameTaken[lowerKey] {
		panic("guild name already taken")
	}

	now := time.Now().Unix()
	g := &Guild{
		Owner:     owner,
		Name:      cleanName,
		CreatedAt: now,
		History: []GuildSnapshot{
			{
				Bio:       strings.TrimSpace(bio),
				Website:   website,
				UpdatedAt: now,
			},
		},
	}
	guildsByOwner[owner] = g
	guildNameTaken[lowerKey] = true
	guildOwnerList = append(guildOwnerList, owner)
}

// UpdateGuild appends a new snapshot to the caller's Guild history.
// Append-only guarantees bytes_delta >= 0 (no storage shrink).
func UpdateGuild(cur realm, bio, website string) {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by EOA")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("non-payable function: do not send coins")
	}
	owner := cur.Previous().Address()
	g, exists := guildsByOwner[owner]
	if !exists {
		panic("guild not found for caller")
	}
	if err := bs_core.ValidateText(bio, bs_core.MaxGuildBioBytes, false, true); err != nil {
		panic("invalid guild bio: " + err.Error())
	}
	if website != "" {
		if err := bs_core.ValidateHTTPSURL(website); err != nil {
			panic("invalid guild website: " + err.Error())
		}
	}
	g.History = append(g.History, GuildSnapshot{
		Bio:       strings.TrimSpace(bio),
		Website:   website,
		UpdatedAt: time.Now().Unix(),
	})
}

//----------------------------------------
// Authorized Core Recorder Functions (Opsi A: Total / Non-Panicking beyond auth)
//----------------------------------------

func assertAuthorizedCore(_ int, rlm realm) {
	if authorizedCorePkgPath == "" || rlm.Previous().PkgPath() != authorizedCorePkgPath {
		panic("unauthorized caller realm")
	}
}

// RecordQuestCompleted records a completed Single-Claim Quest or Co-op Raid slot.
// Total function after auth check: never panics on any input.
func RecordQuestCompleted(
	cur realm,
	sponsor address,
	builder address,
	cat uint8,
	reward int64,
	reviewSecs int64,
	isRaid bool,
	isTimeout bool,
) {
	assertAuthorizedCore(0, cur)
	if sponsor == "" || builder == "" || sponsor == builder {
		return
	}
	if reward < 0 {
		reward = 0
	}
	if reviewSecs < 0 {
		reviewSecs = 0
	}
	c := bs_core.Category(cat)
	if !c.IsValid() {
		c = bs_core.CatContract
	}

	now := time.Now().Unix()
	bp := getOrCreateBuilder(builder)
	sp := getOrCreateSponsor(sponsor)

	bp.CompletedCount = bs_core.SafeAdd64(bp.CompletedCount, 1)
	bp.TotalEarnedUgnot = bs_core.SafeAdd64(bp.TotalEarnedUgnot, reward)

	sp.CompletedCount = bs_core.SafeAdd64(sp.CompletedCount, 1)
	sp.TotalPaidUgnot = bs_core.SafeAdd64(sp.TotalPaidUgnot, reward)
	if isTimeout {
		sp.TimeoutCount = bs_core.SafeAdd64(sp.TimeoutCount, 1)
	} else {
		sp.ReviewedCount = bs_core.SafeAdd64(sp.ReviewedCount, 1)
		sp.TotalReviewSeconds = bs_core.SafeAdd64(sp.TotalReviewSeconds, reviewSecs)
	}

	awardUniqueAndXP(bp, sp, sponsor, builder, c, reward, now, isRaid, false)
}

// RecordContestWinners records payouts & reputation for Open Contest winners.
// Total function after auth check: never panics on any input.
func RecordContestWinners(
	cur realm,
	sponsor address,
	winners []address,
	cat uint8,
	payouts []int64,
) {
	assertAuthorizedCore(0, cur)
	if sponsor == "" || len(winners) == 0 {
		return
	}
	c := bs_core.Category(cat)
	if !c.IsValid() {
		c = bs_core.CatContract
	}
	now := time.Now().Unix()
	sp := getOrCreateSponsor(sponsor)
	sp.CompletedCount = bs_core.SafeAdd64(sp.CompletedCount, 1)

	limit := len(winners)
	if len(payouts) < limit {
		limit = len(payouts)
	}
	for i := 0; i < limit; i++ {
		w := winners[i]
		p := payouts[i]
		if w == "" || w == sponsor {
			continue
		}
		if p < 0 {
			p = 0
		}
		bp := getOrCreateBuilder(w)
		bp.CompletedCount = bs_core.SafeAdd64(bp.CompletedCount, 1)
		bp.TotalEarnedUgnot = bs_core.SafeAdd64(bp.TotalEarnedUgnot, p)
		sp.TotalPaidUgnot = bs_core.SafeAdd64(sp.TotalPaidUgnot, p)

		awardUniqueAndXP(bp, sp, sponsor, w, c, p, now, false, true)
	}
}

// RecordNoShow records a builder no-show when ExpireClaim triggers.
func RecordNoShow(cur realm, builder address) {
	assertAuthorizedCore(0, cur)
	if builder == "" {
		return
	}
	bp := getOrCreateBuilder(builder)
	bp.NoShowCount = bs_core.SafeAdd64(bp.NoShowCount, 1)
}

// RecordRejected records FinalizeRejection (builder did not dispute within 48h).
func RecordRejected(cur realm, sponsor, builder address) {
	assertAuthorizedCore(0, cur)
	if builder != "" {
		bp := getOrCreateBuilder(builder)
		bp.RejectedCount = bs_core.SafeAdd64(bp.RejectedCount, 1)
	}
	if sponsor != "" {
		sp := getOrCreateSponsor(sponsor)
		sp.CancelledAfterSubmitCount = bs_core.SafeAdd64(sp.CancelledAfterSubmitCount, 1)
	}
}

// RecordDisputeOutcome records which side lost an arbiter-resolved dispute.
func RecordDisputeOutcome(cur realm, sponsor, builder address, builderWon bool) {
	assertAuthorizedCore(0, cur)
	if builderWon {
		if sponsor != "" {
			sp := getOrCreateSponsor(sponsor)
			sp.LostDisputeCount = bs_core.SafeAdd64(sp.LostDisputeCount, 1)
		}
	} else {
		if builder != "" {
			bp := getOrCreateBuilder(builder)
			bp.LostDisputeCount = bs_core.SafeAdd64(bp.LostDisputeCount, 1)
		}
		if sponsor != "" {
			sp := getOrCreateSponsor(sponsor)
			sp.CancelledAfterSubmitCount = bs_core.SafeAdd64(sp.CancelledAfterSubmitCount, 1)
		}
	}
}

// RecordLateJudging records a sponsor missing a Contest judgingDeadline.
func RecordLateJudging(cur realm, sponsor address) {
	assertAuthorizedCore(0, cur)
	if sponsor == "" {
		return
	}
	sp := getOrCreateSponsor(sponsor)
	sp.LateJudgingCount = bs_core.SafeAdd64(sp.LateJudgingCount, 1)
}

// RecordRevisionExpired records an expired revision window as a neutral statistic
// (does NOT penalize builder XP or increment RejectedCount/NoShowCount).
func RecordRevisionExpired(cur realm, builder address) {
	assertAuthorizedCore(0, cur)
	if builder == "" {
		return
	}
	bp := getOrCreateBuilder(builder)
	bp.RevisionExpiredCount = bs_core.SafeAdd64(bp.RevisionExpiredCount, 1)
}

//----------------------------------------
// Internal XP, Cooldown, Diminishing Returns & Badges (Non-Panicking)
//----------------------------------------

func awardUniqueAndXP(
	bp *BuilderProfile,
	sp *SponsorStats,
	sponsor, builder address,
	cat bs_core.Category,
	reward int64,
	now int64,
	isRaid bool,
	isContest bool,
) {
	key := sponsor.String() + "|" + builder.String()
	if !uniquePairSeen[key] {
		uniquePairSeen[key] = true
		bp.UniqueSponsorsCount = bs_core.SafeAdd64(bp.UniqueSponsorsCount, 1)
		sp.UniqueBuildersCount = bs_core.SafeAdd64(sp.UniqueBuildersCount, 1)
	}

	// Minimum reward threshold for XP & Badges (5 GNOT) mitigates micro-quest farming.
	if reward < bs_core.MinRewardForXP {
		return
	}

	bp.QualifiedCompletedCount = bs_core.SafeAdd64(bp.QualifiedCompletedCount, 1)
	bp.QualifiedByCategory[cat] = bs_core.SafeAdd64(bp.QualifiedByCategory[cat], 1)
	if isRaid {
		bp.QualifiedRaidCount = bs_core.SafeAdd64(bp.QualifiedRaidCount, 1)
	}
	if isContest {
		bp.QualifiedContestCount = bs_core.SafeAdd64(bp.QualifiedContestCount, 1)
	}

	// Pair cooldown (7d) + diminishing returns (100% -> 50% -> 25%).
	pr, exists := pairXP[key]
	if !exists {
		pr = &pairXPRecord{}
		pairXP[key] = pr
	}

	var xpAward int64
	cooldownPassed := pr.XPAwardCount == 0 || (now-pr.LastRewardUnix) >= bs_core.PairXPCooldownSec
	if cooldownPassed {
		gnotBonus := reward / bs_core.UgnotPerGnot
		if gnotBonus > 100 {
			gnotBonus = 100
		}
		baseXP := int64(100) + gnotBonus*10
		switch pr.XPAwardCount {
		case 0:
			xpAward = baseXP
		case 1:
			xpAward = baseXP / 2
		default:
			xpAward = baseXP / 4
		}
		pr.LastRewardUnix = now
		pr.XPAwardCount = bs_core.SafeAdd64(pr.XPAwardCount, 1)
	}

	if xpAward > 0 {
		bp.XPByCategory[cat] = bs_core.SafeAdd64(bp.XPByCategory[cat], xpAward)
		bp.TotalXP = bs_core.SafeAdd64(bp.TotalXP, xpAward)
	}

	// Soulbound Badge checks (append-only, never revoked/transferred).
	if bp.QualifiedCompletedCount >= 1 {
		grantBadge(bp, BadgeFirstBlood)
	}
	if bp.QualifiedByCategory[cat] >= 3 {
		grantBadge(bp, BadgeSkilledSpecialist)
	}
	if bp.UniqueSponsorsCount >= 3 {
		grantBadge(bp, BadgeMultiSponsorTrusted)
	}
	if bp.QualifiedRaidCount >= 1 {
		grantBadge(bp, BadgeRaidFinisher)
	}
	if bp.QualifiedContestCount >= 1 {
		grantBadge(bp, BadgeContestWinner)
	}
}

func grantBadge(bp *BuilderProfile, badge string) {
	if bp.badgeSet == nil {
		bp.badgeSet = map[string]bool{}
	}
	if bp.badgeSet[badge] {
		return
	}
	bp.badgeSet[badge] = true
	bp.Badges = append(bp.Badges, badge)
}

func getOrCreateBuilder(addr address) *BuilderProfile {
	if bp, ok := buildersByAddr[addr]; ok {
		return bp
	}
	bp := &BuilderProfile{
		Addr:     addr,
		badgeSet: map[string]bool{},
	}
	buildersByAddr[addr] = bp
	builderAddrList = append(builderAddrList, addr)
	return bp
}

func getOrCreateSponsor(addr address) *SponsorStats {
	if sp, ok := sponsorsByAddr[addr]; ok {
		return sp
	}
	sp := &SponsorStats{Addr: addr}
	sponsorsByAddr[addr] = sp
	sponsorAddrList = append(sponsorAddrList, addr)
	return sp
}

//----------------------------------------
// Public Read-Only Composable Getters
//----------------------------------------

func GetAuthorizedCore() string {
	return authorizedCorePkgPath
}

func HasBadge(addr address, badge string) bool {
	bp, ok := buildersByAddr[addr]
	if !ok || bp.badgeSet == nil {
		return false
	}
	return bp.badgeSet[badge]
}

func GetBuilderXP(addr address) int64 {
	bp, ok := buildersByAddr[addr]
	if !ok {
		return 0
	}
	return bp.TotalXP
}

func GetBuilderCompletedCount(addr address) int64 {
	bp, ok := buildersByAddr[addr]
	if !ok {
		return 0
	}
	return bp.CompletedCount
}

func GetGuildName(owner address) string {
	g, ok := guildsByOwner[owner]
	if !ok {
		return ""
	}
	return g.Name
}

func GetSponsorTotalPaid(sponsor address) int64 {
	sp, ok := sponsorsByAddr[sponsor]
	if !ok {
		return 0
	}
	return sp.TotalPaidUgnot
}

func BuilderCount() int {
	return len(builderAddrList)
}

func GuildCount() int {
	return len(guildOwnerList)
}
