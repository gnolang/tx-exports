package makeunexp

func F() []int { return f(5) }
func f(n int) []int { return make([]int, n) }
