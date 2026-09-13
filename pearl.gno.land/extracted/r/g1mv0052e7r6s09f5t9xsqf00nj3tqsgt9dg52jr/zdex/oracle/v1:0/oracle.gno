package oracle

import (
	"chain"
	"chain/runtime"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/amm/v1"
	"gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/v2"
)

const (
	ringCap      = 32
	scaleX6      = int64(1_000_000)
	dexPkg       = "gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/v2"
	protoVersion = "1"
)

type Sample struct {
	H  int64
	Px int64
}

type Ring struct {
	Items []Sample
}

var rings avl.Tree // poolID -> *Ring

func Version() string { return protoVersion }
func DexPkg() string  { return dexPkg }

func height() int64 { return runtime.ChainHeight() }

func require(cond bool, msg string) {
	if !cond {
		panic(msg)
	}
}

func getRing(poolID string) *Ring {
	if v := rings.Get(poolID); v != nil {
		return v.(*Ring)
	}
	r := &Ring{}
	rings.Set(poolID, r)
	return r
}

// Ping stores SpotPrice for poolID. Same height overwrites last. Ring drops oldest at 32.
func Ping(cur realm, poolID string) int64 {
	require(cur.Previous().IsUserCall(), "zdex: EOA-only")
	ru, rt, vu, _, _ := zdex.PoolInfo(poolID)
	den := ru + vu
	require(den > 0 && rt > 0, "zdex: empty pool")
	px := amm.MulDiv(rt, scaleX6, den)
	h := height()
	r := getRing(poolID)
	n := len(r.Items)
	if n > 0 && r.Items[n-1].H == h {
		r.Items[n-1].Px = px
		chain.Emit("Ping", "pool", poolID, "px", itoa(px), "h", itoa(h))
		return px
	}
	if n >= ringCap {
		r.Items = r.Items[1:]
	}
	r.Items = append(r.Items, Sample{H: h, Px: px})
	chain.Emit("Ping", "pool", poolID, "px", itoa(px), "h", itoa(h))
	return px
}

// Observe is TWAP of stored spots over [now-agoBlocks, now]. Panics if the window is thin.
func Observe(poolID string, agoBlocks int64) int64 {
	require(agoBlocks > 0, "zdex: window")
	r := getRing(poolID)
	require(len(r.Items) >= 2, "zdex: thin window")
	now := height()
	target := now - agoBlocks
	if r.Items[0].H > target {
		panic("zdex: thin window")
	}
	num, den := int64(0), int64(0)
	for i, s := range r.Items {
		from := s.H
		to := now
		if i+1 < len(r.Items) {
			to = r.Items[i+1].H
		}
		if to <= target {
			continue
		}
		if from < target {
			from = target
		}
		if to > now {
			to = now
		}
		dt := to - from
		if dt <= 0 {
			continue
		}
		add, ok := mul(s.Px, dt)
		if !ok {
			chain.Emit("ObserveSkip", "pool", poolID)
			continue
		}
		num, ok = add64(num, add)
		if !ok {
			chain.Emit("ObserveSkip", "pool", poolID)
			continue
		}
		den += dt
	}
	require(den > 0, "zdex: thin window")
	return num / den
}

func SampleCount(poolID string) int {
	if v := rings.Get(poolID); v != nil {
		return len(v.(*Ring).Items)
	}
	return 0
}

func LastSpot(poolID string) int64 {
	r := getRing(poolID)
	n := len(r.Items)
	if n == 0 {
		return 0
	}
	return r.Items[n-1].Px
}

func add64(a, b int64) (int64, bool) {
	s := a + b
	if (b > 0 && s < a) || (b < 0 && s > a) {
		return 0, false
	}
	return s, true
}

func mul(a, b int64) (int64, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	p := a * b
	if a != 0 && p/a != b {
		return 0, false
	}
	return p, true
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}
