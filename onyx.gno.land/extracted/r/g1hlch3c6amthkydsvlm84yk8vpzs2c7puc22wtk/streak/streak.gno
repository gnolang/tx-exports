// Realm streak is an on-chain habit streak tracker.
//
// Anyone can call CheckIn once per day. Checking in on consecutive
// days grows your current streak; missing a day restarts the current
// streak at 1, but your best (longest) streak and your lifetime
// check-in count are kept forever. Render shows a public leaderboard
// and per-user pages, so the whole game is readable on gnoweb with no
// frontend at all.
//
// All of the arithmetic lives in the pure package
// gno.land/p/g1hlch3c6amthkydsvlm84yk8vpzs2c7puc22wtk/streakcalc; this realm is only storage, caller
// authentication, the block clock, and rendering.
package streak

import (
	"strconv"
	"time"

	"gno.land/p/g1hlch3c6amthkydsvlm84yk8vpzs2c7puc22wtk/streakcalc"
)

// records holds one streakcalc.State per user address. It is the
// realm's entire persistent state, together with members.
var records = map[address]streakcalc.State{}

// members lists every address that has ever checked in, in
// first-check-in order. Render copies and sorts it, so leaderboard
// ordering never mutates storage.
var members []address

// CheckIn records today's check-in for the caller and returns a
// human-readable summary. It must be called directly by the user:
// a check-in forwarded through another realm would credit that
// realm's address, so cross-realm calls are rejected.
func CheckIn(cur realm) string {
	if !cur.Previous().IsUserCall() {
		panic("streak: CheckIn must be called directly by a user")
	}
	caller := cur.Previous().Address()
	day := streakcalc.DayOf(time.Now().Unix())
	before, had := records[caller]
	after := checkIn(caller, day)
	if had && after.Total == before.Total {
		return "Already checked in today. Current streak: " +
			strconv.FormatInt(after.Current, 10) + " day(s), best " +
			strconv.FormatInt(after.Longest, 10) + "."
	}
	return "Checked in. Current streak: " +
		strconv.FormatInt(after.Current, 10) + " day(s), best " +
		strconv.FormatInt(after.Longest, 10) + ", total check-in days " +
		strconv.FormatInt(after.Total, 10) + "."
}

// checkIn folds one check-in for addr on the given day index into the
// stored record and returns the updated state. It is split out of
// CheckIn so tests can drive arbitrary day sequences without a chain.
func checkIn(addr address, day int64) streakcalc.State {
	prev, ok := records[addr]
	if !ok {
		members = append(members, addr)
	}
	next := streakcalc.Apply(prev, day)
	records[addr] = next
	return next
}

// GetStats returns the stored counters for addr. found is false when
// the address has never checked in.
func GetStats(addr address) (current, longest, total, lastDay int64, found bool) {
	st, ok := records[addr]
	return st.Current, st.Longest, st.Total, st.LastDay, ok
}

// TotalUsers returns how many addresses have ever checked in.
func TotalUsers() int {
	return len(members)
}

// entry is one leaderboard row: an address and its record.
type entry struct {
	addr  address
	state streakcalc.State
}

// better reports whether entry a ranks above entry b: longest streak
// first, then current streak, then total check-in days, then the
// address itself so the order is fully deterministic.
func better(a, b entry) bool {
	if a.state.Longest != b.state.Longest {
		return a.state.Longest > b.state.Longest
	}
	if a.state.Current != b.state.Current {
		return a.state.Current > b.state.Current
	}
	if a.state.Total != b.state.Total {
		return a.state.Total > b.state.Total
	}
	return a.addr.String() < b.addr.String()
}

// top returns at most n leaderboard entries, best first.
func top(n int) []entry {
	entries := make([]entry, 0, len(members))
	for _, addr := range members {
		entries = append(entries, entry{addr: addr, state: records[addr]})
	}
	// Selection sort: only the first n positions need to be final.
	if len(entries) < n {
		n = len(entries)
	}
	for i := 0; i < n; i++ {
		best := i
		for j := i + 1; j < len(entries); j++ {
			if better(entries[j], entries[best]) {
				best = j
			}
		}
		entries[i], entries[best] = entries[best], entries[i]
	}
	return entries[:n]
}

// Render renders the realm's public pages as markdown:
//
//	""            -> the leaderboard (top 10)
//	"<address>"   -> that user's streak page
//
// Any other path gets an explanation. Only bech32 addresses and
// numbers are ever rendered, never free-form input.
func Render(path string) string {
	if path == "" {
		return renderLeaderboard()
	}
	addr := address(path)
	if _, ok := records[addr]; ok {
		return renderUser(addr)
	}
	return "# Streak\n\nNo check-ins yet for `" + path + "`.\n\n" +
		"Check in with `CheckIn` to start a streak, or open the " +
		"leaderboard at the realm's root path."
}

func renderLeaderboard() string {
	out := "# Streak — daily check-in leaderboard\n\n"
	out += "Check in once a day to grow your streak. Miss a day and " +
		"the current streak restarts at 1 — your best streak is kept forever.\n\n"
	if len(members) == 0 {
		return out + "Nobody has checked in yet. Be the first.\n"
	}
	out += "| # | User | Best streak | Current streak | Check-in days |\n"
	out += "|---|------|-------------|----------------|---------------|\n"
	for i, e := range top(10) {
		out += "| " + strconv.Itoa(i+1) +
			" | " + e.addr.String() +
			" | " + strconv.FormatInt(e.state.Longest, 10) +
			" | " + strconv.FormatInt(e.state.Current, 10) +
			" | " + strconv.FormatInt(e.state.Total, 10) + " |\n"
	}
	out += "\n" + strconv.Itoa(len(members)) + " user(s) have checked in.\n"
	return out
}

func renderUser(addr address) string {
	st := records[addr]
	out := "# Streak of " + addr.String() + "\n\n"
	out += "- Current streak: **" + strconv.FormatInt(st.Current, 10) + "** day(s)\n"
	out += "- Best streak: **" + strconv.FormatInt(st.Longest, 10) + "** day(s)\n"
	out += "- Total check-in days: **" + strconv.FormatInt(st.Total, 10) + "**\n"
	out += "- Last check-in day index: " + strconv.FormatInt(st.LastDay, 10) + "\n"
	return out
}
