package makeclamp

func F(n int) []int { if n > 100 { n = 100 }; if n < 0 { n = 0 }; return make([]int, n) }
