package townmath

// Mix is the splitmix64 finalizer applied to x + golden gamma. It is a pure
// deterministic hash; uint64 arithmetic wraps on overflow.
func Mix(x uint64) uint64 {
	x += 0x9E3779B97F4A7C15
	z := x
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

// Event kinds.
const (
	EventNone     = 0
	EventFestival = 1
	EventShortage = 2
	EventRival    = 3
	EventTaxDay   = 4
)

// Event is the town-wide modifier for one game day. BoostBps scales customer
// demand, GrainMulBps scales the grain price, TaxBps is a tax on a tavern's
// gold (the town realm deducts it once per tax day).
// Hours is 24 for every real event (it lasts the whole game day) and 0 for
// EventNone.
type Event struct {
	Kind                                 int
	BoostBps, GrainMulBps, TaxBps, Hours int64
}

// EventForDay derives the event for a game day from the season seed.
// Distribution: 55% none, 15% festival, 15% shortage, 8% rival, 7% tax day.
func EventForDay(seed uint64, day int64) Event {
	roll := Mix(seed+uint64(day)) % 100
	switch {
	case roll < 55:
		return Event{Kind: EventNone, BoostBps: 10000, GrainMulBps: 10000}
	case roll < 70:
		return Event{Kind: EventFestival, BoostBps: 17000, GrainMulBps: 10000, Hours: 24}
	case roll < 85:
		return Event{Kind: EventShortage, BoostBps: 10000, GrainMulBps: 18000, Hours: 24}
	case roll < 93:
		return Event{Kind: EventRival, BoostBps: 7000, GrainMulBps: 10000, Hours: 24}
	}
	return Event{Kind: EventTaxDay, BoostBps: 10000, GrainMulBps: 10000, TaxBps: 800, Hours: 24}
}
