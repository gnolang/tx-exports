package game

import (
	"chain"
	"errors"
)

const (
	maxKillEntries = 32   // players per SubmitKills call
	maxKillCount   = 1000 // kills per player per call

	// maxKillsLen bounds a kills string, so that an oversized input is
	// refused before it is read. An address is 40 characters, a count 4 at
	// most, plus the two separators: 64 a player leaves room to spare.
	maxKillsLen = maxKillEntries * 64
)

var errKillsFormat = errors.New(`gnofly: kills must be 1 to 32 entries "address:count" separated by ";"`)

// SubmitKills adds kills to players' on-chain counts. Referee only.
//
// kills is 1 to 32 entries "address:count" separated by ";", for example
//
//	g1abc...:3;g1def...:1
//
// Each address must be valid and listed once, each count from 1 to 1000.
// Anything else aborts the transaction and nothing is recorded. The counts
// are added to what the players already have, and the kill leaderboard is
// updated. Kills are player actions: Version does not move.
func SubmitKills(cur realm, kills string) {
	referee := assertReferee(0, cur)
	addrs, counts, err := parseKills(kills)
	if err != nil {
		panic(err)
	}

	size := leaderboardSize()
	added := int64(0)
	for i, addr := range addrs {
		total := recordedKills(addr) + counts[i]
		pilots.Set(addr.String(), total)

		if next, changed := killers.raise(addr, total-counts[i], total, size); changed {
			killers = next
		}
		added += counts[i]
	}
	chain.Emit("KillsSubmitted",
		"referee", referee.String(),
		"players", itoa(int64(len(addrs))),
		"kills", itoa(added),
	)
}

// parseKills parses and validates a kills string in a single pass. It
// returns the players and their counts, in the order of the string.
func parseKills(s string) ([]address, []int64, error) {
	if s == "" || len(s) > maxKillsLen {
		return nil, nil, errKillsFormat
	}
	var addrs []address
	var counts []int64
	seen := make(map[address]bool) // lookups only, never iterated
	i := 0
	for {
		index := len(addrs)
		if index == maxKillEntries {
			return nil, nil, errKillsFormat
		}
		colon := indexFrom(s, i, ':')
		if colon == len(s) {
			return nil, nil, errKillsFormat
		}
		end := indexFrom(s, colon+1, ';')

		addr := address(s[i:colon])
		if !validAddress(addr) {
			return nil, nil, killsEntryError(index, "invalid address")
		}
		if seen[addr] {
			return nil, nil, killsEntryError(index, "address listed twice")
		}
		// At most 4 digits: 1000 is the highest count, and a bounded length
		// keeps the number from overflowing.
		if end-colon-1 > 4 {
			return nil, nil, killsEntryError(index, "count must be a number from 1 to 1000")
		}
		count, ok := digits(s[colon+1 : end])
		if !ok || count < 1 || count > maxKillCount {
			return nil, nil, killsEntryError(index, "count must be a number from 1 to 1000")
		}
		seen[addr] = true
		addrs = append(addrs, addr)
		counts = append(counts, count)

		if end == len(s) {
			return addrs, counts, nil
		}
		i = end + 1
		if i == len(s) {
			return nil, nil, errKillsFormat // a trailing ";"
		}
	}
}

func killsEntryError(index int, reason string) error {
	return errors.New("gnofly: kills entry " + itoa(int64(index)) + ": " + reason)
}
