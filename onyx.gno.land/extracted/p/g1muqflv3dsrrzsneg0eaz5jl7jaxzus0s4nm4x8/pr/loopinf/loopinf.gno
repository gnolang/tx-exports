package loopinf

func F(x int) int { n := 0; for { if x <= 0 { break }; x /= 2; n++ }; return n }
