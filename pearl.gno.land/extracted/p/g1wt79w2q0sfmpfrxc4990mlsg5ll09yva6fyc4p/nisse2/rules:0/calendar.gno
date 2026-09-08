package rules

func MonthIndex(turns uint64) uint64 {
	return turns % 12
}

func SeasonName(turns uint64) string {
	switch MonthIndex(turns) / 3 {
	case 0:
		return "spring"
	case 1:
		return "summer"
	case 2:
		return "fall"
	default:
		return "winter"
	}
}

func SeasonMonth(turns uint64) uint64 {
	return MonthIndex(turns) % 3
}
