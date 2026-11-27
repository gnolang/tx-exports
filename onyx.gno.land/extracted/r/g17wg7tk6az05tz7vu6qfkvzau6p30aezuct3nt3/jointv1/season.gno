package jointv1

import (
	"time"

	"chain"
	"chain/banker"

	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
)

// Seasons and the prize pot. The realm keeps one season. While it is running,
// shop sales add to the live pot. Freeze copies the live boards and splits
// that pot; claims pay the copy. The next StartSeason waits until every rank
// that would pay has claimed, then drops the copy. Live boards are cleared
// at the start. Each tavern's season fields are cleared lazily, the next
// time it is settled, by comparing ScoreGen to seasonGen.

const (
	// MinPubPotBps and MaxPubPotBps bound the pubs' share of a frozen pot.
	MinPubPotBps int64 = 4000
	MaxPubPotBps int64 = 8000

	minSeasonSeconds int64 = 60
	maxSeasonSeconds int64 = 86400 * 30
)

// Season is the frozen prize snapshot. Number 0 means a season has never
// started. Pots are ugnot. Top and FarmTop are copies of the live boards
// at the freeze, and Claimed* marks a rank (0-based) already paid.
type Season struct {
	Number, EndsAt, PotUgnot, PubPotUgnot, FarmPotUgnot int64
	Frozen                                              bool
	Top                                                 [TopN]townmath.Entry
	TopLen                                              int
	FarmTop                                             [TopN]townmath.Entry
	FarmTopLen                                          int
	ClaimedPubs, ClaimedFarms                           [TopN]bool
}

// PubPotBps is the pubs' share of the next freeze, in basis points.
func PubPotBps() int64 { return pubPotBps }

// GetSeason returns a copy of the season snapshot.
func GetSeason() Season { return season }

// SeasonGen returns the live season generation. StartSeason increments it.
// Read-only.
func SeasonGen() int64 { return seasonGen }

// StartSeason opens a season of durationSeconds (60 to 30 days). Admin only.
// Allowed when no season has started, or the current one is frozen and every
// rank that would pay has been claimed. Live boards are cleared. Per-tavern
// scores are left in place until the next settle (see seasonGen).
func StartSeason(cur realm, durationSeconds int64) {
	assertAdmin(cur)
	assertNoSend()
	if durationSeconds < minSeasonSeconds || durationSeconds > maxSeasonSeconds {
		panic("town: season duration must be 60 to 2592000")
	}
	if season.Number != 0 && !season.Frozen {
		panic("town: season already active")
	}
	if season.Frozen && unclaimedPrizes() {
		panic("town: unclaimed prizes")
	}
	seasonGen++
	season = Season{
		Number: season.Number + 1,
		EndsAt: time.Now().Unix() + durationSeconds,
	}
	clearLiveBoards()
}

// FreezeSeason snapshots the live boards and splits the live pot. Anyone may
// call it, once, at or after EndsAt. The live pot is zeroed so later sales
// accumulate the next season's pot; the shop stays open.
func FreezeSeason(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("town: must be a direct user call")
	}
	assertNoSend()
	if season.Number == 0 || season.Frozen || time.Now().Unix() < season.EndsAt {
		panic("town: season not ended")
	}
	season.Frozen = true
	season.Top = top
	season.TopLen = topLen
	season.FarmTop = farmTop
	season.FarmTopLen = farmTopLen
	pot := potUgnot
	season.PotUgnot = pot
	season.PubPotUgnot = townmath.MulBps(pot, pubPotBps)
	season.FarmPotUgnot = pot - season.PubPotUgnot
	potUgnot = 0
	for i := 0; i < TopN; i++ { // TopN is 10
		season.ClaimedPubs[i] = false
		season.ClaimedFarms[i] = false
	}
}

// ClaimPrize pays the caller their frozen prize, pubs or farms. The realm
// balance is checked, then the rank is marked, then the coins are sent.
func ClaimPrize(cur realm) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("town: must be a direct user call")
	}
	assertNoSend()
	if !season.Frozen {
		panic("town: season not frozen")
	}
	caller := prev.Address().String()
	farm := false
	rank := -1
	for i := 0; i < season.TopLen && i < TopN; i++ {
		if season.Top[i].Owner == caller {
			rank = i
			break
		}
	}
	if rank < 0 {
		farm = true
		for i := 0; i < season.FarmTopLen && i < TopN; i++ {
			if season.FarmTop[i].Owner == caller {
				rank = i
				break
			}
		}
	}
	if rank < 0 {
		panic("town: not a winner")
	}
	if farm {
		if season.ClaimedFarms[rank] {
			panic("town: already claimed")
		}
	} else if season.ClaimedPubs[rank] {
		panic("town: already claimed")
	}
	pot := season.PubPotUgnot
	if farm {
		pot = season.FarmPotUgnot
	}
	amt := townmath.Payout(pot, rank+1)
	if amt == 0 {
		panic("town: nothing to claim")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if bk.GetCoin(cur.Address(), "ugnot") < amt {
		panic("town: insufficient realm balance")
	}
	if farm {
		season.ClaimedFarms[rank] = true
	} else {
		season.ClaimedPubs[rank] = true
	}
	bk.SendCoins(cur.Address(), prev.Address(), chain.NewCoins(chain.NewCoin("ugnot", amt)))
}

// unclaimedPrizes reports whether a frozen snapshot still owes a rank whose
// payout would be more than zero.
func unclaimedPrizes() bool {
	for i := 0; i < season.TopLen && i < TopN; i++ {
		if !season.ClaimedPubs[i] && townmath.Payout(season.PubPotUgnot, i+1) > 0 {
			return true
		}
	}
	for i := 0; i < season.FarmTopLen && i < TopN; i++ {
		if !season.ClaimedFarms[i] && townmath.Payout(season.FarmPotUgnot, i+1) > 0 {
			return true
		}
	}
	return false
}

func clearLiveBoards() {
	topLen = 0
	farmTopLen = 0
	for i := 0; i < TopN; i++ { // TopN is 10
		top[i] = townmath.Entry{}
		farmTop[i] = townmath.Entry{}
	}
}
