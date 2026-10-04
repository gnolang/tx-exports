package game

// What the realm remembers about a player is their kills, recorded by the
// referees: pilots maps an address to an int64, allocated at the first kill.
// A player without a record has none. Skins and planes are tokens of their
// own realms (gnofly/nfts/skins, gnofly/nfts/planes).

// killsOf returns the kills recorded for addr.
func recordedKills(addr address) int64 {
	v := pilots.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}
