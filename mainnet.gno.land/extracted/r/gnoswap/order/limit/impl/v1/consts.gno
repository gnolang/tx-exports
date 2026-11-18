package impl

const (
	defaultExecutionFeeRate    int64 = 15
	defaultMinMakingAmount     int64 = 100
	defaultMinOrderDuration    int64 = 300
	defaultMaxOrderDuration    int64 = 31 * 24 * 60 * 60
	defaultMaxCleanupBatchSize int64 = 100

	maxCleanupBatchSizeLimit    int64 = 500
	maxCleanupOrderIDsCSVLength       = int(maxCleanupBatchSizeLimit)*20 + int(maxCleanupBatchSizeLimit) - 1
)
