package looplen

func F(xs []int) int { s := 0; for i := 0; i < len(xs); i++ { s += xs[i] }; return s }
