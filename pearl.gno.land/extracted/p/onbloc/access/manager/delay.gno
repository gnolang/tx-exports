package manager

// Delay is a value that changes only after a setback, mirroring
// OpenZeppelin's packed `Delay` type and Union's Delay struct.
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/utils/types/Time.sol#L61
// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/lib/access-manager-types/src/time.rs#L16-L20
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
// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/lib/access-manager-types/src/time.rs#L89-L103
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
// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/lib/access-manager-types/src/time.rs#L119-L131
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
