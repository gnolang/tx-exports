package alloc

const BPS = int64(10_000)

// DefaultBufferBPS keeps 15% of book assets as idle WUGNOT for withdraws.
const DefaultBufferBPS int64 = 1_500

// MinDeploy is 1 GNOT (ugnot units). Smaller leftovers stay idle.
const MinDeploy int64 = 1_000_000

// TargetIdle is the WUGNOT buffer to keep un-deployed.
func TargetIdle(totalAssets, bufferBPS int64) int64 {
	if totalAssets <= 0 || bufferBPS <= 0 {
		return 0
	}
	if bufferBPS >= BPS {
		return totalAssets
	}
	return totalAssets * bufferBPS / BPS
}

// ExcessIdle is capital above the buffer that can go into LP. 0 if too small.
func ExcessIdle(idle, target, minDeploy int64) int64 {
	if idle <= target {
		return 0
	}
	x := idle - target
	if x < minDeploy {
		return 0
	}
	return x
}

// Shortfall is extra WUGNOT needed to pay a withdraw.
func Shortfall(idle, need int64) int64 {
	if need <= idle {
		return 0
	}
	return need - idle
}
