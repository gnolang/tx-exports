package oracle

import (
	"time"

	"chain"
	"chain/runtime/unsafe"

	poracle "gno.land/p/g18ugne5ng6eylkca4mqeet9luj0xaykp84sh2cf/oracle/v1"
)

const (
	maxFeeds   = 16
	maxPairLen = 128
)

type feed struct {
	pair      string
	tick      int32
	liquidity string
	windowSec uint32
	maxAgeSec int64
	updatedAt int64
}

var (
	admin address
	feeds []feed
)

func init() {
	c := unsafe.OriginCaller()
	if c.IsValid() {
		admin = c
	}
}

func Admin() address {
	return admin
}

func FeedCount() int {
	return len(feeds)
}

func requireAdmin(cur realm) {
	caller := cur.Previous().Address()
	if !admin.IsValid() {
		if !caller.IsValid() {
			panic("oracle: no admin")
		}
		admin = caller
		return
	}
	if caller != admin {
		panic("oracle: admin only")
	}
}

func validPair(pair string) bool {
	if pair == "" || len(pair) > maxPairLen {
		return false
	}
	for i := 0; i < len(pair); i++ {
		c := pair[i]
		ok := (c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '_' || c == '-' || c == '/' || c == '|' || c == ':' || c == '.'
		if !ok {
			return false
		}
	}
	return true
}

func find(pair string) int {
	for i := 0; i < len(feeds); i++ {
		if feeds[i].pair == pair {
			return i
		}
	}
	return -1
}

// TransferAdmin rotates the admin. Crossing; caller must be current admin.
func TransferAdmin(cur realm, next address) {
	requireAdmin(cur)
	if !next.IsValid() {
		panic("oracle: invalid admin")
	}
	prev := admin
	admin = next
	chain.Emit("AdminChange", "old", prev.String(), "new", next.String())
}

// SetManualFeed upserts a manual observation.
// Grade is always Informational (v1 never stamps Oracle).
func SetManualFeed(cur realm, pair string, tick int32, liquidity string, windowSec uint32, maxAgeSec int64) {
	requireAdmin(cur)
	if !validPair(pair) {
		panic("oracle: invalid pair")
	}
	if windowSec == 0 {
		panic("oracle: windowSec required")
	}
	if maxAgeSec < 1 {
		panic("oracle: maxAgeSec required")
	}
	if len(liquidity) > 128 {
		panic("oracle: liquidity too long")
	}
	now := time.Now().Unix()
	i := find(pair)
	f := feed{
		pair:      pair,
		tick:      tick,
		liquidity: liquidity,
		windowSec: windowSec,
		maxAgeSec: maxAgeSec,
		updatedAt: now,
	}
	if i < 0 {
		if len(feeds) >= maxFeeds {
			panic("oracle: feed cap")
		}
		feeds = append(feeds, f)
	} else {
		feeds[i] = f
	}
	chain.Emit("ManualFeed", "pair", pair)
}

// RemoveFeed deletes a pair.
func RemoveFeed(cur realm, pair string) {
	requireAdmin(cur)
	i := find(pair)
	if i < 0 {
		panic("oracle: unknown pair")
	}
	feeds = append(feeds[:i], feeds[i+1:]...)
	chain.Emit("RemoveFeed", "pair", pair)
}

// Consult is a read. Missing or stale feeds return GradeNone.
func Consult(pair string) poracle.Quote {
	if !validPair(pair) {
		return poracle.None(pair, "invalid pair")
	}
	i := find(pair)
	if i < 0 {
		return poracle.None(pair, "unknown pair")
	}
	f := feeds[i]
	now := time.Now().Unix()
	if f.updatedAt <= 0 || now-f.updatedAt > f.maxAgeSec {
		return poracle.None(pair, "stale")
	}
	return poracle.Informational(pair, f.tick, f.liquidity, f.updatedAt, f.windowSec, poracle.SourceManual)
}

// MustInformational panics unless Consult is at least informational.
func MustInformational(pair string) poracle.Quote {
	q := Consult(pair)
	q.RequireAtLeast(poracle.GradeInformational)
	return q
}
