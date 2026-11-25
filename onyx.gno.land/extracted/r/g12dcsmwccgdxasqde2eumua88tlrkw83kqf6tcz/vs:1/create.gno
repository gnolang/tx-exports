package vs

import (
	"strings"

	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
)

type createArgs struct {
	question, creatorPosition, counterPosition, resolutionURL string
	deadline, stakeAmount                                     int64
	category                                                  string
	parentID                                                  int64
	marketType, oddsMode                                      string
	challengerPayoutBps                                       int64
	handicapLine, settlementRule                              string
	maxChallengers                                            int
	isPrivate                                                 bool
	referrer                                                  address
}

// CreateClaim opens a claim with `stakeAmount` mUSD (less the entry fee) on
// the creator's position. oddsMode is "pool" or "fixed"; challengerPayoutBps
// applies to fixed odds (below 10000 means the 2x default). maxChallengers 0
// means the maximum. referrer is the copied basket's creator, or "".
func CreateClaim(cur realm,
	question, creatorPosition, counterPosition, resolutionURL string,
	deadline, stakeAmount int64,
	category string, parentID int64,
	marketType, oddsMode string, challengerPayoutBps int64,
	handicapLine, settlementRule string, maxChallengers int,
	isPrivate bool, referrer string) int64 {
	roles.AssertNotPaused()
	return createClaim(cur, createArgs{
		question, creatorPosition, counterPosition, resolutionURL,
		deadline, stakeAmount, category, parentID, marketType, oddsMode,
		challengerPayoutBps, handicapLine, settlementRule, maxChallengers,
		isPrivate, mimir.ParseOptional(referrer),
	})
}

// CreateRematch opens a new claim inheriting its terms from a parent. The
// caller is the creator and pays the stake. The parent's referrer carries over
// only to the parent's own creator.
func CreateRematch(cur realm, parentID, deadline, stakeAmount int64) int64 {
	roles.AssertNotPaused()
	p := getClaim(parentID)
	ref := address("")
	if caller(cur) == p.Creator {
		ref = p.Referrer
	}
	return createClaim(cur, createArgs{
		p.Question, p.CreatorPosition, p.CounterPosition, p.ResolutionURL,
		deadline, stakeAmount, p.Category, parentID, p.MarketType, p.OddsMode,
		p.ChallengerPayoutBps, p.HandicapLine, p.SettlementRule, p.MaxChallengers,
		p.IsPrivate, ref,
	})
}

func createClaim(cur realm, a createArgs) int64 {
	if a.stakeAmount < MinStake {
		panic("StakeTooSmall")
	}
	if a.deadline <= now() {
		panic("DeadlineInPast")
	}
	if a.deadline > now()+MaxDeadlineAhead {
		panic("DeadlineTooFar")
	}
	if a.question == "" {
		panic("EmptyQuestion")
	}
	isFixed := a.oddsMode == "fixed"
	payoutBps := int64(0)
	if isFixed {
		payoutBps = DefaultPayoutBps
		if a.challengerPayoutBps >= 10_000 {
			payoutBps = a.challengerPayoutBps
		}
	}
	if payoutBps > MaxPayoutBps {
		panic("PayoutTooHigh")
	}
	maxCh := a.maxChallengers
	if maxCh <= 0 || maxCh > MaxChallengers {
		maxCh = MaxChallengers
	}
	claimCount++
	c := &Claim{
		ID: claimCount, Creator: caller(cur), Question: a.question,
		CreatorPosition: a.creatorPosition, CounterPosition: a.counterPosition,
		ResolutionURL: a.resolutionURL, Deadline: a.deadline, Category: orDefault(a.category, "custom"),
		ParentID: a.parentID, CreatedAt: now(), MarketType: orDefault(a.marketType, "binary"),
		OddsMode: "pool", ChallengerPayoutBps: payoutBps, HandicapLine: a.handicapLine,
		SettlementRule: a.settlementRule, MaxChallengers: maxCh, IsPrivate: a.isPrivate,
		Referrer: a.referrer,
	}
	if isFixed {
		c.OddsMode = "fixed"
	}
	net := takeEntry(cur, c, c.Creator, a.stakeAmount)
	roles.CheckCaps(net, net)
	c.CreatorStake = net
	claims.Set(key(c.ID), c)
	if a.referrer != "" {
		emit("ReferrerSet", "id", itoa(c.ID), "user", c.Creator.String(), "referrer", a.referrer.String())
	}
	emit("ClaimCreated", "id", itoa(c.ID), "creator", c.Creator.String(), "category", c.Category)
	return c.ID
}

func orDefault(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

// SetInvited grants or revokes wallets on a private claim, up to
// MaxChallengers per call, as a comma-separated list. Revocation only blocks
// future entry. Rematches have their own empty list.
func SetInvited(cur realm, claimID int64, accounts string, allowed bool) {
	c := getClaim(claimID)
	list := strings.Split(accounts, ",")
	if caller(cur) != c.Creator || !c.IsPrivate || c.State > StActive || len(list) > MaxChallengers {
		panic("BadInvite")
	}
	for _, s := range list {
		a := address(strings.TrimSpace(s))
		if !a.IsValid() || a == c.Creator {
			panic("BadInvite")
		}
		c.invited.Set(a.String(), allowed)
		emit("InviteUpdated", "id", itoa(claimID), "account", a.String(), "allowed", boolStr(allowed))
	}
}

// ChallengeClaim takes the counter position with `stakeAmount` mUSD (less the entry fee).
func ChallengeClaim(cur realm, claimID, stakeAmount int64, referrer string) {
	roles.AssertNotPaused()
	c := getClaim(claimID)
	user := caller(cur)
	ref := mimir.ParseOptional(referrer)
	checkChallenge(c, user, stakeAmount)
	net := takeEntry(cur, c, user, stakeAmount)
	roles.CheckCaps(net, c.CreatorStake+c.TotalChallengerStake+net)
	if c.OddsMode == "fixed" {
		// The creator's unreserved stake must cover this challenger's profit.
		gross := grossPayout(net, c.ChallengerPayoutBps)
		profit := int64(0)
		if gross > net {
			profit = gross - net
		}
		if c.CreatorStake-c.ReservedCreatorLiability < profit {
			panic("CreatorHasInsufficientLiquidity")
		}
		c.ReservedCreatorLiability += profit
	} else if c.TotalChallengerStake+net > c.CreatorStake*MaxPoolMultiple {
		panic("PoolFull")
	}
	c.challengers = append(c.challengers, &Challenger{Addr: user, Stake: net, At: now(), Referrer: ref})
	c.joined.Set(user.String(), true)
	if ref != "" {
		emit("ReferrerSet", "id", itoa(claimID), "user", user.String(), "referrer", ref.String())
	}
	c.TotalChallengerStake += net
	c.State = StActive
	emit("ClaimChallenged", "id", itoa(claimID), "challenger", user.String(), "stake", itoa(net))
}

func checkChallenge(c *Claim, user address, stakeAmount int64) {
	if c.State != StOpen && c.State != StActive {
		panic("NotOpen")
	}
	if user == c.Creator {
		panic("SelfChallenge")
	}
	if c.hasJoined(user) {
		panic("AlreadyChallenged")
	}
	if len(c.challengers) >= c.MaxChallengers {
		panic("Full")
	}
	if stakeAmount < MinStake {
		panic("StakeTooSmall")
	}
	if now()+ChallengeLockSeconds > c.Deadline {
		panic("ChallengeWindowClosed")
	}
	if c.LockAt != 0 && now() >= c.LockAt {
		panic("Locked")
	}
	// Authorize the caller's wallet before calling the fee realm or pulling mUSD.
	if c.IsPrivate && !c.isInvited(user) {
		panic("NotInvited")
	}
}

// SetLockAt closes a claim to new challengers early, by its creator or the
// owner. Only ever earlier.
func SetLockAt(cur realm, claimID, at int64) {
	c := getClaim(claimID)
	u := caller(cur)
	if u != c.Creator && u != roles.Owner {
		panic("BadLock")
	}
	if c.State > StActive || at < now() || at+ChallengeLockSeconds > c.Deadline {
		panic("BadLock")
	}
	if c.LockAt != 0 && at > c.LockAt {
		panic("BadLock")
	}
	c.LockAt = at
	emit("LockSet", "id", itoa(claimID), "lockAt", itoa(at))
}

// CancelClaim refunds the creator of a claim nobody has challenged yet.
func CancelClaim(cur realm, claimID int64) {
	c := getClaim(claimID)
	if caller(cur) != c.Creator {
		panic("NotCreator")
	}
	if c.State != StOpen {
		panic("NotOpen")
	}
	c.State = StCancelled
	push(cur, c.Creator, c.CreatorStake)
	emit("ClaimCancelled", "id", itoa(claimID), "refunded", itoa(c.CreatorStake))
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
