package rbac

func pageOffset(page int, count int) int {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 0 {
		panic("count must be non-negative")
	}
	return (page - 1) * count
}
