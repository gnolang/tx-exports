// Package komit implements Komit: stake-backed habit streaks on Gno.land.
//
// A user locks testnet GNOT (ugnot) as a stake, picks a habit and a target
// number of consecutive daily check-ins, and must call CheckIn once per UTC
// day. Miss a day and the streak breaks: the stake is forfeited into a shared
// reward pool. Reach the target and Claim returns the stake plus a bonus of
// min(reward pool balance, stake) -- up to 2x back.
//
// There is deliberately no owner/admin functionality: nobody can withdraw
// user stakes or the pool. Coins leave the realm only through Claim (to the
// challenge owner) -- forfeited stakes stay in the realm as the pool.
package komit

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

const (
	DenomUgnot = "ugnot"

	MinStakeUgnot = int64(1_000_000)   // 1 GNOT
	MaxStakeUgnot = int64(100_000_000) // 100 GNOT

	MinTargetDays = 3
	MaxTargetDays = 90

	MaxHabitLen = 64

	StatusActive    = "ACTIVE"
	StatusCompleted = "COMPLETED"
	StatusFailed    = "FAILED"

	// PkgPath is this realm's own on-chain path, used in Render's
	// copy-paste commands.
	PkgPath = "gno.land/r/g10w0ycc9802gyja9w99xctx5s6vkgyc6fcj0f6u/komit"
)

// Challenge is one user's stake-backed habit streak.
type Challenge struct {
	Owner         address
	Habit         string
	TargetDays    int
	Stake         int64 // ugnot locked in the realm
	Streak        int   // consecutive daily check-ins so far
	StartDay      int64 // UTC day number (unix/86400) the challenge started
	LastCheckDay  int64 // UTC day number of the last check-in (StartDay-1 before the first)
	Status        string
	StartedHeight int64
}

var (
	activeByOwner  = make(map[address]*Challenge)
	finished       []*Challenge // completed and failed, oldest first
	poolBalance    int64        // ugnot forfeited into the shared reward pool, minus bonuses paid
	activeStaked   int64        // ugnot currently locked in active challenges
	totalStaked    int64        // ugnot staked all-time
	completedCount int
	failedCount    int
)

// today returns the current UTC day number, derived from the block time.
// In Gno, time.Now() returns the timestamp of the block the transaction is
// included in, so this is deterministic across validators.
func today() int64 {
	return time.Now().Unix() / 86400
}

// isStale reports whether the challenge's streak is broken at the given day:
// the last check-in day is older than yesterday.
func (c *Challenge) isStale(day int64) bool {
	return day > c.LastCheckDay+1
}

// breakChallenge closes an active challenge as failed and forfeits its stake
// into the shared reward pool. The coins stay at the realm address; only the
// accounting moves.
func breakChallenge(c *Challenge) {
	c.Status = StatusFailed
	poolBalance += c.Stake
	activeStaked -= c.Stake
	failedCount++
	delete(activeByOwner, c.Owner)
	finished = append(finished, c)

	chain.Emit(
		"ChallengeBroken",
		"owner", c.Owner.String(),
		"habit", c.Habit,
		"streak", strconv.Itoa(c.Streak),
		"forfeited_ugnot", strconv.FormatInt(c.Stake, 10),
	)
}

// startChallenge validates and records a new challenge for owner. Any stale
// previous challenge is broken first (lazy evaluation); a still-live previous
// challenge rejects the new one.
func startChallenge(owner address, habit string, targetDays int, stake int64, day int64) *Challenge {
	if prev, ok := activeByOwner[owner]; ok {
		if prev.isStale(day) {
			breakChallenge(prev)
		} else {
			panic("you already have an active challenge; finish it or let it break first")
		}
	}

	habit = strings.TrimSpace(habit)
	if habit == "" {
		panic("habit must not be empty")
	}
	if len(habit) > MaxHabitLen {
		panic("habit is too long (max 64 characters)")
	}
	if targetDays < MinTargetDays || targetDays > MaxTargetDays {
		panic("targetDays must be between 3 and 90")
	}
	if stake < MinStakeUgnot {
		panic("stake too small: send at least 1 GNOT (1000000ugnot) with the call")
	}
	if stake > MaxStakeUgnot {
		panic("stake too large: send at most 100 GNOT (100000000ugnot) with the call")
	}

	c := &Challenge{
		Owner:         owner,
		Habit:         habit,
		TargetDays:    targetDays,
		Stake:         stake,
		Streak:        0,
		StartDay:      day,
		LastCheckDay:  day - 1, // first check-in is due on the start day itself
		Status:        StatusActive,
		StartedHeight: runtime.ChainHeight(),
	}
	activeByOwner[owner] = c
	totalStaked += stake
	activeStaked += stake

	chain.Emit(
		"ChallengeStarted",
		"owner", owner.String(),
		"habit", habit,
		"target_days", strconv.Itoa(targetDays),
		"stake_ugnot", strconv.FormatInt(stake, 10),
	)
	return c
}

// checkInOn records a check-in for owner at the given UTC day. It returns the
// new streak, or (0, true) if the streak was broken by a missed day (the
// break is committed, not panicked, so the forfeit persists).
func checkInOn(owner address, day int64) (int, bool) {
	c, ok := activeByOwner[owner]
	if !ok {
		panic("no active challenge; start one first")
	}
	if c.isStale(day) {
		breakChallenge(c)
		return 0, true
	}
	if day == c.LastCheckDay {
		panic("already checked in today; come back tomorrow (UTC)")
	}
	// Here day == LastCheckDay+1: the consecutive day.
	c.Streak++
	c.LastCheckDay = day

	chain.Emit(
		"CheckedIn",
		"owner", owner.String(),
		"habit", c.Habit,
		"streak", strconv.Itoa(c.Streak),
		"target_days", strconv.Itoa(c.TargetDays),
	)
	return c.Streak, false
}

// claimOn settles owner's challenge at the given UTC day. If the streak is
// broken by then, the stake is forfeited and 0 is paid. If the target is
// reached, it pays stake + bonus where bonus = min(pool balance, stake),
// following Checks-Effects-Interactions: state is updated before the
// coin transfer.
func claimOn(cur realm, owner address, day int64) int64 {
	c, ok := activeByOwner[owner]
	if !ok {
		panic("no active challenge to claim")
	}
	if c.isStale(day) {
		breakChallenge(c)
		return 0
	}
	if c.Streak < c.TargetDays {
		panic("target not reached yet: streak " + strconv.Itoa(c.Streak) + " of " + strconv.Itoa(c.TargetDays))
	}

	bonus := poolBalance
	if bonus > c.Stake {
		bonus = c.Stake
	}
	payout := c.Stake + bonus

	// Effects before interactions.
	c.Status = StatusCompleted
	poolBalance -= bonus
	activeStaked -= c.Stake
	completedCount++
	delete(activeByOwner, owner)
	finished = append(finished, c)

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), owner, chain.NewCoins(chain.NewCoin(DenomUgnot, payout)))

	chain.Emit(
		"ChallengeClaimed",
		"owner", owner.String(),
		"habit", c.Habit,
		"stake_ugnot", strconv.FormatInt(c.Stake, 10),
		"bonus_ugnot", strconv.FormatInt(bonus, 10),
		"payout_ugnot", strconv.FormatInt(payout, 10),
	)
	return payout
}

// StartChallenge starts a new habit challenge, locking the ugnot sent with
// the call as the caller's stake. Send between 1 and 100 GNOT
// (1000000 to 100000000 ugnot) with -send. Your first CheckIn is due the
// same UTC day.
func StartChallenge(cur realm, habit string, targetDays int) {
	if !cur.Previous().IsUser() {
		panic("StartChallenge must be called directly by a user account")
	}
	owner := cur.Previous().Address()
	stake := unsafe.OriginSend().AmountOf(DenomUgnot)
	startChallenge(owner, habit, targetDays, stake, today())
}

// CheckIn records today's check-in. It returns the new streak, or 0 if a
// missed day broke the streak and forfeited the stake to the reward pool.
func CheckIn(cur realm) int {
	if !cur.Previous().IsUser() {
		panic("CheckIn must be called directly by a user account")
	}
	streak, _ := checkInOn(cur.Previous().Address(), today())
	return streak
}

// Claim settles the caller's challenge. If the streak reached the target,
// it returns the payout in ugnot (stake + bonus of up to the stake again,
// drawn from the reward pool). If a missed day broke the streak, the stake
// is forfeited and 0 is returned. Claim by the day after your last
// check-in at the latest, or the challenge breaks like any other.
func Claim(cur realm) int64 {
	if !cur.Previous().IsUser() {
		panic("Claim must be called directly by a user account")
	}
	return claimOn(cur, cur.Previous().Address(), today())
}

// --- Read-only getters (used by Render and available via vm/qeval) ---

func ActiveChallenges() int { return len(activeByOwner) }

func PoolUgnot() int64 { return poolBalance }

func ActiveStakedUgnot() int64 { return activeStaked }

func TotalStakedUgnot() int64 { return totalStaked }

func CompletedCount() int { return completedCount }

func FailedCount() int { return failedCount }

// MyChallenge returns a one-line summary of the caller's active challenge,
// or an empty string if they have none. Note: as a read-only query it does
// not apply lazy break evaluation.
func MyChallenge(addr address) string {
	c, ok := activeByOwner[addr]
	if !ok {
		return ""
	}
	return c.Habit + ": streak " + strconv.Itoa(c.Streak) + "/" + strconv.Itoa(c.TargetDays) +
		", stake " + strconv.FormatInt(c.Stake, 10) + "ugnot, started day " + strconv.FormatInt(c.StartDay, 10)
}
