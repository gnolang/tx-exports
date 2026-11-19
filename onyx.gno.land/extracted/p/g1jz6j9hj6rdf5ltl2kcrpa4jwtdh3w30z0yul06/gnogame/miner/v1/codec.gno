package miner

import (
	"errors"
	"math"
)

// Compact codec of a State: one short string instead of a tree of objects,
// so a realm can keep a farm in a single string field (one stored value
// instead of an object per card, rig and history entry). Decode(Encode(st))
// gives back the same state exactly: every float64 bit for bit (also -0,
// NaN and ±Inf), every int, string, slot and card.
//
// Format (version "A"):
//
//	A <header> ; <rigs> ; <cards> ; <offers> ; <history>
//
//   - header: 13 numbers joined by ",": wallet, pool, last, lastClaim,
//     seasonStart, room, nextId, watch, mined, value, spentElec, born,
//     season (the JSON order).
//   - rigs: each rig is "/" followed by its slots as runs joined by ".":
//     "x" is one slot with card id x (0 = empty), "x+k" is x, x+1, …, x+k
//     (for x = 0: k+1 empty slots). A rig without slots is a bare "/".
//   - cards, ascending ids: each run is "/" id "." t "." oc, then "*" for
//     the RGB edition, then "+k" when the next k ids are the same card
//     (same t, oc and RGB).
//   - offers: each entry is "/" and the offer key (e.g. "12:0").
//   - history: each entry is "/" season "." value "." mined "." badge "."
//     room "." event (badge and event "" for none).
//
// Numbers are base 36 (0-9a-z) with an optional "-". A float64 that is an
// integer below 2^53 in magnitude is written as that integer; any other
// float64 is "~" followed by its IEEE-754 bits in base 36. Strings (offer
// keys, badge and event names) must not contain any of , ; / . — Encode
// panics on one that does; the game never makes such a string.
//
// A typical farm takes well under 1 KB: an 80-card data-center farm whose
// rigs each run one model is about 300 bytes.

const codecVersion = 'A'

var errCodec = errors.New("bad farm encoding")

// Encode returns the compact form of st (see the format above).
func Encode(st *State) string {
	// A byte slice and append: cheaper in gas than a strings.Builder's
	// method calls.
	b := make([]byte, 0, 256)
	b = append(b, codecVersion)
	b = encFloat(b, st.Wallet)
	b = append(b, ',')
	b = encFloat(b, st.Pool)
	b = append(b, ',')
	b = encInt(b, st.Last)
	b = append(b, ',')
	b = encInt(b, st.LastClaim)
	b = append(b, ',')
	b = encInt(b, st.SeasonStart)
	b = append(b, ',')
	b = encInt(b, int64(st.Room))
	b = append(b, ',')
	b = encInt(b, int64(st.NextID))
	b = append(b, ',')
	b = encInt(b, int64(st.Watch))
	b = append(b, ',')
	b = encFloat(b, st.Mined)
	b = append(b, ',')
	b = encFloat(b, st.Value)
	b = append(b, ',')
	b = encFloat(b, st.SpentElec)
	b = append(b, ',')
	b = encInt(b, st.Born)
	b = append(b, ',')
	b = encInt(b, int64(st.Season))

	b = append(b, ';')
	for _, rig := range st.Rigs {
		b = append(b, '/')
		n := len(rig)
		for i := 0; i < n; {
			x := rig[i]
			k := 0
			if x == 0 {
				for i+k+1 < n && rig[i+k+1] == 0 {
					k++
				}
			} else {
				for i+k+1 < n && rig[i+k+1] == x+k+1 {
					k++
				}
			}
			if i > 0 {
				b = append(b, '.')
			}
			b = encInt(b, int64(x))
			if k > 0 {
				b = append(b, '+')
				b = encInt(b, int64(k))
			}
			i += k + 1
		}
	}

	b = append(b, ';')
	ids := st.CardIDs()
	n := len(ids)
	for i := 0; i < n; {
		id := ids[i]
		c := st.Cards[id]
		k := 0
		for i+k+1 < n && ids[i+k+1] == id+k+1 {
			x := st.Cards[id+k+1]
			if x.T != c.T || x.OC != c.OC || x.RGB != c.RGB {
				break
			}
			k++
		}
		b = append(b, '/')
		b = encInt(b, int64(id))
		b = append(b, '.')
		b = encInt(b, int64(c.T))
		b = append(b, '.')
		b = encInt(b, int64(c.OC))
		if c.RGB {
			b = append(b, '*')
		}
		if k > 0 {
			b = append(b, '+')
			b = encInt(b, int64(k))
		}
		i += k + 1
	}

	b = append(b, ';')
	for _, o := range st.OffersBought {
		b = append(b, '/')
		b = encStr(b, o)
	}

	b = append(b, ';')
	for _, h := range st.History {
		b = append(b, '/')
		b = encInt(b, int64(h.Season))
		b = append(b, '.')
		b = encFloat(b, h.Value)
		b = append(b, '.')
		b = encFloat(b, h.Mined)
		b = append(b, '.')
		b = encStr(b, h.Badge)
		b = append(b, '.')
		b = encInt(b, int64(h.Room))
		b = append(b, '.')
		b = encStr(b, h.Event)
	}
	return string(b)
}

const digits36 = "0123456789abcdefghijklmnopqrstuvwxyz"

func encUint(b []byte, u uint64) []byte {
	if u < 36 {
		return append(b, digits36[u])
	}
	var buf [13]byte
	i := len(buf)
	for u > 0 {
		i--
		buf[i] = digits36[u%36]
		u /= 36
	}
	return append(b, buf[i:]...)
}

func encInt(b []byte, x int64) []byte {
	if x >= 0 {
		return encUint(b, uint64(x))
	}
	b = append(b, '-')
	if x == math.MinInt64 {
		return encUint(b, 1<<63)
	}
	return encUint(b, uint64(-x))
}

// maxExact: integers of smaller magnitude are exact in a float64 and in an
// int64 alike.
const maxExact = 9007199254740992 // 2^53

func encFloat(b []byte, x float64) []byte {
	if x > -maxExact && x < maxExact {
		i := int64(x)
		if float64(i) == x && (i != 0 || math.Float64bits(x) == 0) { // -0 takes the bits form
			return encInt(b, i)
		}
	}
	b = append(b, '~')
	return encUint(b, math.Float64bits(x))
}

func encStr(b []byte, s string) []byte {
	for i, n := 0, len(s); i < n; i++ {
		switch s[i] {
		case ',', ';', '/', '.':
			panic("miner: cannot encode " + s)
		}
	}
	return append(b, s...)
}

// Decode reads a state written by Encode. It returns an error for anything
// Encode cannot produce.
func Decode(s string) (*State, error) {
	n := len(s)
	if n == 0 || s[0] != codecVersion {
		return nil, errCodec
	}
	st := &State{Cards: map[int]*Card{}, Rigs: [][]int{}, History: []HistoryEntry{}, OffersBought: []string{}}
	// header: 13 numbers, then ';'. i < 0 marks an error from here on.
	var h [13]int64
	var hf [13]float64
	i := 1
	for k := 0; k < 13; k++ {
		switch k {
		case 0, 1, 8, 9, 10: // wallet, pool, mined, value, spentElec
			hf[k], i = decFloat(s, i)
		default:
			h[k], i = decInt(s, i)
		}
		sep := byte(',')
		if k == 12 {
			sep = ';'
		}
		if i < 0 || i >= n || s[i] != sep {
			return nil, errCodec
		}
		i++
	}
	st.Wallet, st.Pool, st.Mined, st.Value, st.SpentElec = hf[0], hf[1], hf[8], hf[9], hf[10]
	st.Last, st.LastClaim, st.SeasonStart, st.Born = h[2], h[3], h[4], h[11]
	st.Room, st.NextID, st.Watch, st.Season = int(h[5]), int(h[6]), int(h[7]), int(h[12])

	// rigs
	for i < n && s[i] == '/' {
		i++
		rig := []int{}
		for i < n && s[i] != '/' && s[i] != ';' {
			if len(rig) > 0 {
				if s[i] != '.' {
					return nil, errCodec
				}
				i++
			}
			var x, k int64
			x, i = decInt(s, i)
			if i < 0 {
				return nil, errCodec
			}
			if i < n && s[i] == '+' {
				k, i = decInt(s, i+1)
				if i < 0 || k < 1 || k > 1000 {
					return nil, errCodec
				}
			}
			for j := int64(0); j <= k; j++ {
				if x == 0 {
					rig = append(rig, 0)
				} else {
					rig = append(rig, int(x+j))
				}
			}
		}
		st.Rigs = append(st.Rigs, rig)
	}
	if i >= n || s[i] != ';' {
		return nil, errCodec
	}
	i++

	// cards
	for i < n && s[i] == '/' {
		var id, t, oc, k int64
		id, i = decInt(s, i+1)
		if i < 0 || i >= n || s[i] != '.' {
			return nil, errCodec
		}
		t, i = decInt(s, i+1)
		if i < 0 || i >= n || s[i] != '.' {
			return nil, errCodec
		}
		oc, i = decInt(s, i+1)
		if i < 0 {
			return nil, errCodec
		}
		rgb := false
		if i < n && s[i] == '*' {
			rgb = true
			i++
		}
		if i < n && s[i] == '+' {
			k, i = decInt(s, i+1)
			if i < 0 || k < 1 || k > 100000 {
				return nil, errCodec
			}
		}
		for j := int64(0); j <= k; j++ {
			st.Cards[int(id+j)] = &Card{T: int(t), OC: int(oc), RGB: rgb}
		}
	}
	if i >= n || s[i] != ';' {
		return nil, errCodec
	}
	i++

	// offers
	for i < n && s[i] == '/' {
		var o string
		o, i = decStr(s, i+1)
		st.OffersBought = append(st.OffersBought, o)
	}
	if i >= n || s[i] != ';' {
		return nil, errCodec
	}
	i++

	// history
	for i < n && s[i] == '/' {
		var e HistoryEntry
		var x int64
		x, i = decInt(s, i+1)
		e.Season = int(x)
		if i < 0 || i >= n || s[i] != '.' {
			return nil, errCodec
		}
		e.Value, i = decFloat(s, i+1)
		if i < 0 || i >= n || s[i] != '.' {
			return nil, errCodec
		}
		e.Mined, i = decFloat(s, i+1)
		if i < 0 || i >= n || s[i] != '.' {
			return nil, errCodec
		}
		e.Badge, i = decStr(s, i+1)
		if i >= n || s[i] != '.' {
			return nil, errCodec
		}
		x, i = decInt(s, i+1)
		e.Room = int(x)
		if i < 0 || i >= n || s[i] != '.' {
			return nil, errCodec
		}
		e.Event, i = decStr(s, i+1)
		st.History = append(st.History, e)
	}
	if i != n {
		return nil, errCodec
	}
	return st, nil
}

// decUint reads 1 to 13 base-36 digits at i; next index, or -1.
func decUint(s string, i int) (uint64, int) {
	var u uint64
	j, n := i, len(s) // a len call per byte costs gas
	for j < n {
		c := s[j]
		if c >= '0' && c <= '9' {
			u = u*36 + uint64(c-'0')
		} else if c >= 'a' && c <= 'z' {
			u = u*36 + uint64(c-'a'+10)
		} else {
			break
		}
		j++
	}
	if j == i || j-i > 13 {
		return 0, -1
	}
	return u, j
}

// decInt reads an optional '-' and a number at i; next index, or -1.
func decInt(s string, i int) (int64, int) {
	if i < 0 {
		return 0, -1
	}
	if i < len(s) && s[i] == '-' {
		u, j := decUint(s, i+1)
		if u == 1<<63 {
			return math.MinInt64, j
		}
		return -int64(u), j
	}
	u, j := decUint(s, i)
	return int64(u), j
}

// decFloat reads a float64 at i; next index, or -1.
func decFloat(s string, i int) (float64, int) {
	if i >= 0 && i < len(s) && s[i] == '~' {
		u, j := decUint(s, i+1)
		return math.Float64frombits(u), j
	}
	x, j := decInt(s, i)
	return float64(x), j
}

// decStr reads up to the next separator.
func decStr(s string, i int) (string, int) {
	j, n := i, len(s)
	for j < n {
		switch s[j] {
		case ',', ';', '/', '.':
			return s[i:j], j
		}
		j++
	}
	return s[i:j], j
}
