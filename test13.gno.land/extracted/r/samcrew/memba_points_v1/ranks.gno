package memba_points_v1

import (
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// On-chain leaderboard: a secondary index over accounts, keyed so the tree orders by points.
// Key = zeroPad(points,19) + ":" + addr → ascending avl order is points-ascending; ReverseIterate
// yields points-DESCENDING (leaders first). Value = the addr string — points are recovered from the
// key, so we never store the same *Account pointer in two trees. An account is in `ranks` iff points>0.
var ranks = avl.NewTree() // rankKey -> addr string

const (
	// MaxTopN bounds a single TopN/TopNPage response (size + node CPU).
	MaxTopN = 200
	// defaultTopN is used when a caller passes count <= 0.
	defaultTopN = 50
)

// rankKey orders ascending by points (19-digit zero-pad — maxInt64 is 19 digits), addr for uniqueness.
func rankKey(points int64, addr string) string { return zeroPad19(points) + ":" + addr }

func zeroPad19(n int64) string {
	s := itoa64(n)
	for len(s) < 19 {
		s = "0" + s
	}
	return s
}

// rankApply maintains `ranks` from Award/Revoke ONLY. old/new are the pre/post points for addr.
// Remove the stale key, insert the new one; an account dropping to 0 is evicted (never re-inserted).
func rankApply(addr string, old, new int64) {
	if old > 0 {
		ranks.Remove(rankKey(old, addr))
	}
	if new > 0 {
		ranks.Set(rankKey(new, addr), addr)
	}
}

// splitRankKey recovers (points, addr) from a stored key.
func splitRankKey(key string) (int64, string) {
	i := strings.Index(key, ":")
	if i < 0 {
		return 0, key
	}
	pts, _ := parseNonNegInt(key[:i])
	return pts, key[i+1:]
}

// TopN returns up to min(n, MaxTopN) leaders (points-descending) as JSON:
// [{"rank":1,"addr":"g1..","points":123,"tier":"Gold"},...]
func TopN(n int) string { return topNFrom(0, n) }

// TopNPage returns a page of the leaderboard from offset (0-based), up to min(count, MaxTopN).
func TopNPage(offset, count int) string { return topNFrom(offset, count) }

func topNFrom(offset, count int) string {
	if count <= 0 {
		count = defaultTopN
	}
	if count > MaxTopN {
		count = MaxTopN
	}
	if offset < 0 {
		offset = 0
	}
	var sb strings.Builder
	sb.WriteString("[")
	first := true
	rank := offset + 1
	ranks.ReverseIterateByOffset(offset, count, func(key string, _ any) bool {
		pts, addr := splitRankKey(key)
		if !first {
			sb.WriteString(",")
		}
		first = false
		sb.WriteString(ufmt.Sprintf(`{"rank":%d,"addr":"%s","points":%d,"tier":"%s"}`,
			rank, jsonEscape(addr), pts, jsonEscape(tierFor(pts))))
		rank++
		return false
	})
	sb.WriteString("]")
	return sb.String()
}

// rankAndHolders returns addr's 1-based rank (0 if it holds none) and the total holder count.
// Exact O(log^2 n): binary-search the ascending index via GetByIndex, then invert to a descending rank.
func rankAndHolders(addr string, pts int64) (int, int) {
	holders := ranks.Size()
	rank := 0
	if pts > 0 {
		if idx := rankIndexOf(rankKey(pts, addr)); idx >= 0 {
			rank = holders - idx // ascending idx (0=lowest) → descending rank (idx=size-1 → rank 1)
		}
	}
	return rank, holders
}

// rankIndexOf returns the ascending index of an exact key in `ranks`, or -1 if absent.
func rankIndexOf(key string) int {
	lo, hi := 0, ranks.Size()-1
	for lo <= hi {
		mid := (lo + hi) / 2
		k, _ := ranks.GetByIndex(mid)
		if k == key {
			return mid
		}
		if k < key {
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return -1
}

// RankOf returns {"addr","points","rank","holders"}; rank/points are 0 if the address holds none.
func RankOf(addr string) string {
	pts := GetPoints(addr)
	rank, holders := rankAndHolders(addr, pts)
	return ufmt.Sprintf(`{"addr":"%s","points":%d,"rank":%d,"holders":%d}`,
		jsonEscape(addr), pts, rank, holders)
}

// ProfileJSON returns points + tier + rank + holders in ONE call (frontend profile, one round-trip).
func ProfileJSON(addr string) string {
	pts := GetPoints(addr)
	rank, holders := rankAndHolders(addr, pts)
	return ufmt.Sprintf(`{"addr":"%s","points":%d,"tier":"%s","rank":%d,"holders":%d}`,
		jsonEscape(addr), pts, jsonEscape(tierFor(pts)), rank, holders)
}
