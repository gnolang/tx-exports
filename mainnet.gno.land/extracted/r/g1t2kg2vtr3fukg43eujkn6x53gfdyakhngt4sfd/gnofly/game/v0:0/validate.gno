package game

// validAddress is the one string rule of this realm: the addresses it keys
// on. Everything else it prints is a number, a param key from its own
// registry or an address checked here.

// validAddress reports whether addr is a valid address in its canonical,
// lowercase form.
//
// Bech32 can also be written in all capitals, and address.IsValid accepts
// that. To this realm the capitals would be a second key for the same
// account: a second player record, a second line on a leaderboard, an admin
// who can never be matched to a caller. Bech32 does not allow mixing cases,
// so looking at the first character is enough.
func validAddress(addr address) bool {
	return addr.IsValid() && addr[0] == 'g'
}
