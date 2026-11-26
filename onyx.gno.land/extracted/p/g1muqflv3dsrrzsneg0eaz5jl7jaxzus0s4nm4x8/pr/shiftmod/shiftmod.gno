package shiftmod

func F(h uint64, i int) int { return int((h >> 13) % uint64(i+1)) }
