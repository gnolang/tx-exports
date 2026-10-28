package ratelimit

type Limiter struct {
	limit       int
	windowSize  int64
	height      int64
	counts      map[string]int
	windowStart map[string]int64
}

func NewLimiter(limit int, windowSizeBlocks int64) *Limiter {
	return &Limiter{
		limit:       limit,
		windowSize:  windowSizeBlocks,
		counts:      make(map[string]int),
		windowStart: make(map[string]int64),
	}
}

func (l *Limiter) Tick(height int64) {
	l.height = height
}

func (l *Limiter) Allow(addr string) bool {
	start, ok := l.windowStart[addr]
	if !ok || l.height-start >= l.windowSize {
		l.windowStart[addr] = l.height
		l.counts[addr] = 1
		return true
	}
	if l.counts[addr] < l.limit {
		l.counts[addr]++
		return true
	}
	return false
}

func (l *Limiter) Remaining(addr string) int {
	c, ok := l.counts[addr]
	if !ok {
		return l.limit
	}
	r := l.limit - c
	if r < 0 {
		return 0
	}
	return r
}
