// Package ratelimit ports golang.org/x/time/rate (the standard Go
// token-bucket rate limiter) to an on-chain gno.land realm.
//
// Each caller address owns a token bucket with a fixed capacity (burst)
// that refills at a steady rate expressed in tokens per block. There is no
// wall clock on-chain, so runtime.ChainHeight() is the monotonic clock:
// between two observations at heights `last` and `now`, the bucket gains
// (now-last)*rate tokens, capped at `burst`. Everything is pure, integer/
// float arithmetic over persistent avl state, hence deterministic.
package ratelimit

import (
	"strconv"

	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
)

// Limiter configuration, shared by every caller bucket.
// rate  = tokens replenished per block.
// burst = bucket capacity (max tokens, also the largest single burst).
var (
	rate  float64 = 0.5 // one token every 2 blocks
	burst float64 = 5.0
)

// bucket is the per-caller state persisted in the avl tree.
type bucket struct {
	tokens float64 // tokens available as of `last`
	last   int64   // block height at which `tokens` was computed
}

// buckets maps address string -> *bucket, ordered by key (deterministic).
var buckets = avl.NewTree()

// --- pure helpers (unit-tested) -------------------------------------------

// fmin returns the smaller of two float64 values.
func fmin(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

// refill returns the token count at height `now` given `tokens` observed at
// height `last`, replenishing at `r` tokens/block up to capacity `cap`.
// It never decreases below the stored value and never exceeds `cap`.
func refill(tokens float64, last, now int64, r, cap float64) float64 {
	if now <= last {
		return fmin(tokens, cap)
	}
	elapsed := float64(now - last)
	return fmin(cap, tokens+elapsed*r)
}

// tokensToInt floors a token count to a whole, non-negative token.
func tokensToInt(t float64) int {
	if t < 0 {
		return 0
	}
	return int(t)
}

// --- state access ----------------------------------------------------------

// load returns the live bucket for addr, refilled to `now`, creating a full
// bucket the first time an address is seen.
func load(key string, now int64) *bucket {
	if buckets.Has(key) {
		b := buckets.Get(key).(*bucket)
		b.tokens = refill(b.tokens, b.last, now, rate, burst)
		b.last = now
		return b
	}
	return &bucket{tokens: burst, last: now}
}

// --- exported API -----------------------------------------------------------

// Allow consumes one token for the calling realm/user and reports whether the
// request is permitted. Returns false (and consumes nothing) when the bucket
// is empty.
func Allow(cur realm) bool {
	addr := unsafe.PreviousRealm().Address()
	key := string(addr)
	now := runtime.ChainHeight()

	b := load(key, now)
	ok := b.tokens >= 1.0
	if ok {
		b.tokens -= 1.0
	}
	buckets.Set(key, b)
	return ok
}

// SetConfig updates the shared rate (tokens per block) and burst (capacity).
// Values are clamped to be non-negative; burst is forced to at least 1.
func SetConfig(cur realm, newRate, newBurst float64) {
	if newRate < 0 {
		newRate = 0
	}
	if newBurst < 1 {
		newBurst = 1
	}
	rate = newRate
	burst = newBurst
}

// Tokens is a read-only view of how many whole tokens `addr` has available at
// the current block height, without mutating any state.
func Tokens(addr address) int {
	key := string(addr)
	now := runtime.ChainHeight()
	if !buckets.Has(key) {
		return tokensToInt(burst)
	}
	b := buckets.Get(key).(*bucket)
	return tokensToInt(refill(b.tokens, b.last, now, rate, burst))
}

// --- rendering --------------------------------------------------------------

func ftoa(f float64) string {
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// Render shows the limiter config and a table of known callers with their
// current tokens and last-seen height. Path "/addr/<address>" focuses one
// caller.
func Render(path string) string {
	now := runtime.ChainHeight()

	if len(path) > 6 && path[:6] == "/addr/" {
		key := path[6:]
		out := "# Rate Limiter — caller\n\n"
		out += "Address: `" + key + "`\n\n"
		if !buckets.Has(key) {
			out += "_Never seen — a full bucket of " + ftoa(burst) + " tokens is available._\n"
			return out
		}
		b := buckets.Get(key).(*bucket)
		cur := refill(b.tokens, b.last, now, rate, burst)
		out += "- Current tokens: **" + strconv.Itoa(tokensToInt(cur)) + "** / " + ftoa(burst) + "\n"
		out += "- Last seen at height: " + strconv.FormatInt(b.last, 10) + "\n"
		out += "- Now (height): " + strconv.FormatInt(now, 10) + "\n"
		return out
	}

	out := "# Rate Limiter\n\n"
	out += "Token-bucket limiter (port of `golang.org/x/time/rate`), on-chain.\n\n"
	out += "## Config\n\n"
	out += "| Parameter | Value |\n|---|---|\n"
	out += "| Rate (tokens/block) | " + ftoa(rate) + " |\n"
	out += "| Burst (capacity) | " + ftoa(burst) + " |\n"
	out += "| Clock height | " + strconv.FormatInt(now, 10) + " |\n\n"

	out += "## Callers\n\n"
	if buckets.Size() == 0 {
		out += "_No caller has hit the limiter yet._\n\n"
	} else {
		out += "| Address | Tokens | Last height |\n|---|---|---|\n"
		buckets.Iterate("", "", func(key string, value any) bool {
			b := value.(*bucket)
			cur := refill(b.tokens, b.last, now, rate, burst)
			out += "| `" + key + "` | " + strconv.Itoa(tokensToInt(cur)) +
				" | " + strconv.FormatInt(b.last, 10) + " |\n"
			return false
		})
		out += "\n"
	}

	out += "---\n"
	out += "Call `Allow(cur)` to consume a token; read `Tokens(addr)` for a caller's balance.\n"
	return out
}
