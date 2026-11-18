package limit

// BpsDenominator is 100% in basis points.
const BpsDenominator int64 = 10_000

// DefaultMaxSlippageBps is the default maximum slippage for new orders (10%).
const DefaultMaxSlippageBps int64 = 1_000

// MaxExecutionFeeRate is the largest execution fee rate, in basis points (10%).
const MaxExecutionFeeRate int64 = 1_000

// DefaultBPTreeFanout is the fanout of every limit-order B+tree.
const DefaultBPTreeFanout = 16
