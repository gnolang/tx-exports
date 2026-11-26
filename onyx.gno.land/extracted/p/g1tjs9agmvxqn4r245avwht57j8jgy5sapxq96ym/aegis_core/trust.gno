package aegis_core

// TrustRecord only counts matches where real ugnot was at stake.
// Friendly matches never touch it, so reputation cannot be farmed for free.
type TrustRecord struct {
	RankedWins   int64
	RankedLosses int64
	Forfeits     int64 // committed but never revealed: bond slashed
	StakedVolume int64 // total ugnot bet on this fighter's matches
}

// TrustScore turns a record into a 0..1000 score.
//
//	base   = 500
//	+ 25 per ranked win, -10 per ranked loss
//	- 150 per forfeit (match-fixing signal)
//	+ 1 per 1 GNOT (1_000_000 ugnot) of staked volume, capped at +200
func TrustScore(r TrustRecord) int64 {
	s := int64(500)
	s += 25 * r.RankedWins
	s -= 10 * r.RankedLosses
	s -= 150 * r.Forfeits
	vol := r.StakedVolume / 1_000_000
	if vol > 200 {
		vol = 200
	}
	s += vol
	if s < 0 {
		s = 0
	}
	if s > 1000 {
		s = 1000
	}
	return s
}

// Pool split in basis points.
const (
	WinnersBps = 9500
	BackersBps = 300
	SeasonBps  = 200
)

// SplitPool splits a pool 95/3/2. Rounding dust goes to winners so
// winners+backers+season == total, always.
func SplitPool(total int64) (winners, backers, season int64) {
	backers = total * BackersBps / 10000
	season = total * SeasonBps / 10000
	winners = total - backers - season
	return
}

// ProRata returns stake * pot / totalStake (0 if totalStake == 0).
func ProRata(stake, pot, totalStake int64) int64 {
	if totalStake == 0 {
		return 0
	}
	return stake * pot / totalStake
}
