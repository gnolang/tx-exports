package kourt2
import (
	"time"
	runtime "chain/runtime"
	unsafe "chain/runtime/unsafe"
)
const (
	maxAdvanceStep  = int64(10 * 365 * 86400)
	maxAdvanceTotal = int64(100 * 365 * 86400)
	maxHeightStep  = 2 * periodBlocks
	maxHeightTotal = 10 * periodBlocks
	maxBase = int64(4102444800)
)
var (
	tcDeployer address
	tcArmed    bool
	tcSealed   bool
	tcSkew     int64
	tcBase     int64
	tcFloor    int64
	tcEverArmed bool
	tcPeakSkew  int64
	tcHeightSkew int64
	tcHeightPeak int64
	tcHeightBase  int64
	tcHeightFloor int64
)
func init() { tcDeployer = unsafe.OriginCaller() }
func mustDeployer(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if cur.Previous().Address() != tcDeployer {
		panic("kourtv2: only the deployer may drive the test clock")
	}
}
func EnableTestClock(cur realm) {
	mustDeployer(cur)
	if tcSealed {
		panic("kourtv2: the test clock is sealed; this realm is not a test chain")
	}
	if tcArmed {
		panic("kourtv2: the test clock is already armed")
	}
	if CourtCount() > 2 {
		panic("kourtv2: this realm already has courts; the test clock cannot be armed")
	}
	m := mustCourt(metaSlug)
	if m.nextID > 1 || m.coin.TotalSupply() > 0 {
		panic("kourtv2: this realm has been used; the test clock cannot be armed")
	}
	tcArmed = true
	tcBase = time.Now().Unix()
	if tcBase > maxBase {
		panic("kourtv2: this chain's own clock reads past 2100; check its genesis time")
	}
	tcFloor = tcBase
	tcHeightBase = runtime.ChainHeight()
	tcHeightFloor = tcHeightBase
}
func EnableTestClockAt(cur realm, base int64) {
	mustDeployer(cur)
	if base <= 0 {
		panic("kourtv2: the test clock's base must be a positive instant")
	}
	if base > maxBase {
		panic("kourtv2: the test clock's base must be an instant before 2100")
	}
	EnableTestClock(cur)
	tcBase = base
	if base > tcFloor {
		tcFloor = base
	}
}
func AdvanceTestClock(cur realm, secs int64) {
	mustDeployer(cur)
	if !tcArmed {
		panic("kourtv2: the test clock is not armed")
	}
	if secs <= 0 || secs > maxAdvanceStep {
		panic("kourtv2: the test clock moves forward, by at most ten years a step")
	}
	if tcSkew > maxAdvanceTotal-secs {
		panic("kourtv2: the test clock has advanced as far as it may")
	}
	tcSkew += secs
	if tcSkew > tcPeakSkew {
		tcPeakSkew = tcSkew
	}
	if n := tcBase + tcSkew; n > tcFloor {
		tcFloor = n
	}
}
func AdvanceTestHeight(cur realm, n int64) {
	mustDeployer(cur)
	if !tcArmed {
		panic("kourtv2: the test clock is not armed")
	}
	if n <= 0 || n > maxHeightStep {
		panic("kourtv2: the test height moves forward, by at most two emission periods a step")
	}
	if tcHeightSkew > maxHeightTotal-n {
		panic("kourtv2: the test height has advanced as far as it may")
	}
	tcHeightSkew += n
	if tcHeightSkew > tcHeightPeak {
		tcHeightPeak = tcHeightSkew
	}
	if h := tcHeightBase + tcHeightSkew; h > tcHeightFloor {
		tcHeightFloor = h
	}
}
func TestHeightSkew() int64 { return tcHeightSkew }
func TestHeightPeakSkew() int64 { return tcHeightPeak }
func SealTestClock(cur realm) {
	mustDeployer(cur)
	if !tcArmed {
		panic("kourtv2: the test clock was never armed; there is nothing to seal")
	}
	sealTestClock()
}
func sealTestClock() {
	tcSealed = true
	tcArmed = false
	tcSkew = 0
	tcBase = 0
	tcHeightSkew = 0
}
func TestClockActive() bool { return tcArmed }
func TestClockFabricated() bool { return tcEverArmed }
func TestClockSkew() int64 { return tcSkew }
func TestClockPeakSkew() int64 { return tcPeakSkew }
func tcNow() int64 {
	var n int64
	if tcArmed {
		n = tcBase + tcSkew
	} else {
		n = time.Now().Unix()
		if n < tcFloor {
			n = tcFloor
		}
	}
	if n <= 0 {
		panic("kourtv2: the clock read a non-positive instant")
	}
	return n
}
