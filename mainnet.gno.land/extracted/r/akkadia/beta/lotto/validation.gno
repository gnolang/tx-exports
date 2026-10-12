package lotto

func assertValidAddress(addr address) {
	if !addr.IsValid() {
		panic("invalid address")
	}
}

func assertListLimit(limit int) {
	if limit < 1 || limit > 100 {
		panic("limit must be between 1 and 100")
	}
}
