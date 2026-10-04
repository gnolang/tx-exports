package game

import "strings"

// The JSON documents are built by hand. That is safe because every string
// that reaches them was validated against a JSON-safe charset when it was
// written (see validate.gno): ids, names, models, colors and bech32 addresses
// need no escaping. The one string that is not under the realm's control, an
// address typed into a query, goes through quote.
//
// Ordering is deterministic everywhere: params follow the registry and the
// leaderboard is best first.

// StateJSON returns everything the game needs from the chain, as one JSON
// object:
//
//	{
//	  "version": 12,
//	  "treasury": "g1...",
//	  "params": { "plane_speed": 70, "boost_speed": 130 }
//	}
//
// The output has no whitespace. It only changes when Version does. The skins
// are in their own realm, gnofly/nfts/skins.
func StateJSON() string {
	var b strings.Builder

	b.WriteString(`{"version":`)
	b.WriteString(itoa(version))
	b.WriteString(`,"treasury":"`)
	b.WriteString(treasury.String())

	b.WriteString(`","params":{`)
	for i, p := range params {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('"')
		b.WriteString(p.key)
		b.WriteString(`":`)
		b.WriteString(itoa(p.value))
	}

	b.WriteString(`}}`)
	return b.String()
}

// PlayerJSON returns one player as a JSON object:
//
//	{ "address": "g1...", "kills": 17 }
//
// The output has no whitespace. An unknown address has zero kills. The skins
// and planes a player owns are read from their realms (SkinsOf, PlanesOf).
func PlayerJSON(addr address) string {
	var b strings.Builder
	b.WriteString(`{"address":`)
	b.WriteString(quote(addr.String()))
	b.WriteString(`,"kills":`)
	b.WriteString(itoa(recordedKills(addr)))
	b.WriteByte('}')
	return b.String()
}

// KillLeaderboardJSON returns the top players by kills recorded on-chain as
// a JSON array, best first, at most leaderboard_size entries:
//
//	[ { "address": "g1...", "kills": 17 } ]
//
// The output has no whitespace. With equal kills, the player who got there
// first stays ahead.
func KillLeaderboardJSON() string {
	var b strings.Builder
	writeRanking(&b, killers, "kills")
	return b.String()
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
