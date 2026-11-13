package dca

// BasisPointDenominator is 100% in basis points, the denominator of every
// rate in basis points: executionFeeRate, minExecutionGapRate, and
// maxPoolPriceDeviationRate.
const BasisPointDenominator int64 = 10_000

// MaxExecutionFeeRate is the largest execution fee rate: 1000 basis points
// (10%).
const MaxExecutionFeeRate int64 = 1_000

// Config holds governance-controlled DCA parameters.
type Config struct {
	minAmountPerExecution int64 // minimum input per execution
	maxExecutionCount     int64 // maximum executions per order

	// allowedIntervals lists the intervals new orders may use, ascending.
	// Removing one only blocks new orders; existing groups keep running.
	allowedIntervals []int64

	// Execution guard.
	minExecutionGapRate int64 // min gap between a group's executions, bps of interval
	// slotSteps[i] is the spacing of the slot offsets
	// allowed for allowedIntervals[i]; it divides the interval.
	// A step equal to the interval allows offset 0 only.
	slotSteps []int64

	maxClaimBatchSize int64 // most orders one ClaimGroupOrders call examines

	// maxPoolPriceDeviationRate is how far, in basis points of price, a pool's
	// price may sit on the favorable side of its swap price limit and still be
	// quoted; 0 disables the check. It bounds the ticks a quote or swap walks
	// when a pool's price is far from the oracle-derived limit.
	maxPoolPriceDeviationRate int64

	// maxPairPriceLimitAge is how long, in seconds, a pair price limit stays
	// usable after it was set; a round or quote under an older limit finds
	// no eligible pool. 0 is invalid and leaves no pool eligible.
	maxPairPriceLimitAge int64

	// executionFeeRate is the share of an order's gross output,
	// in basis points, sent to the protocol fee realm.
	// Each new order snapshots it; changing it leaves existing orders as is.
	executionFeeRate int64
}

// NewConfig returns a config that allows allowedIntervals, which must be
// ascending. The slice is copied. Fees and the execution gap start disabled.
// Each interval starts with a single slot, offset 0; see SetSlotStep.
func NewConfig(minAmountPerExecution, maxExecutionCount int64, allowedIntervals []int64) *Config {
	return &Config{
		minAmountPerExecution: minAmountPerExecution,
		maxExecutionCount:     maxExecutionCount,
		allowedIntervals:      cloneInt64s(allowedIntervals),
		minExecutionGapRate:   0,
		slotSteps:             cloneInt64s(allowedIntervals),
		maxClaimBatchSize:     0,
		executionFeeRate:      0,

		maxPoolPriceDeviationRate: 0,
		maxPairPriceLimitAge:      0,
	}
}

// Clone returns a deep copy of the config.
func (c *Config) Clone() *Config {
	return &Config{
		minAmountPerExecution: c.minAmountPerExecution,
		maxExecutionCount:     c.maxExecutionCount,
		allowedIntervals:      cloneInt64s(c.allowedIntervals),
		minExecutionGapRate:   c.minExecutionGapRate,
		slotSteps:             cloneInt64s(c.slotSteps),
		maxClaimBatchSize:     c.maxClaimBatchSize,
		executionFeeRate:      c.executionFeeRate,

		maxPoolPriceDeviationRate: c.maxPoolPriceDeviationRate,
		maxPairPriceLimitAge:      c.maxPairPriceLimitAge,
	}
}

func (c *Config) MinAmountPerExecution() int64     { return c.minAmountPerExecution }
func (c *Config) SetMinAmountPerExecution(v int64) { c.minAmountPerExecution = v }

func (c *Config) MaxExecutionCount() int64     { return c.maxExecutionCount }
func (c *Config) SetMaxExecutionCount(v int64) { c.maxExecutionCount = v }

func (c *Config) MinExecutionGapRate() int64     { return c.minExecutionGapRate }
func (c *Config) SetMinExecutionGapRate(v int64) { c.minExecutionGapRate = v }

func (c *Config) MaxClaimBatchSize() int64     { return c.maxClaimBatchSize }
func (c *Config) SetMaxClaimBatchSize(v int64) { c.maxClaimBatchSize = v }

func (c *Config) MaxPoolPriceDeviationRate() int64     { return c.maxPoolPriceDeviationRate }
func (c *Config) SetMaxPoolPriceDeviationRate(v int64) { c.maxPoolPriceDeviationRate = v }

func (c *Config) MaxPairPriceLimitAge() int64     { return c.maxPairPriceLimitAge }
func (c *Config) SetMaxPairPriceLimitAge(v int64) { c.maxPairPriceLimitAge = v }

func (c *Config) ExecutionFeeRate() int64 { return c.executionFeeRate }

// SetExecutionFeeRate sets the execution fee rate in basis points.
// It returns ErrInvalidInput outside [0, MaxExecutionFeeRate].
func (c *Config) SetExecutionFeeRate(v int64) error {
	if !isValidExecutionFeeRate(v) {
		return ErrInvalidInput
	}

	c.executionFeeRate = v

	return nil
}

// AllowedIntervals returns a copy of the allowed intervals, ascending.
func (c *Config) AllowedIntervals() []int64 {
	return cloneInt64s(c.allowedIntervals)
}

// IsAllowedInterval reports whether new orders may use interval.
func (c *Config) IsAllowedInterval(interval int64) bool {
	return c.intervalIndex(interval) >= 0
}

// AddAllowedInterval allows interval, keeping the list ascending.
// The interval starts with a single slot, offset 0; see SetSlotStep.
func (c *Config) AddAllowedInterval(interval int64) error {
	if c.IsAllowedInterval(interval) {
		return ErrIntervalExists
	}

	i := 0
	for i < len(c.allowedIntervals) && c.allowedIntervals[i] < interval {
		i++
	}

	c.allowedIntervals = insertInt64(c.allowedIntervals, i, interval)
	c.slotSteps = insertInt64(c.slotSteps, i, interval)

	return nil
}

// RemoveAllowedInterval disallows interval for new orders,
// dropping its slot step with it.
func (c *Config) RemoveAllowedInterval(interval int64) error {
	i := c.intervalIndex(interval)
	if i < 0 {
		return ErrIntervalNotFound
	}

	c.allowedIntervals = removeInt64(c.allowedIntervals, i)
	c.slotSteps = removeInt64(c.slotSteps, i)

	return nil
}

// SlotStep returns the spacing of the slot offsets allowed for interval,
// or 0 if the interval is not allowed.
func (c *Config) SlotStep(interval int64) int64 {
	i := c.intervalIndex(interval)
	if i < 0 {
		return 0
	}

	return c.slotSteps[i]
}

// SetSlotStep sets the spacing of the slot offsets allowed for interval.
// It returns ErrInvalidInput if the interval is not allowed,
// or if step is not a positive divisor of the interval.
func (c *Config) SetSlotStep(interval int64, step int64) error {
	i := c.intervalIndex(interval)
	if i < 0 || step <= 0 || interval%step != 0 {
		return ErrInvalidInput
	}

	c.slotSteps[i] = step

	return nil
}

// IsAllowedSlot reports whether new orders may use slotOffset at interval:
// a multiple of the interval's slot step in [0, interval).
func (c *Config) IsAllowedSlot(interval int64, slotOffset int64) bool {
	step := c.SlotStep(interval)
	if step <= 0 {
		return false
	}

	return slotOffset >= 0 && slotOffset < interval && slotOffset%step == 0
}

func (c *Config) intervalIndex(interval int64) int {
	for i, v := range c.allowedIntervals {
		if v == interval {
			return i
		}
	}

	return -1
}

// insertInt64 returns a copy of values with v inserted at index i.
func insertInt64(values []int64, i int, v int64) []int64 {
	out := make([]int64, 0, len(values)+1)
	out = append(out, values[:i]...)
	out = append(out, v)

	return append(out, values[i:]...)
}

// removeInt64 returns a copy of values without the element at index i.
func removeInt64(values []int64, i int) []int64 {
	out := make([]int64, 0, len(values)-1)
	out = append(out, values[:i]...)

	return append(out, values[i+1:]...)
}

func cloneInt64s(values []int64) []int64 {
	out := make([]int64, len(values))
	copy(out, values)

	return out
}
