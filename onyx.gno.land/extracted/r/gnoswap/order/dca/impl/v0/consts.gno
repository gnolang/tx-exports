package impl

const (
	dcaBPTreeFanOut int = 16

	// maxExecutionCountLimit bounds the configurable executions per order,
	// so cancelling an order releases its execution logs within one block.
	maxExecutionCountLimit int64 = 10_000

	// Bounds of an allowed interval: one minute to one year.
	minAllowedInterval int64 = 60
	maxAllowedInterval int64 = 365 * 24 * 60 * 60

	// maxClaimBatchSizeLimit bounds the configurable ClaimGroupOrders batch.
	maxClaimBatchSizeLimit int64 = 500

	// minOrderAmountOutFloor is the least output a round credits each of
	// its orders, whatever minOrderAmountOut ExecuteGroup is given.
	minOrderAmountOutFloor int64 = 1

	defaultMinAmountPerExecution int64 = 1
	defaultMaxExecutionCount     int64 = 1_000
	defaultMaxClaimBatchSize     int64 = 50
	defaultExecutionFeeRate      int64 = 15 // basis points

	// Starting execution gap: half an interval; tune per deployment.
	defaultMinExecutionGapRate int64 = 5_000

	// defaultMaxPoolPriceDeviationRate is the starting
	// Config.MaxPoolPriceDeviationRate: 20%, in basis points of price.
	defaultMaxPoolPriceDeviationRate int64 = 2_000

	// defaultMaxPairPriceLimitAge is the starting Config.MaxPairPriceLimitAge:
	// one hour, in seconds.
	defaultMaxPairPriceLimitAge int64 = 60 * 60

	// Bounds of Config.MaxPairPriceLimitAge: one minute to seven days.
	minMaxPairPriceLimitAge int64 = 60
	maxMaxPairPriceLimitAge int64 = 7 * 24 * 60 * 60
)

// Intervals new orders may use after deployment, in seconds.
// A month is a fixed 30 days, so every round in a group has the same length.
const (
	intervalMinute int64 = 60
	intervalHour   int64 = 60 * intervalMinute
	intervalDay    int64 = 24 * intervalHour
	intervalWeek   int64 = 7 * intervalDay
	intervalMonth  int64 = 30 * intervalDay
)

// defaultAllowedIntervals returns the initial allowed intervals, ascending.
func defaultAllowedIntervals() []int64 {
	return []int64{intervalMinute, intervalHour, intervalDay, intervalWeek, intervalMonth}
}

// defaultSlotSteps returns the initial slot step of the intervals split
// into several slots: daily orders pick an hour, weekly and 30-day orders
// a day. A 30-day slot is a day of the 30-day cycle counted from the unix
// epoch, not a calendar date.
// Minute and hourly orders keep a single slot, offset 0: finer slots would
// split liquidity for little gain.
// Each slot is its own group, so the steps bound the groups per pair.
func defaultSlotSteps() map[int64]int64 {
	return map[int64]int64{
		intervalDay:   intervalHour,
		intervalWeek:  intervalDay,
		intervalMonth: intervalDay,
	}
}
