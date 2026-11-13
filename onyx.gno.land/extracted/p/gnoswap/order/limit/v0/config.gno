package limit

// Config holds governance-controlled limit-order parameters.
type Config struct {
	executionFeeRate    int64 // snapshotted into each new order, bps of gross output
	maxSlippageBps      int64 // maximum slippage accepted for new orders
	minMakingAmount     int64 // minimum input amount accepted for new orders
	minOrderDuration    int64 // shortest allowed expiresAt - createdAt, in seconds
	maxOrderDuration    int64 // longest allowed expiresAt - createdAt, in seconds
	maxCleanupBatchSize int64 // most orders one CleanupExpiredOrders call examines
}

// NewConfig returns a config with the given parameters.
// Bounds are enforced by the implementation that stores it.
func NewConfig(
	executionFeeRate int64,
	minMakingAmount int64,
	minOrderDuration int64,
	maxOrderDuration int64,
	maxCleanupBatchSize int64,
) *Config {
	return &Config{
		executionFeeRate:    executionFeeRate,
		maxSlippageBps:      DefaultMaxSlippageBps,
		minMakingAmount:     minMakingAmount,
		minOrderDuration:    minOrderDuration,
		maxOrderDuration:    maxOrderDuration,
		maxCleanupBatchSize: maxCleanupBatchSize,
	}
}

// Clone returns a copy of the config that shares no state with c.
// Callers outside the storing realm read the config through it.
func (c *Config) Clone() *Config {
	return &Config{
		executionFeeRate:    c.executionFeeRate,
		maxSlippageBps:      c.maxSlippageBps,
		minMakingAmount:     c.minMakingAmount,
		minOrderDuration:    c.minOrderDuration,
		maxOrderDuration:    c.maxOrderDuration,
		maxCleanupBatchSize: c.maxCleanupBatchSize,
	}
}

func (c *Config) ExecutionFeeRate() int64 { return c.executionFeeRate }

// SetExecutionFeeRate sets the execution fee rate in basis points.
// It returns ErrInvalidExecutionFeeRate outside [0, MaxExecutionFeeRate].
func (c *Config) SetExecutionFeeRate(executionFeeRate int64) error {
	if !isValidExecutionFeeRate(executionFeeRate) {
		return ErrInvalidExecutionFeeRate
	}

	c.executionFeeRate = executionFeeRate

	return nil
}

func (c *Config) MaxSlippageBps() int64 { return c.maxSlippageBps }

// SetMaxSlippageBps sets the maximum slippage accepted for new orders.
// It returns ErrInvalidSlippage outside [0, BpsDenominator].
func (c *Config) SetMaxSlippageBps(maxSlippageBps int64) error {
	if maxSlippageBps < 0 || maxSlippageBps > BpsDenominator {
		return ErrInvalidSlippage
	}

	c.maxSlippageBps = maxSlippageBps

	return nil
}

func (c *Config) MinMakingAmount() int64     { return c.minMakingAmount }
func (c *Config) SetMinMakingAmount(v int64) { c.minMakingAmount = v }

func (c *Config) MinOrderDuration() int64     { return c.minOrderDuration }
func (c *Config) SetMinOrderDuration(v int64) { c.minOrderDuration = v }

func (c *Config) MaxOrderDuration() int64     { return c.maxOrderDuration }
func (c *Config) SetMaxOrderDuration(v int64) { c.maxOrderDuration = v }

func (c *Config) MaxCleanupBatchSize() int64 { return c.maxCleanupBatchSize }
func (c *Config) SetMaxCleanupBatchSize(maxCleanupBatchSize int64) {
	c.maxCleanupBatchSize = maxCleanupBatchSize
}
