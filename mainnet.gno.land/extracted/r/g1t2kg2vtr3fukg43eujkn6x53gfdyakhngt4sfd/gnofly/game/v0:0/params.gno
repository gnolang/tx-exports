package game

import "chain"

// param is one tunable number of the game, with the bounds an admin has to
// stay within.
type param struct {
	key   string
	value int64
	min   int64
	max   int64
	doc   string
}

// paramLeaderboardSize is the one param the realm itself consumes. Every
// other param is only stored here and applied by the game server.
const paramLeaderboardSize = "leaderboard_size"

// defaultParams returns the registry with its default values. The order is
// the display order, in StateJSON as well as in Render.
func defaultParams() []*param {
	return []*param{
		{"plane_speed", 70, 20, 300, "cruise speed, m/s"},
		{"boost_speed", 130, 20, 600, "speed while boosting, m/s"},
		{"boost_capacity_ms", 4000, 0, 60000, "how long a full boost tank lasts, 0 disables boost"},
		{"boost_recharge_ms", 10000, 100, 600000, "time to refill an empty tank while not boosting"},
		{"turn_rate", 80, 20, 360, "pitch and turn responsiveness, deg/s"},
		{"plane_health", 100, 1, 1000, "hit points"},
		{"fire_cooldown_ms", 160, 50, 5000, "minimum time between shots"},
		{"bullet_speed", 400, 100, 2000, "m/s"},
		{"bullet_ttl_ms", 1500, 100, 10000, "bullet lifetime"},
		{"bullet_damage", 20, 1, 1000, "hit points removed per bullet"},
		{"respawn_ms", 3000, 0, 60000, "delay before a destroyed plane respawns"},
		{"balloon_respawn_ms", 6000, 0, 600000, "delay before a popped balloon comes back"},
		{paramLeaderboardSize, 10, 1, 100, "entries a leaderboard keeps, on-chain and on the server"},
		{"max_players", 64, 1, 1000, "server capacity"},
		{"bot_max", 2, 0, 16, "bots flying with a lone pilot, 0 for no bots"},
		{"bot_off_players", 5, 1, 64, "from this many pilots there are no bots"},
		{"bot_aim_error", 8, 0, 45, "how far a bot's shot can stray from its aim, degrees"},
		{"bot_fire_interval_ms", 900, 100, 10000, "minimum time between a bot's shots"},
	}
}

// findParam returns the param registered under key, or nil. The registry is
// a dozen entries, a linear scan is cheaper than any index.
func findParam(key string) *param {
	for _, p := range params {
		if p.key == key {
			return p
		}
	}
	return nil
}

// SetParam changes a game parameter. Admin only.
//
// The key must exist and the value must be within the bounds of that key,
// see Render("params"). Lowering leaderboard_size truncates the kill
// leaderboard right away. Raising it does not bring back the lines that were
// dropped: the list fills up again as kills come in.
func SetParam(cur realm, key string, value int64) {
	assertAdmin(0, cur)
	p := findParam(key)
	if p == nil {
		panic(errUnknownParam)
	}
	if value < p.min || value > p.max {
		panic("gnofly: " + key + " must be between " + itoa(p.min) + " and " + itoa(p.max))
	}
	p.value = value
	if key == paramLeaderboardSize {
		trimRankings()
	}
	bump()
	chain.Emit("ParamSet", "key", key, "value", itoa(value))
}

// SetParamBounds changes the range SetParam accepts for a key. Owner only.
//
// The bounds are the guard rail between the owner and the admins: admins tune
// values within them, the owner decides how far tuning may go. The current
// value has to fit the new bounds, so that the registry never holds a value
// SetParam would refuse.
func SetParamBounds(cur realm, key string, min, max int64) {
	assertOwner(0, cur)
	p := findParam(key)
	if p == nil {
		panic(errUnknownParam)
	}
	if min < 0 || min > max {
		panic(errInvalidBounds)
	}
	// An empty leaderboard has no last line to compare a new total with.
	if key == paramLeaderboardSize && min < 1 {
		panic(errLeaderboardMin)
	}
	if p.value < min || p.value > max {
		panic(errValueOutOfBounds)
	}
	p.min, p.max = min, max
	bump()
	chain.Emit("ParamBoundsSet", "key", key, "min", itoa(min), "max", itoa(max))
}

// Param returns the value of a game parameter. It panics on an unknown key.
func Param(key string) int64 {
	p := findParam(key)
	if p == nil {
		panic(errUnknownParam)
	}
	return p.value
}
