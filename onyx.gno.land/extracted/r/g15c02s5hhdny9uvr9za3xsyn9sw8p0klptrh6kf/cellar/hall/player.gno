package hall

import (
	"chain"
	"sort"

	"gno.land/r/sys/users"
)

// profile is a player as the hall knows them.
type profile struct {
	addr   address
	handle string
	solves []Solve // claim order
	badges []string
}

func (p *profile) solved(slug string) bool {
	for _, s := range p.solves {
		if s.Slug == slug {
			return true
		}
	}
	return false
}

// score sums the player's solves; season 0 means all time.
func (p *profile) score(season int) (points, solves int, last int64) {
	for _, s := range p.solves {
		if season != 0 && s.Season != season {
			continue
		}
		points += solvePoints(s)
		solves++
		last = s.Height
	}
	return points, solves, last
}

// profileOf returns the profile of addr, creating it on first use.
func profileOf(addr address) *profile {
	if p, ok := findProfile(addr); ok {
		return p
	}
	p := &profile{addr: addr}
	players.Set(addr.String(), p)
	return p
}

func findProfile(addr address) (*profile, bool) {
	v := players.Get(addr.String())
	if v == nil {
		return nil, false
	}
	return v.(*profile), true
}

// SetHandle sets the caller's display name in the hall. Handles are
// unique; setting a new one releases the old one.
func SetHandle(cur realm, handle string) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic(ErrNotUser)
	}
	if !validHandle(handle) {
		panic(ErrBadHandle)
	}
	addr := caller.Address()
	if owner := handles.Get(handle); owner != nil && owner.(address) != addr {
		panic(ErrHandleTaken)
	}
	p := profileOf(addr)
	if p.handle != "" {
		handles.Remove(p.handle)
	}
	p.handle = handle
	handles.Set(handle, addr)
	chain.Emit("Handle", "player", addr.String(), "handle", handle)
}

func validHandle(h string) bool {
	if len(h) < 3 || len(h) > 20 || h[0] < 'a' || h[0] > 'z' {
		return false
	}
	for _, c := range h {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

// DisplayName returns the hall handle of addr, else its gno.land username,
// else a shortened address.
func DisplayName(addr address) string {
	if p, ok := findProfile(addr); ok && p.handle != "" {
		return p.handle
	}
	if u := users.ResolveAddress(addr); u != nil {
		return u.Name()
	}
	s := addr.String()
	if len(s) < 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// resolvePlayer finds an address from an address or a handle.
func resolvePlayer(who string) (address, bool) {
	if addr := address(who); addr.IsValid() {
		return addr, true
	}
	if v := handles.Get(who); v != nil {
		return v.(address), true
	}
	return "", false
}

// Standing is a row of a leaderboard.
type Standing struct {
	Player address
	Points int
	Solves int
	Last   int64 // height of the latest counted solve, for tie-breaks
}

// standings ranks every player with points; season 0 means all time.
// Ties go to whoever got there first.
func standings(season int) []Standing {
	var rows []Standing
	players.Iterate("", "", func(_ string, v any) bool {
		p := v.(*profile)
		pts, n, last := p.score(season)
		if n > 0 {
			rows = append(rows, Standing{Player: p.addr, Points: pts, Solves: n, Last: last})
		}
		return false
	})
	sort.Sort(byRank(rows))
	return rows
}

type byRank []Standing

func (r byRank) Len() int      { return len(r) }
func (r byRank) Swap(i, j int) { r[i], r[j] = r[j], r[i] }
func (r byRank) Less(i, j int) bool {
	if r[i].Points != r[j].Points {
		return r[i].Points > r[j].Points
	}
	if r[i].Last != r[j].Last {
		return r[i].Last < r[j].Last
	}
	return r[i].Player < r[j].Player
}
