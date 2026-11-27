package arena

import (
	"strconv"
	"strings"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/game"
)

// Matches are stored as one compact string each, not as Go objects. Every
// stored object carries its own id, hash and type information, so a Match
// struct with an embedded Game used to cost several KB. A string costs little
// more than its bytes. On top of that, bucketSize records share one tree node:
// storage is paid on the bytes a transaction adds, so a new match mostly pays
// for its own record and only every bucketSize-th match pays for a new node.
// A Match is decoded when a transaction or page needs it and encoded again
// when it changes.

const (
	bucketSize = 16
	recSep     = "\x1e" // record separator inside a bucket
	sep        = "\x1f" // field separator; never appears in names or reasons
	byteOffset = 40     // coins (0-80) and moves (0-6) are shifted into printable bytes
	codecV2    = "2"
)

func shift(raw string) string {
	b := []byte(raw)
	for i := range b {
		b[i] += byteOffset
	}
	return string(b)
}

func unshift(enc string) string {
	b := []byte(enc)
	for i := range b {
		b[i] -= byteOffset
	}
	return string(b)
}

func itoa(n int) string  { return strconv.Itoa(n) }
func i64(n int64) string { return strconv.FormatInt(n, 10) }
func flag(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func (m *Match) encode() string {
	g := &m.Game
	return strings.Join([]string{
		codecV2,
		m.BotA, m.BotB, itoa(int(m.Status)),
		itoa(g.Seed), itoa(g.Turn), itoa(g.CellA), itoa(g.CellB), itoa(g.GoldA), itoa(g.GoldB),
		shift(g.Coins), shift(g.Moves),
		m.Challenger.String(), i64(m.Created), flag(m.Rated),
		itoa(m.Waiting), itoa(int(m.Held)), i64(m.Deadline),
		itoa(m.Winner), flag(m.Forfeit), m.Reason, itoa(m.Delta), i64(m.Settled),
		itoa(m.Season), itoa(m.Tournament),
	}, sep)
}

func decode(id int, s string) *Match {
	f := strings.Split(s, sep)
	if len(f) != 25 || f[0] != codecV2 {
		panic("corrupt match record " + itoa(id))
	}
	n := func(i int) int {
		v, err := strconv.Atoi(f[i])
		if err != nil {
			panic("corrupt match record " + itoa(id))
		}
		return v
	}
	n64 := func(i int) int64 { return int64(n(i)) }
	return &Match{
		ID:     id,
		BotA:   f[1],
		BotB:   f[2],
		Status: Status(n(3)),
		Game: game.Game{
			Seed: n(4), Turn: n(5), CellA: n(6), CellB: n(7), GoldA: n(8), GoldB: n(9),
			Coins: unshift(f[10]), Moves: unshift(f[11]),
		},
		Challenger: address(f[12]),
		Created:    n64(13),
		Rated:      f[14] == "1",
		Waiting:    n(15),
		Held:       bot.Action(n(16)),
		Deadline:   n64(17),
		Winner:     n(18),
		Forfeit:    f[19] == "1",
		Reason:     f[20],
		Delta:      n(21),
		Settled:    n64(22),
		Season:     n(23),
		Tournament: n(24),
	}
}

func bucketKey(id int) string { return key((id - 1) / bucketSize) }

func bucket(id int) []string {
	v := matches.Get(bucketKey(id))
	if v == nil {
		return nil
	}
	return strings.Split(v.(string), recSep)
}

// record returns the stored string for match id.
func record(id int) (string, bool) {
	if id < 1 || id > lastID {
		return "", false
	}
	recs := bucket(id)
	i := (id - 1) % bucketSize
	if i >= len(recs) {
		return "", false
	}
	return recs[i], true
}

// save writes the match back into its bucket.
func (m *Match) save() {
	recs := bucket(m.ID)
	i := (m.ID - 1) % bucketSize
	switch {
	case i == len(recs):
		recs = append(recs, m.encode())
	case i < len(recs):
		recs[i] = m.encode()
	default:
		panic("match records out of order")
	}
	matches.Set(bucketKey(m.ID), strings.Join(recs, recSep))
	if m.Status == Finished && m.Tournament != 0 {
		mustTournament(m.Tournament).checkDone()
	}
}

// eachRecent calls fn on matches from newest to oldest, looking at no more
// than maxScan of them, until fn returns true.
func eachRecent(maxScan int, fn func(m *Match) bool) {
	var recs []string
	cached := -1
	for id := lastID; id >= 1 && id > lastID-maxScan; id-- {
		if b := (id - 1) / bucketSize; b != cached {
			recs, cached = bucket(id), b
		}
		if fn(decode(id, recs[(id-1)%bucketSize])) {
			return
		}
	}
}
