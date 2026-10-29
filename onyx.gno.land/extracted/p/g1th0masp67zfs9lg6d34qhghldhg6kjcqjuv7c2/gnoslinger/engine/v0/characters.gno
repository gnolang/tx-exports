package engine

// CharKeys are the 48 character tokens a player can pick.
var CharKeys = []string{
	"andy", "axe", "banker", "barkeep", "border_rider", "cattle_baron",
	"chief", "clerk", "driver", "dude", "eagle", "el_jefe", "fast_draw",
	"fast_eddie", "floozy", "foreman", "gambler", "guard", "gun_artist",
	"happy", "hawk", "ike", "innocente", "john_henry", "lady", "lightning",
	"ling_ho", "little_ernie", "lucky", "marshal", "mountain_man", "nco",
	"old_man", "owner", "prospector", "quiet_man", "reb", "running_boy",
	"slim", "smith", "sodbuster", "texas", "the_drifter", "the_kid",
	"u_s_scout", "veteran", "woman", "yankee",
}

// IsCharKey reports whether s names one of the character tokens.
func IsCharKey(s string) bool {
	for _, k := range CharKeys {
		if k == s {
			return true
		}
	}
	return false
}
