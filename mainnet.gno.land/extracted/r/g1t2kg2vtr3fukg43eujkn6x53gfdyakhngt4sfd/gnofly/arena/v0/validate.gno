package arena

// The string rules below are what makes the hand-built JSON and the markdown
// of this realm safe: every string that is stored and later printed went
// through one of them, and none of them lets a quote, a backslash, a pipe, a
// bracket or a control character in. They are the rules of the game realm.

const ticketLen = 64 // a SHA-256 in hex

// validTicket reports whether s is 64 lowercase hex characters, the SHA-256
// of the secret a player's client keeps.
func validTicket(s string) bool {
	if len(s) != ticketLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// validAddress reports whether addr is a valid address in its canonical,
// lowercase form.
//
// Bech32 can also be written in all capitals, and address.IsValid accepts
// that. Bech32 does not allow mixing cases, so looking at the first character
// is enough.
func validAddress(addr address) bool {
	return addr.IsValid() && addr[0] == 'g'
}

// indexOfAddr returns the index of addr in list, -1 when it is not there.
// The lists of this realm hold at most 16 addresses.
func indexOfAddr(list []address, addr address) int {
	for i, a := range list {
		if a == addr {
			return i
		}
	}
	return -1
}
