package sandiwara

import (
	"chain/runtime"
)

// copyBytes returns an independent copy of b. Every byte slice that enters
// realm state goes through here, so a caller cannot mutate stored state by
// keeping a reference to the slice they passed in.
func copyBytes(b []byte) []byte {
	if b == nil {
		return nil
	}
	out := make([]byte, len(b))
	copy(out, b)
	return out
}

// bytesEqual reports whether a and b hold the same bytes.
func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// shortAddr renders an address as its first 10 characters, which is enough to
// tell seats apart on the board without printing 40 characters per seat.
func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 10 {
		return s
	}
	return s[:10]
}

// shortHex renders a hash as its first 8 bytes in hex.
func shortHex(b []byte) string {
	const hexdigits = "0123456789abcdef"
	if len(b) > 8 {
		b = b[:8]
	}
	out := make([]byte, 0, len(b)*2)
	for _, c := range b {
		out = append(out, hexdigits[c>>4], hexdigits[c&0x0f])
	}
	return string(out)
}

// fullHex renders a hash as lowercase hex.
func fullHex(b []byte) string {
	const hexdigits = "0123456789abcdef"
	out := make([]byte, 0, len(b)*2)
	for _, c := range b {
		out = append(out, hexdigits[c>>4], hexdigits[c&0x0f])
	}
	return string(out)
}

// chainHeight is the current block height, wrapped so render code does not
// import chain/runtime directly in several places.
func chainHeight() int64 {
	return runtime.ChainHeight()
}

// seatsFilled returns how many seats are taken.
func seatsFilled(g *Game) int {
	return len(g.Seats)
}

// livingCount returns how many players are still alive.
func livingCount(g *Game) int {
	n := 0
	for i := range g.Seats {
		if g.Seats[i].Alive {
			n++
		}
	}
	return n
}

// submittedNight returns how many living players have committed a night action.
func submittedNight(g *Game) int {
	n := 0
	for i := range g.Seats {
		if g.Seats[i].Alive && len(g.Seats[i].NightCommit) != 0 {
			n++
		}
	}
	return n
}

// submittedVote returns how many living players have committed a vote.
func submittedVote(g *Game) int {
	n := 0
	for i := range g.Seats {
		if g.Seats[i].Alive && len(g.Seats[i].VoteCommit) != 0 {
			n++
		}
	}
	return n
}

// gameCount returns the number of games ever opened.
func gameCount() int {
	return len(games)
}
