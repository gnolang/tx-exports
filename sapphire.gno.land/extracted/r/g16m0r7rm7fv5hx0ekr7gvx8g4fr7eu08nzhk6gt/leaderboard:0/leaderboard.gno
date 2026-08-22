package leaderboard

import (
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/ringbuffer"
)

// PlayerRecord holds a player's cumulative score and recent score history.
type PlayerRecord struct {
	Player     address
	TotalScore int64
	Submissions int64
	History    *ringbuffer.Buffer // last N individual score submissions
	LastSubmitAt int64
}

const historyCapacity = 10

var (
	admin   address
	records *avl.Tree // addr -> *PlayerRecord
)

func init() {
	admin = address("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")
	records = avl.NewTree()
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("leaderboard: must be a direct user call")
	}
	return cur.Previous().Address()
}

// SubmitScore lets a player submit a new score, adding to their cumulative total.
func SubmitScore(cur realm, score int64) {
	caller := assertUserCall(cur)
	if score < 0 {
		panic("leaderboard: score must be non-negative")
	}

	key := string(caller)
	var rec *PlayerRecord
	if records.Has(key) {
		rec = records.Get(key).(*PlayerRecord)
	} else {
		rec = &PlayerRecord{
			Player:  caller,
			History: ringbuffer.New(historyCapacity),
		}
		records.Set(key, rec)
	}

	rec.TotalScore += score
	rec.Submissions++
	rec.History.Push(score)
	rec.LastSubmitAt = runtime.ChainHeight()
}

// GetScore returns a player's cumulative total score.
func GetScore(player address) int64 {
	key := string(player)
	if !records.Has(key) {
		return 0
	}
	rec := records.Get(key).(*PlayerRecord)
	return rec.TotalScore
}

// GetAverage returns a player's average score over their recent history window.
func GetAverage(player address) int64 {
	key := string(player)
	if !records.Has(key) {
		panic("leaderboard: no record for player")
	}
	rec := records.Get(key).(*PlayerRecord)
	return rec.History.Average()
}

// ResetPlayer lets the admin clear a single player's record (e.g. moderation).
func ResetPlayer(cur realm, player address) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("leaderboard: admin only")
	}
	key := string(player)
	if records.Has(key) {
		records.Remove(key)
	}
}

// Top returns up to n (player, score) pairs sorted by total score descending.
// This does a full scan; fine for moderate leaderboard sizes.
func topN(n int) ([]address, []int64) {
	type pair struct {
		addr  address
		score int64
	}
	all := []pair{}
	records.Iterate("", "", func(key string, value interface{}) bool {
		rec := value.(*PlayerRecord)
		all = append(all, pair{addr: rec.Player, score: rec.TotalScore})
		return false
	})

	// simple insertion sort descending by score
	for i := 1; i < len(all); i++ {
		k := all[i]
		j := i - 1
		for j >= 0 && all[j].score < k.score {
			all[j+1] = all[j]
			j--
		}
		all[j+1] = k
	}

	if n > len(all) {
		n = len(all)
	}
	addrs := make([]address, n)
	scores := make([]int64, n)
	for i := 0; i < n; i++ {
		addrs[i] = all[i].addr
		scores[i] = all[i].score
	}
	return addrs, scores
}

func Render(path string) string {
	out := "# Leaderboard\n\n"
	out += ufmt.Sprintf("Total players: %d\n\n", records.Size())
	addrs, scores := topN(10)
	for i := range addrs {
		out += ufmt.Sprintf("%d. %s - %d points\n", i+1, addrs[i], scores[i])
	}
	return out
}
