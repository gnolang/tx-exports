package heirloom

func recordRelease(w *Will) {
	state.releasedCount++
	state.recent.Append(w.ID)
}

func recentlyReleased() []*Will {
	ids := state.recent.Entries()
	ws := make([]*Will, len(ids))
	for i, id := range ids {
		ws[len(ids)-1-i] = getWill(id.(int))
	}
	return ws
}

func totals() (active int, gnotHeld int64, released int) {
	return activeCount(), state.totalGNOT, state.releasedCount
}
