package mkstruct

type T struct{ A, B int }

func F(n int) []T { return make([]T, n) }
