package manager

// Delay is a value that changes only after a setback, mirroring
// OpenZeppelin's packed `Delay` type.
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/utils/types/Time.sol#L61
type Delay struct {
	effectDate  TimePoint
	valueBefore uint32
	valueAfter  uint32
}

func NewDelay(delay uint32) Delay {
	return Delay{effectDate: 0, valueBefore: 0, valueAfter: delay}
}

// Get returns the value active at timestamp.
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/utils/types/Time.sol#L86-L96
func (d Delay) Get(timestamp TimePoint) uint32 {
	if d.effectDate.After(timestamp) {
		return d.valueBefore
	}

	return d.valueAfter
}

// WithUpdate schedules newDelay to take effect at timestamp plus a setback:
// at least minSetback, or longer when newDelay decreases the active value
// by more than minSetback. Returns the updated Delay and the effect timePoint.
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/utils/types/Time.sol#L103-L112
func (d Delay) WithUpdate(timestamp TimePoint, newDelay uint32, minSetback uint32) (Delay, TimePoint) {
	value := d.Get(timestamp)

	setback := minSetback
	if value > newDelay {
		if diff := value - newDelay; diff > setback {
			setback = diff
		}
	}

	effect := NewTimePoint(timestamp.Int64() + int64(setback))

	return Delay{effectDate: effect, valueBefore: value, valueAfter: newDelay}, effect
}
