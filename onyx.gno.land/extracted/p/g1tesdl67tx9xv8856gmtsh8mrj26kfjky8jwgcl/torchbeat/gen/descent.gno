package gen

// DescentMaxBeats is the longest log the descent realm replays for one floor.
// It bounds a reveal's gas: the costliest Layout+Parse plus this many beats of
// the costliest replay stays under the realm's budget (pinned by the descent
// realm's gas filetests). Every witness is at most 120 beats, so every proven
// floor stays clearable. Clients share it to end a floor run "out of time".
const DescentMaxBeats = 240

// ChestRelic is the relic a day's descent chest holds: 1 (Featherboots) on
// even days, 2 (Ironheart) on odd days. It draws nothing from the floor PRNG,
// so it never changes a floor.
func ChestRelic(day uint32) uint8 {
	if day%2 == 0 {
		return 1
	}
	return 2
}
