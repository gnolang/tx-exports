package competition

import (
	"chain/runtime"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

type ScoreSubmission struct {
	Seed int64
	Score int
	Digest string
	Verifier address
	VerifierKey string
	Proof string
	ExpiresAt int64
	AcceptedAt int64
}

type WeeklyPilot struct {
	Attempts int
	Flights [attemptCap]ScoreSubmission
	Best ScoreSubmission
	Prize int64
	Rank int
	Claimed bool
}

type Season struct {
	ID int64
	Seed int64
	Shares [10]int64
	FinalizedAt int64
	Snapshot int64
	CarryIn int64
	CarryOut int64
	Reserved int64
	Claimed int64
	Revenue RevenueLedger
	pilots map[address]*WeeklyPilot
	ranking *avl.Tree
}

func defaultShares() [10]int64 {
	return [10]int64{3000, 1800, 1300, 1000, 800, 600, 500, 400, 300, 300}
}

func sharesFor(id int64) [10]int64 {
	if shares, exists := seasonRules[id]; exists {
		return shares
	}
	return defaultShares()
}

func newSeason(id int64, shares [10]int64) *Season {
	return &Season{
		ID: id, Seed: seasonSeed(id), Shares: shares,
		pilots: make(map[address]*WeeklyPilot), ranking: avl.NewTree(),
	}
}

func seasonSeed(id int64) int64 {
	return (id%4294967296*1664525 + 1013904223) % 4294967296
}

func getSeason(id int64) *Season {
	if s := seasons[id]; s != nil {
		return s
	}
	s := newSeason(id, sharesFor(id))
	seasons[id] = s
	return s
}

func (s *Season) record(pilot address, submission ScoreSubmission) {
	require(s.FinalizedAt == 0, "season finalized")
	p := s.pilots[pilot]
	if p == nil {
		p = &WeeklyPilot{}
		s.pilots[pilot] = p
	}
	for i := 0; i < p.Attempts; i++ {
		require(p.Flights[i].Digest != submission.Digest, "replay already used")
	}
	require(p.Attempts < attemptCap, "all three flights used")
	p.Flights[p.Attempts] = submission
	p.Attempts++
	if p.Attempts == 1 || submission.Score > p.Best.Score {
		if p.Attempts > 1 {
			s.ranking.Remove(scoreKey(pilot, p.Best))
		}
		p.Best = submission
		s.ranking.Set(scoreKey(pilot, submission), pilot)
	}
}

func scoreKey(pilot address, submission ScoreSubmission) string {
	score := decimal(int64(maxScore-submission.Score))
	timestamp := decimal(submission.AcceptedAt)
	return strings.Repeat("0", 5-len(score)) + score + ":" +
		strings.Repeat("0", 20-len(timestamp)) + timestamp + ":" + string(pilot)
}

func (s *Season) pilotRank(pilot address, p *WeeklyPilot) int {
	key := scoreKey(pilot, p.Best)
	low, high := 0, s.ranking.Size()
	for low < high {
		mid := low+(high-low)/2
		candidate, _ := s.ranking.GetByIndex(mid)
		if candidate < key {
			low = mid+1
		} else {
			high = mid
		}
	}
	return low+1
}

func checkEvidence(now, expiry, deadline, expectedSeed, seed int64, version string, score int, digest string) {
	require(now < deadline && now < expiry && expiry <= deadline, "submission expired")
	require(seed == expectedSeed && version == ruleset, "wrong mission seed or ruleset")
	require(score >= 0 && score <= maxScore && validHex(digest, 64), "invalid score or replay digest")
}

// The verifier's Gno transaction is the signed attestation. The pilot
// authorizes the replay off chain and pays no Gno transaction fees.
func SubmitWeekly(cur realm, pilot address, id, seed int64, version string, score int, digest string, expiry int64) {
	runtime.AssertOriginCall()
	signer := paidCaller(cur, 0)
	require(signer == verifier && pilot.IsValid(), "verified pilot required")
	now := time.Now().Unix()
	require(!paused && firstSeason > 0 && id >= firstSeason && id == weekID(now), "season closed to entries")
	checkEvidence(now, expiry, weekStart(id+1), seasonSeed(id), seed, version, score, digest)
	getSeason(id).record(pilot, ScoreSubmission{Seed: seed, Score: score, Digest: digest, Verifier: signer, ExpiresAt: expiry, AcceptedAt: now})
}

func FinalizeWeek(cur realm, id int64) {
	runtime.AssertOriginCall()
	paidCaller(cur, 0)
	now := time.Now().Unix()
	require(firstSeason > 0 && id >= firstSeason && id < weekID(now), "week is still open")
	if id < nextSnapshot {
		return
	}
	require(id == nextSnapshot, "finalize previous week first")
	s := getSeason(id)
	s.snapshot(now)
	getSeason(id+1).CarryIn = s.CarryOut
	nextSnapshot++
}

func (s *Season) snapshot(now int64) {
	require(s.FinalizedAt == 0, "already finalized")
	s.Snapshot = checkedAdd(s.CarryIn, s.Revenue.Allocation)
	for i := 0; i < len(s.Shares) && i < s.ranking.Size(); i++ {
		_, entry := s.ranking.GetByIndex(i)
		p := s.pilots[entry.(address)]
		p.Rank = i+1
		p.Prize = basisPoints(s.Snapshot, s.Shares[i])
		s.Reserved = checkedAdd(s.Reserved, p.Prize)
	}
	s.CarryOut = s.Snapshot-s.Reserved
	s.FinalizedAt = now
}

func ClaimPrize(cur realm, id int64) int64 {
	runtime.AssertOriginCall()
	pilot := paidCaller(cur, 0)
	s := seasons[id]
	require(s != nil && s.FinalizedAt != 0, "snapshot required")
	amount := s.claim(pilot)
	pay(cur, pilot, amount)
	return amount
}

func (s *Season) claim(pilot address) int64 {
	p := s.pilots[pilot]
	require(p != nil && p.Rank > 0 && p.Prize > 0, "no prize for this address")
	if p.Claimed {
		return 0
	}
	p.Claimed = true
	s.Claimed = checkedAdd(s.Claimed, p.Prize)
	require(s.Claimed <= s.Reserved, "claims exceed snapshot")
	return p.Prize
}
