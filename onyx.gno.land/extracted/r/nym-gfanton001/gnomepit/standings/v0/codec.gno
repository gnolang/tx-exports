package standings

import "encoding/binary"

// The standings and the result log are stored as byte strings laid out here, big-endian.

const (
	addressSize = 40                // bytes in an address's text
	standingFix = 2 + 2 + 2 + 2 + 1 // a standing's bytes before its per-clan counts
	resultSize  = 1 + 2*addressSize + 1 + 1 + 1 + 4

	// resultsPerChunk is the most entries in a log chunk, one string, so a new result grows a
	// string instead of adding tree nodes.
	resultsPerChunk = 64
)

type writer struct{ b []byte }

func (w *writer) u8(x uint64)   { w.b = append(w.b, byte(x)) }
func (w *writer) text(s string) { w.b = append(w.b, s...) }

func (w *writer) u16(x uint64) {
	var t [2]byte
	binary.BigEndian.PutUint16(t[:], uint16(x))
	w.b = append(w.b, t[:]...)
}

func (w *writer) u32(x uint64) {
	var t [4]byte
	binary.BigEndian.PutUint32(t[:], uint32(x))
	w.b = append(w.b, t[:]...)
}

// addr writes a's 40 characters.
func (w *writer) addr(a address) {
	if len(a) != addressSize {
		panic("invalid address")
	}
	w.text(string(a))
}

func (w *writer) String() string { return string(w.b) }

type reader struct {
	s  string
	at int
}

func (r *reader) left() int { return len(r.s) - r.at }

func (r *reader) text(n int) string {
	if r.left() < n {
		panic("truncated record")
	}
	s := r.s[r.at : r.at+n]
	r.at += n
	return s
}

func (r *reader) u8() uint64    { return uint64(r.text(1)[0]) }
func (r *reader) u16() uint64   { return uint64(binary.BigEndian.Uint16([]byte(r.text(2)))) }
func (r *reader) u32() uint64   { return uint64(binary.BigEndian.Uint32([]byte(r.text(4)))) }
func (r *reader) addr() address { return address(r.text(addressSize)) }

// standing is a player's rated record. lastClan is the clan number of their last rated
// match; perClan[i] counts their rated matches with clan number i + 1.
type standing struct {
	rating, wins, losses, draws int
	lastClan                    int
	perClan                     []int
}

// decodeStanding reads a standing's bytes: the rating, wins, losses and draws at 2 bytes
// each, the last clan number at 1, then a 2-byte count per clan number played.
func decodeStanding(s string) *standing {
	if s == "" {
		return nil
	}
	if len(s) < standingFix || (len(s)-standingFix)%2 != 0 {
		panic("malformed standing")
	}
	r := &reader{s: s}
	st := &standing{rating: int(r.u16()), wins: int(r.u16()), losses: int(r.u16()), draws: int(r.u16()), lastClan: int(r.u8())}
	for r.left() > 0 {
		st.perClan = append(st.perClan, int(r.u16()))
	}
	return st
}

func encodeStanding(st *standing) string {
	w := &writer{}
	w.u16(uint64(st.rating))
	w.u16(uint64(st.wins))
	w.u16(uint64(st.losses))
	w.u16(uint64(st.draws))
	w.u8(uint64(st.lastClan))
	for _, n := range st.perClan {
		w.u16(uint64(n))
	}
	return w.String()
}

// ladderKey orders the ladder: highest rating first, then address order.
func ladderKey(rating int, player address) string {
	w := &writer{}
	w.u16(uint64(maxRating - rating))
	w.text(string(player))
	return w.String()
}

// resultEntry is one logged result. writer is the reporting realm's writer number, clans
// the two clan numbers, result 'a', 'b' or 'd', and time the block's Unix seconds.
type resultEntry struct {
	writer               int
	challenger, acceptor address
	clans                [2]int
	result               byte
	time                 int64
}

// resultChunkKey is the log key of the chunk that holds result seq, 1 first.
func resultChunkKey(seq int) string {
	w := &writer{}
	w.u32(uint64((seq - 1) / resultsPerChunk))
	return w.String()
}

func encodeResult(e resultEntry) string {
	w := &writer{}
	w.u8(uint64(e.writer))
	w.addr(e.challenger)
	w.addr(e.acceptor)
	w.u8(uint64(e.clans[0]))
	w.u8(uint64(e.clans[1]))
	w.u8(uint64(e.result))
	w.u32(uint64(e.time))
	return w.String()
}

func decodeResult(s string) resultEntry {
	if len(s) != resultSize {
		panic("malformed result")
	}
	r := &reader{s: s}
	return resultEntry{
		writer:     int(r.u8()),
		challenger: r.addr(),
		acceptor:   r.addr(),
		clans:      [2]int{int(r.u8()), int(r.u8())},
		result:     byte(r.u8()),
		time:       int64(r.u32()),
	}
}
