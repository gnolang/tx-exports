// Package profiles keeps the Gnoslinger players' records (games played,
// victory points) and their ranking apart from the game realm, so a new
// version of the game (new rules) keeps the scores. Only the game realms on
// the allowlist may write; the admin, the deployer, manages that list.
package profiles

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/sys/users"
)

// MaxPage bounds PlayersJSON and json/players/{offset}/{count}.
const MaxPage = 50

// Profile is a player's record, created the first time the address creates
// or joins a game.
type Profile struct {
	Addr address
	// GamesPlayed counts the games the player sat in once they started (a
	// second player joined); a cancelled showdown does not count.
	GamesPlayed int
	// VictoryPoints adds up the points of the player's finished games (rule
	// 15); it may be negative.
	VictoryPoints int
	CreatedAt     time.Time
}

var (
	// admin manages the allowlist of game realms; the deployer at first.
	admin    = unsafe.OriginCaller()
	profiles = avl.NewTree() // address -> *Profile
	// ranking orders the profiles, best first: rankKey -> *Profile.
	ranking = avl.NewTree()
	// games is the allowlist: the pkgpaths of the game realms that may write.
	games = avl.NewTree()
)

func init() {
	games.Set("gno.land/r/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/v0", true)
}

// --- Writes, from an allowed game realm ---

// Ensure creates addr's profile if it has none yet.
func Ensure(cur realm, addr address) {
	assertGame(cur)
	ensure(addr)
}

// AddGamePlayed counts a game that started for addr.
func AddGamePlayed(cur realm, addr address) {
	assertGame(cur)
	update(addr, func(p *Profile) { p.GamesPlayed++ })
}

// AddVictoryPoints adds an award's points (< 0 for a loss) to addr's total.
func AddVictoryPoints(cur realm, addr address, points int) {
	assertGame(cur)
	update(addr, func(p *Profile) { p.VictoryPoints += points })
}

func assertGame(cur realm) {
	if !cur.IsCurrent() {
		panic("profiles: realm value is not the caller's live cur")
	}
	if caller := cur.Previous().PkgPath(); !IsGame(caller) {
		panic("profiles: " + caller + " is not an allowed game realm")
	}
}

// --- Admin ---

// Allow lets the game realm pkgPath write the profiles (a new version of
// the game).
func Allow(cur realm, pkgPath string) {
	assertAdmin(cur)
	if !strings.HasPrefix(pkgPath, "gno.land/r/") {
		panic("profiles: " + pkgPath + " is not a realm path")
	}
	games.Set(pkgPath, true)
	chain.Emit("GameAllowed", "pkgpath", pkgPath)
}

// Disallow stops pkgPath from writing (a game version no longer scored);
// its calls panic from then on.
func Disallow(cur realm, pkgPath string) {
	assertAdmin(cur)
	if _, removed := games.Remove(pkgPath); !removed {
		panic("profiles: " + pkgPath + " is not allowed")
	}
	chain.Emit("GameDisallowed", "pkgpath", pkgPath)
}

// SetAdmin hands the allowlist over to addr.
func SetAdmin(cur realm, addr address) {
	assertAdmin(cur)
	if !addr.IsValid() {
		panic("profiles: invalid address")
	}
	admin = addr
	chain.Emit("AdminChanged", "admin", addr.String())
}

func assertAdmin(cur realm) {
	if !cur.IsCurrent() {
		panic("profiles: realm value is not the caller's live cur")
	}
	if prev := cur.Previous(); !prev.IsUser() || prev.Address() != admin {
		panic("profiles: admin only")
	}
}

// --- Reads ---

// Admin is the address managing the allowlist.
func Admin() address { return admin }

// IsGame tells whether the realm pkgPath may write the profiles.
func IsGame(pkgPath string) bool { return games.Has(pkgPath) }

// Games lists the allowed game realms.
func Games() []string {
	var l []string
	games.Iterate("", "", func(k string, _ any) bool {
		l = append(l, k)
		return false
	})
	return l
}

// Get is a copy of addr's profile, false when it has none.
func Get(addr address) (Profile, bool) {
	v := profiles.Get(addr.String())
	if v == nil {
		return Profile{}, false
	}
	return *v.(*Profile), true
}

// Rank is addr's 1-based position in the ranking, 0 without a profile.
func Rank(addr address) int {
	v := profiles.Get(addr.String())
	if v == nil {
		return 0
	}
	return rankOf(v.(*Profile))
}

// Count is the number of profiles.
func Count() int { return profiles.Size() }

// Name is addr's name in gno.land/r/sys/users (where namereg registers
// them), or "".
func Name(addr address) string {
	if addr == "" {
		return ""
	}
	if u := users.ResolveAddress(addr); u != nil {
		return u.Name()
	}
	return ""
}

// --- Ranking ---

// rankKey sorts by victory points, then games played, both descending, then
// by address.
func rankKey(p *Profile) string {
	return desc(p.VictoryPoints) + ":" + desc(p.GamesPlayed) + ":" + p.Addr.String()
}

// desc is a fixed-width key that sorts larger numbers first; victory
// points may be negative, so it is centred on 0 (|n| below 5e8).
func desc(n int) string {
	s := strconv.Itoa(500000000 - n)
	return strings.Repeat("0", 9-len(s)) + s
}

// ensure returns addr's profile, creating it on first use.
func ensure(addr address) *Profile {
	if v := profiles.Get(addr.String()); v != nil {
		return v.(*Profile)
	}
	p := &Profile{Addr: addr, CreatedAt: time.Now()}
	profiles.Set(addr.String(), p)
	ranking.Set(rankKey(p), p)
	return p
}

// update applies change to addr's profile and keeps its rank.
func update(addr address, change func(p *Profile)) {
	p := ensure(addr)
	ranking.Remove(rankKey(p))
	change(p)
	ranking.Set(rankKey(p), p)
}

// rankOf is the 1-based position of p in the ranking.
func rankOf(p *Profile) int {
	key := rankKey(p)
	rank := 0
	ranking.Iterate("", "", func(k string, _ any) bool {
		rank++
		return k == key
	})
	return rank
}
