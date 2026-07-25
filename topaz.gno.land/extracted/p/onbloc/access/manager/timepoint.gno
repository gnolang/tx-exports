package manager

import (
	"strconv"
	"time"
)

type TimePoint int64

func NewTimePoint(timePoint int64) TimePoint {
	return TimePoint(timePoint)
}

func CurrentTimePoint() TimePoint {
	return TimePoint(time.Now().Unix())
}

func (t TimePoint) After(other TimePoint) bool {
	return t > other
}

func (t TimePoint) Before(other TimePoint) bool {
	return t < other
}

func (t TimePoint) Equal(other TimePoint) bool {
	return t == other
}

func (t TimePoint) String() string {
	return strconv.FormatInt(int64(t), 10)
}

func (t TimePoint) Int64() int64 {
	return int64(t)
}

func (t TimePoint) IsZero() bool {
	return t == 0
}
