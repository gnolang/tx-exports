package miner

import (
	"math"
	"strconv"
	"strings"
)

// JSON serialises the state like JSON.stringify of the JS save object:
// same field names and order, empty slots as null, cards keyed by id in
// ascending order, rgb only when true. Numbers use the shortest form that
// reads back to the same float64 (as JS prints them).
func (st *State) JSON() string {
	var b strings.Builder
	b.WriteString(`{"v":`)
	b.WriteString(strconv.Itoa(Version))
	b.WriteString(`,"wallet":`)
	b.WriteString(JSNum(st.Wallet))
	b.WriteString(`,"pool":`)
	b.WriteString(JSNum(st.Pool))
	b.WriteString(`,"last":`)
	b.WriteString(strconv.FormatInt(st.Last, 10))
	b.WriteString(`,"lastClaim":`)
	b.WriteString(strconv.FormatInt(st.LastClaim, 10))
	b.WriteString(`,"seasonStart":`)
	b.WriteString(strconv.FormatInt(st.SeasonStart, 10))
	b.WriteString(`,"room":`)
	b.WriteString(strconv.Itoa(st.Room))
	b.WriteString(`,"rigs":[`)
	for i, rig := range st.Rigs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('[')
		for k, id := range rig {
			if k > 0 {
				b.WriteByte(',')
			}
			if id == 0 {
				b.WriteString("null")
			} else {
				b.WriteString(strconv.Itoa(id))
			}
		}
		b.WriteByte(']')
	}
	b.WriteString(`],"cards":{`)
	for i, id := range st.CardIDs() {
		c := st.Cards[id]
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('"')
		b.WriteString(strconv.Itoa(id))
		b.WriteString(`":{"t":`)
		b.WriteString(strconv.Itoa(c.T))
		b.WriteString(`,"oc":`)
		b.WriteString(strconv.Itoa(c.OC))
		if c.RGB {
			b.WriteString(`,"rgb":true`)
		}
		b.WriteByte('}')
	}
	b.WriteString(`},"nextId":`)
	b.WriteString(strconv.Itoa(st.NextID))
	b.WriteString(`,"watch":`)
	b.WriteString(strconv.Itoa(st.Watch))
	b.WriteString(`,"mined":`)
	b.WriteString(JSNum(st.Mined))
	b.WriteString(`,"value":`)
	b.WriteString(JSNum(st.Value))
	b.WriteString(`,"spentElec":`)
	b.WriteString(JSNum(st.SpentElec))
	b.WriteString(`,"born":`)
	b.WriteString(strconv.FormatInt(st.Born, 10))
	b.WriteString(`,"season":`)
	b.WriteString(strconv.Itoa(st.Season))
	b.WriteString(`,"history":[`)
	for i, h := range st.History {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"season":`)
		b.WriteString(strconv.Itoa(h.Season))
		b.WriteString(`,"value":`)
		b.WriteString(JSNum(h.Value))
		b.WriteString(`,"mined":`)
		b.WriteString(JSNum(h.Mined))
		b.WriteString(`,"badge":`)
		b.WriteString(jsonStrOrNull(h.Badge))
		b.WriteString(`,"room":`)
		b.WriteString(strconv.Itoa(h.Room))
		b.WriteString(`,"event":`)
		b.WriteString(jsonStrOrNull(h.Event))
		b.WriteByte('}')
	}
	b.WriteString(`],"offersBought":[`)
	for i, x := range st.OffersBought {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsonStr(x))
	}
	b.WriteString(`]}`)
	return b.String()
}

// CardIDs returns the ids of the owned cards in ascending order.
func (st *State) CardIDs() []int {
	ids := make([]int, 0, len(st.Cards))
	for id := range st.Cards {
		ids = append(ids, id)
	}
	// insertion sort: the result does not depend on map order
	for i := 1; i < len(ids); i++ {
		x := ids[i]
		j := i
		for j > 0 && ids[j-1] > x {
			ids[j] = ids[j-1]
			j--
		}
		ids[j] = x
	}
	return ids
}

// JSNum formats a float64 like JS Number#toString (as JSON.stringify does):
// shortest round-trip digits, fixed notation for 1e-6 <= |x| < 1e21,
// exponent notation otherwise; NaN and ±Inf become null.
func JSNum(x float64) string {
	if math.IsNaN(x) || math.IsInf(x, 0) {
		return "null"
	}
	if x == 0 {
		return "0"
	}
	a := math.Abs(x)
	if a >= 1e-6 && a < 1e21 {
		return strconv.FormatFloat(x, 'f', -1, 64)
	}
	s := strconv.FormatFloat(x, 'e', -1, 64)
	// Go writes e-07 / e+21; JS writes e-7 / e+21.
	i := strings.IndexByte(s, 'e')
	mant, exp := s[:i], s[i+1:]
	sign := exp[:1]
	digits := strings.TrimLeft(exp[1:], "0")
	if digits == "" {
		digits = "0"
	}
	return mant + "e" + sign + digits
}

func jsonStrOrNull(s string) string {
	if s == "" {
		return "null"
	}
	return jsonStr(s)
}

func jsonStr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c < 0x20:
			const hexd = "0123456789abcdef"
			b.WriteString(`\u00`)
			b.WriteByte(hexd[c>>4])
			b.WriteByte(hexd[c&15])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
