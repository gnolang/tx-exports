package arena

import "strings"

// The JSON documents are built by hand. That is safe because every string
// that reaches them was validated against a JSON-safe charset when it was
// written: ids are hex, modes and nonces [a-z0-9-], tickets hex, addresses
// bech32. The one string that is not under the realm's control, an address
// typed into a query, goes through quote.
//
// Ordering is deterministic everywhere: arenas follow their id (the tree
// iterates in key order), a lobby and a round the order of entry, results
// are newest first and earnings best first.

// ArenasJSON returns every arena someone paid into and whose game is not
// over, as a JSON array sorted by id:
//
//	[
//	  { "id": "3f2a...", "mode": "deathmatch", "stake": 10000000,
//	    "minSeats": 2, "maxSeats": 8, "lives": 3, "seconds": 900, "killTarget": 5,
//	    "creator": "g1...", "created": 1790950000, "nonce": "k3x9",
//	    "lobby": [ { "address": "g1...", "ticket": "9f86d0...00a08" } ],
//	    "round": { "startedAt": 1790950300, "players": [ "g1...", "g1..." ] } }
//	]
//
// The output has no whitespace. "round" is null until the game starts.
// The fields from "mode" to "nonce" are the arena's spec: the game server
// rebuilds the spec string, and so the id, from them.
func ArenasJSON() string {
	var b strings.Builder
	b.WriteByte('[')
	first := true
	arenas.Iterate("", "", func(id string, v any) bool {
		if !first {
			b.WriteByte(',')
		}
		first = false
		writeArena(&b, id, v.(*arena))
		return false
	})
	b.WriteByte(']')
	return b.String()
}

// ArenaJSON returns one arena in the shape of ArenasJSON, or null.
func ArenaJSON(id string) string {
	a := getArena(id)
	if a == nil {
		return "null"
	}
	var b strings.Builder
	writeArena(&b, id, a)
	return b.String()
}

func writeArena(b *strings.Builder, id string, a *arena) {
	b.WriteString(`{"id":"` + id + `","mode":"` + a.mode + `"`)
	for _, f := range []struct {
		k string
		v int64
	}{{"stake", a.stake}, {"minSeats", a.minSeats}, {"maxSeats", a.maxSeats}, {"lives", a.lives},
		{"seconds", a.seconds}, {"killTarget", a.killTarget}} {
		b.WriteString(`,"` + f.k + `":` + itoa(f.v))
	}
	b.WriteString(`,"creator":"` + a.creator.String() + `","created":` + itoa(a.created) + `,"nonce":"` + a.nonce + `"`)
	b.WriteString(`,"lobby":[`)
	for i, p := range a.lobby {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"address":"` + p.String() + `","ticket":"` + a.tickets[i] + `"}`)
	}
	b.WriteString(`],"round":`)
	if a.round == nil {
		b.WriteString("null}")
		return
	}
	b.WriteString(`{"startedAt":` + itoa(a.round.startedAt) + `,"players":[`)
	for i, p := range a.round.players {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`"` + p.String() + `"`)
	}
	b.WriteString("]}}")
}

// ResultsJSON returns the last closed games, newest first, at most 50:
//
//	[ { "id": "3f2a...", "mode": "deathmatch", "stake": 10000000,
//	    "outcome": "settled", "players": 2, "pot": 20000000, "fee": 500000,
//	    "closedAt": 1790951000,
//	    "payouts": [ { "address": "g1...", "amount": 19500000 } ] } ]
func ResultsJSON() string {
	var b strings.Builder
	b.WriteByte('[')
	for i := len(closed) - 1; i >= 0; i-- {
		if i < len(closed)-1 {
			b.WriteByte(',')
		}
		r, _ := resultOf(closed[i])
		writeResult(&b, closed[i], r)
	}
	b.WriteByte(']')
	return b.String()
}

// ResultJSON returns the result of one closed game in the shape of
// ResultsJSON, or null when the realm does not have it (still running, or
// too old).
func ResultJSON(id string) string {
	r, ok := resultOf(id)
	if !ok {
		return "null"
	}
	var b strings.Builder
	writeResult(&b, id, r)
	return b.String()
}

func writeResult(b *strings.Builder, id string, r result) {
	b.WriteString(`{"id":"` + id + `","mode":"` + r.mode + `","stake":` + itoa(r.stake) +
		`,"outcome":"` + r.outcome + `","players":` + itoa(r.players) + `,"pot":` + itoa(r.pot) +
		`,"fee":` + itoa(r.fee) + `,"closedAt":` + itoa(r.closedAt) + `,"payouts":[`)
	for i, p := range r.payouts {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"address":"` + p.Address.String() + `","amount":` + itoa(p.Amount) + `}`)
	}
	b.WriteString("]}")
}

// EarningsJSON returns the top winners as a JSON array, best first, at most
// 10 entries:
//
//	[ { "address": "g1...", "won": 19000000, "rounds": 3 } ]
//
// The output has no whitespace. "won" adds up, round after round, what the
// player was paid above their own stake, never less than zero for a round.
// "rounds" is how many settled rounds they played. With equal winnings, the
// player who got there first stays ahead.
func EarningsJSON() string {
	var b strings.Builder
	b.WriteByte('[')
	for i, addr := range winners.addrs {
		if i > 0 {
			b.WriteByte(',')
		}
		writeTotals(&b, `"`+addr.String()+`"`, totalsOf(addr))
	}
	b.WriteByte(']')
	return b.String()
}

// PlayerJSON returns one player's totals as a JSON object:
//
//	{ "address": "g1...", "won": 19000000, "rounds": 3 }
//
// The output has no whitespace. An unknown address returns the same shape
// with zero won and zero rounds.
func PlayerJSON(addr address) string {
	var b strings.Builder
	writeTotals(&b, quote(addr.String()), totalsOf(addr))
	return b.String()
}

// writeTotals writes the totals of a player. quoted is the player's address
// as a JSON string literal, quotes included.
func writeTotals(b *strings.Builder, quoted string, t totals) {
	b.WriteString(`{"address":`)
	b.WriteString(quoted)
	b.WriteString(`,"won":`)
	b.WriteString(itoa(t.won))
	b.WriteString(`,"rounds":`)
	b.WriteString(itoa(t.rounds))
	b.WriteByte('}')
}

// quote returns s as a JSON string literal, quotes included. It is for the
// strings the realm did not validate. Quotes and backslashes are escaped and
// anything outside printable ASCII is replaced by "?", so the result is
// valid JSON whatever s holds.
func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c < 0x20 || c > 0x7e:
			b.WriteByte('?')
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
