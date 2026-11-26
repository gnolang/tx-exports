package loopdown

func F(xs []int) int { s := 0; for i := len(xs) - 1; i > 0; i-- { s += xs[i] }; return s }
