package jointv1

import "gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"

// Shared customer pool and the hourly snapshot ring.
//
// Every game hour the town has one pool of customers (townmath.
// PoolCustomersMilli for the pub count), scaled by the price factor of the
// town's weight-weighted average price against ReferencePriceCg (all pubs
// dearer: fewer customers; a pub with almost no weight barely moves it) and by the day's event, and split among pubs by weight. A pub
// settles lazily, so for each hour it missed it needs the town totals of that
// hour: the ring keeps one snapshot per hour of the last 24, written whenever
// the totals change and by every settle for its own hour (a settle that
// credits hours reads the ring with that write applied, and stores the slot
// once, after its reweigh). An hour nobody wrote uses the last known
// snapshot before it.

// maxPoolScaleClamp is the scale clamp of townmath.PoolCustomersMilli.
const maxPoolScaleClamp int64 = 100000

// ringSize is the number of hourly snapshots kept (one game day).
const ringSize = 24

// Pool parameter bounds (see docs/spikes/pool-sim.md).
const (
	MinPoolK        = 1
	MaxPoolK        = 3
	MinPoolScaleBps = 5000
	MaxPoolScaleBps = 30000
)

// snapshot is the town totals at the end of a game hour. Set tells an
// empty slot from hour 0.
type snapshot struct {
	Hour, Pubs, TotalWeight, TotalPriceWeight int64
	Set                                       bool
}

var (
	ring           [ringSize]snapshot // slot hour % ringSize
	snapshotWrites int64              // stored ring writes (skipped writes not counted)
	poolK          int   = townmath.PoolExponentK
	poolScaleBps   int64 = townmath.PoolScaleBps
)

// currentSnapshot returns the town totals now.
func currentSnapshot(hour int64) snapshot {
	return snapshot{Hour: hour, Pubs: pubCount, TotalWeight: totalWeight, TotalPriceWeight: totalPriceWeight, Set: true}
}

// writeSnapshot stores the current totals in the slot of hour. It skips the
// write when the slot already holds exactly these values for this hour (an
// unchanged write still costs gas), and never replaces a newer hour (block
// time behind the slot).
func writeSnapshot(hour int64) {
	if hour < 0 {
		return
	}
	i := hour % ringSize
	s := ring[i]
	if s.Set && s.Hour > hour {
		return
	}
	if s.Set && s.Hour == hour && s.Pubs == pubCount && s.TotalWeight == totalWeight && s.TotalPriceWeight == totalPriceWeight {
		return
	}
	ring[i] = currentSnapshot(hour)
	snapshotWrites++
}

// snapshotFor returns the snapshot written for exactly hour in rg (a copy
// of the ring), else fallback.
func snapshotFor(rg *[ringSize]snapshot, hour int64, fallback snapshot) snapshot {
	if hour < 0 {
		return fallback
	}
	s := rg[hour%ringSize]
	if s.Set && s.Hour == hour {
		return s
	}
	return fallback
}

// lastKnownSnapshot returns the latest snapshot in rg (a copy of the ring)
// at or before hour, or the current totals if there is none. 24 reads.
func lastKnownSnapshot(rg *[ringSize]snapshot, hour int64) snapshot {
	best := currentSnapshot(hour)
	found := false
	for i := 0; i < ringSize; i++ {
		s := rg[i]
		if s.Set && s.Hour <= hour && (!found || s.Hour > best.Hour) {
			best = s
			found = true
		}
	}
	return best
}

// poolCalc computes a pub's hourly pool share, caching the pool power of
// the last pub count seen (the integer roots are the costly part).
type poolCalc struct {
	pubs, powMilli int64
}

// shareMilli is a pub's share of one hour's pool in thousandths of a
// customer: townmath.PoolCustomersMilli(hod, s.Pubs, poolK, poolScaleBps)
// (computed here as HourCurve * PoolPowMilli times poolScaleBps clamped to
// 0..100000, the same formula), times the price factor of the snapshot's
// weight-weighted average price (TotalPriceWeight / TotalWeight) against
// ReferencePriceCg and the event boost, split by weight against the
// snapshot's total weight.
func (c *poolCalc) shareMilli(hod int, s snapshot, weight, boostBps int64) int64 {
	curve := townmath.HourCurve(hod)
	if curve <= 0 || s.Pubs <= 0 || s.TotalWeight <= 0 || weight <= 0 {
		return 0
	}
	if s.Pubs != c.pubs || c.powMilli == 0 {
		c.pubs = s.Pubs
		c.powMilli = townmath.PoolPowMilli(s.Pubs, poolK)
	}
	scale := poolScaleBps
	if scale < 0 {
		scale = 0
	}
	if scale > maxPoolScaleClamp {
		scale = maxPoolScaleClamp
	}
	pool := townmath.MulBps(curve*c.powMilli, scale)
	pool = townmath.MulBps(pool, townmath.PriceFactorBps(s.TotalPriceWeight/s.TotalWeight, ReferencePriceCg))
	pool = townmath.MulBps(pool, boostBps)
	return townmath.PubShareMilli(pool, weight, s.TotalWeight)
}

// PoolSnapshot returns the raw ring slot that hour maps to (hour % 24): the
// hour it holds, the pub count, total weight and total price x weight then,
// and whether it was ever written. Compare the returned hour with yours: the slot
// may hold another hour. Read-only.
func PoolSnapshot(hour int64) (slotHour, pubs, totalW, totalPriceW int64, set bool) {
	if hour < 0 {
		return 0, 0, 0, 0, false
	}
	s := ring[hour%ringSize]
	return s.Hour, s.Pubs, s.TotalWeight, s.TotalPriceWeight, s.Set
}

// PoolSharesMilli returns, for each pub count in pubs (at most 64 are
// used), the share in milli customers that settlement credits a pub of
// weight at hour of day hod, with the given total weight, total price x
// weight and event boost, under the current pool params. One cached
// calculator serves the whole list, as in a settle. Read-only.
func PoolSharesMilli(hod int, pubs []int64, totalW, totalPriceW, weight, boostBps int64) []int64 {
	n := len(pubs)
	if n > 64 {
		n = 64
	}
	out := make([]int64, n)
	var c poolCalc
	for i := 0; i < n; i++ {
		s := snapshot{Pubs: pubs[i], TotalWeight: totalW, TotalPriceWeight: totalPriceW, Set: true}
		out[i] = c.shareMilli(hod, s, weight, boostBps)
	}
	return out
}

// SnapshotWrites returns how many ring writes were stored (writes skipped
// because nothing changed are not counted). Read-only.
func SnapshotWrites() int64 {
	return snapshotWrites
}

// GetPoolParams returns the pool exponent step count k and the demand scale
// in basis points.
func GetPoolParams() (k int, scaleBps int64) {
	return poolK, poolScaleBps
}
