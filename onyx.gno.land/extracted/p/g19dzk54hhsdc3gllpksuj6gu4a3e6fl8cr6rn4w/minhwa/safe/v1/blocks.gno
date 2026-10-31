package safe

// AvgBlockMs is the measured mainnet average block time (RA §1: 200k blocks
// in 708,660 s). Use it only for UI estimates and defaults; every on-chain
// rule is stated in blocks.
const AvgBlockMs = 3540

// BlocksFor converts a duration to blocks, rounding up.
func BlocksFor(seconds int64) int64 {
	if seconds <= 0 {
		return 0
	}
	return (seconds*1000 + AvgBlockMs - 1) / AvgBlockMs
}
