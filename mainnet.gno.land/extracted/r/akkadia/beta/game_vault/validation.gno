package game_vault

func readQueryCSVEntry(csv string, start int) (string, int, bool) {
	end := start
	for end < len(csv) && csv[end] != ',' {
		end++
	}
	return csv[start:end], end + 1, end == len(csv)
}
