package incentives

import (
	"chain/runtime"
	"math/overflow"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

const (
	nativeDenom      = "ugnot"
	scale            = int64(1_000_000_000)
	minFundUgnot     = int64(1_000_000)
	minLiquidity     = int64(1000)
	minProgramBlocks = int64(28800)
	dexPkg           = "gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/v2"
	protoVersion     = "3"
)

var (
	admin  address
	paused bool
	gauges avl.Tree // poolID -> *Gauge
	stakes avl.Tree // poolID/owner -> *Stake
)

type Gauge struct {
	ID             string
	Acc            int64
	TotalFunded    int64
	On             bool
	EndH           int64
	RewardPerBlock int64
	Remaining      int64
	LastH          int64
}

// LastLP/LastAcc are the sidecar checkpoint. Claimable and Sync both
// use stored LastLP, not live PositionOf, so a first Sync only snapshots.
type Stake struct {
	LastLP  int64
	LastAcc int64
}

func init(cur realm) {
	admin = cur.Previous().Address()
}

func require(cond bool, msg string) {
	if !cond {
		panic(msg)
	}
}

func mustOwner(cur realm) {
	if cur.Previous().Address() != admin {
		panic("zdex: admin only")
	}
}

func height() int64 {
	return runtime.ChainHeight()
}

func add64(a, b int64) int64 {
	s, ok := overflow.Add64(a, b)
	if !ok {
		panic("zdex: add overflow")
	}
	return s
}

func sub64(a, b int64) int64 {
	s, ok := overflow.Sub64(a, b)
	if !ok {
		panic("zdex: sub overflow")
	}
	return s
}

func mul64(a, b int64) int64 {
	p, ok := overflow.Mul64(a, b)
	if !ok {
		panic("zdex: mul overflow")
	}
	return p
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}

func btoi(v bool) int64 {
	if v {
		return 1
	}
	return 0
}

func stakeKey(poolID string, owner address) string {
	return poolID + "/" + owner.String()
}

func tryGauge(poolID string) *Gauge {
	v := gauges.Get(poolID)
	if v == nil {
		return nil
	}
	return v.(*Gauge)
}

func tryStake(poolID string, owner address) *Stake {
	v := stakes.Get(stakeKey(poolID, owner))
	if v == nil {
		return nil
	}
	return v.(*Stake)
}

func getOrCreateStake(poolID string, owner address) *Stake {
	if st := tryStake(poolID, owner); st != nil {
		return st
	}
	st := &Stake{}
	stakes.Set(stakeKey(poolID, owner), st)
	return st
}

// Fund creates the gauge on=true. SetGauge may create on=false.
func ensureGauge(poolID string, onIfNew bool) *Gauge {
	if g := tryGauge(poolID); g != nil {
		return g
	}
	g := &Gauge{ID: poolID, On: onIfNew}
	gauges.Set(poolID, g)
	return g
}
