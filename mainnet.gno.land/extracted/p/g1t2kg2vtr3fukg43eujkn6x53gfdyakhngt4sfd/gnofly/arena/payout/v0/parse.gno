package payout

// Both parsers read their input in a single pass, byte by byte, and bound it
// before they read it. On chain every interpreted operation is paid for, and
// an oversized string must cost its sender nothing but a refusal.
//
// They only accept an address in its canonical form, see validAddress.

const (
	// addressLen is the length of a gno address: "g1" and 38 characters.
	addressLen = 40
	// maxPlayersLen bounds a players string: MaxPlayers addresses, each
	// followed by a separator.
	maxPlayersLen = MaxPlayers * (addressLen + 1)
	// maxDeathsLen bounds a deaths string: MaxDeaths entries
	// of two addresses, each followed by a separator.
	maxDeathsLen = MaxDeaths * 2 * (addressLen + 1)
)

// ParsePlayers parses a players string: comma-separated addresses, for
// example
//
//	g1aaa...,g1bbb...,g1ccc...
//
// It returns 1 to MaxPlayers addresses in the order of the string, each one
// valid and listed once. Whitespace, empty entries and a trailing separator
// are refused. Whether there are enough players for a round is decided by
// Rule.Settle, and by the realm that starts the round.
func ParsePlayers(s string) ([]address, error) {
	if s == "" {
		return nil, ErrNoPlayers
	}
	if len(s) > maxPlayersLen {
		return nil, ErrTooManyPlayers
	}
	var players []address
	i := 0
	for {
		if len(players) == MaxPlayers {
			return nil, ErrTooManyPlayers
		}
		end := indexFrom(s, i, ',')
		addr := address(s[i:end])
		if !validAddress(addr) {
			return nil, ErrPlayersFormat
		}
		if indexOf(players, addr) >= 0 {
			return nil, ErrDuplicatePlayer
		}
		players = append(players, addr)
		if end == len(s) {
			return players, nil
		}
		i = end + 1
		if i == len(s) {
			return nil, ErrPlayersFormat // a trailing ","
		}
	}
}

// ParseDeaths parses a deaths string: "victim:killer" entries
// separated by ";", in the order they happened, "victim:" when nobody shot
// the victim down, for example
//
//	g1bbb...:g1aaa...;g1ccc...:
//
// The empty string means nobody died and gives an empty list. At
// most MaxDeaths entries are accepted, and every address must be valid.
// Whitespace, empty entries and a trailing separator are refused.
//
// It only checks the syntax. Whether the victims and the killers are players
// of the round, and how often they died, is decided by Rule.Settle.
func ParseDeaths(s string) ([]Death, error) {
	if s == "" {
		return nil, nil
	}
	if len(s) > maxDeathsLen {
		return nil, ErrTooManyDeaths
	}
	var out []Death
	i := 0
	for {
		if len(out) == MaxDeaths {
			return nil, ErrTooManyDeaths
		}
		colon := indexFrom(s, i, ':')
		if colon == len(s) {
			return nil, ErrDeathsFormat
		}
		end := indexFrom(s, colon+1, ';')

		victim := address(s[i:colon])
		if !validAddress(victim) {
			return nil, ErrDeathsFormat
		}
		killer := address(s[colon+1 : end])
		if killer != "" && !validAddress(killer) {
			return nil, ErrDeathsFormat
		}
		out = append(out, Death{Victim: victim, Killer: killer})
		if end == len(s) {
			return out, nil
		}
		i = end + 1
		if i == len(s) {
			return nil, ErrDeathsFormat // a trailing ";"
		}
	}
}

// validAddress reports whether addr is a valid address in its canonical,
// lowercase form.
//
// Bech32 can also be written in all capitals, and address.IsValid accepts
// that. To a realm the capitals would be a second name for the same account,
// one that matches no player of a round. Bech32 does not allow mixing cases,
// so looking at the first character is enough. The length is checked first:
// it is free, and it keeps an overlong string away from the decoder.
func validAddress(addr address) bool {
	return len(addr) == addressLen && addr[0] == 'g' && addr.IsValid()
}

// indexFrom returns the index of the first c in s at or after i, or len(s)
// when there is none.
func indexFrom(s string, i int, c byte) int {
	for i < len(s) && s[i] != c {
		i++
	}
	return i
}
