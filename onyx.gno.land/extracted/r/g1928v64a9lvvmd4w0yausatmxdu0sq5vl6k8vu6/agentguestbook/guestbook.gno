// Agent Guestbook — a daily check-in and guestbook realm for gno.land.
//
// A port of the Agent Guestbook concept (first deployed on BNB Smart Chain
// for the Binance Agent ID Hackathon) to Gno: any gno.land account can check
// in once per UTC day, build a consecutive-day streak, and leave a short
// public message in the guestbook. There is no owner and no admin: nobody
// can edit or delete another account's check-ins, and the realm holds no
// funds and issues no token.
package agentguestbook

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

// RealmPath is the path this realm is deployed at; used in Render output.
const RealmPath = "gno.land/r/g1928v64a9lvvmd4w0yausatmxdu0sq5vl6k8vu6/agentguestbook"

// MaxMessageLength is the maximum guestbook message length, in bytes.
const MaxMessageLength = 280

// recentLimit caps how many recent check-ins are kept for the Render page.
const recentLimit = 10

// AgentStats holds one account's check-in statistics and guestbook entry.
type AgentStats struct {
	LastCheckInDay int64 // UTC day number (unix seconds / 86400) of the last counted check-in; 0 = never
	CurrentStreak  int64 // consecutive-day streak ending at LastCheckInDay
	BestStreak     int64 // longest streak ever reached
	TotalCheckIns  int64 // total counted check-ins by this account
	Message        string // latest guestbook message
}

var (
	agents        = avl.NewTree() // address string -> *AgentStats
	totalCheckIns int64
	uniqueAgents  int64
	recent        []string // most recent checking-in addresses, newest first
)

// currentDay returns today's UTC day number from the chain clock.
func currentDay() int64 {
	return time.Now().Unix() / 86400
}

// nextStreak computes the streak after a counted check-in today, given the
// day of the previous counted check-in and the streak that ended then.
func nextStreak(lastDay, today, current int64) int64 {
	if lastDay == today-1 {
		return current + 1
	}
	return 1
}

// validateMessage enforces the guestbook message size limit.
func validateMessage(message string) {
	if len(message) > MaxMessageLength {
		panic("guestbook: message too long (max 280 bytes)")
	}
}

// CheckIn counts today's check-in for the caller and stores the guestbook
// message. A repeat call on the same UTC day only updates the message; a
// day is never counted twice. Panics if the message exceeds 280 bytes.
func CheckIn(cur realm, message string) string {
	validateMessage(message)

	addr := cur.Previous().Address()
	key := addr.String()
	today := currentDay()

	stats, exists := getStats(key)
	if exists && stats.LastCheckInDay == today {
		// Same-day repeat: guestbook update only, no double counting.
		stats.Message = message
		chain.Emit("MessageUpdated", "agent", key, "day", strconv.FormatInt(today, 10))
		return "Already checked in today — guestbook message updated."
	}

	if !exists {
		stats = &AgentStats{}
		uniqueAgents++
	}

	stats.CurrentStreak = nextStreak(stats.LastCheckInDay, today, stats.CurrentStreak)
	if stats.CurrentStreak > stats.BestStreak {
		stats.BestStreak = stats.CurrentStreak
	}
	stats.LastCheckInDay = today
	stats.TotalCheckIns++
	stats.Message = message
	agents.Set(key, stats)

	totalCheckIns++
	pushRecent(key)

	chain.Emit("CheckedIn",
		"agent", key,
		"day", strconv.FormatInt(today, 10),
		"streak", strconv.FormatInt(stats.CurrentStreak, 10),
	)
	return "Checked in. Streak: " + strconv.FormatInt(stats.CurrentStreak, 10) +
		" day(s), total check-ins: " + strconv.FormatInt(stats.TotalCheckIns, 10) + "."
}

// GetAgent returns a human-readable summary of one account's guestbook
// record, or a note that the account has never checked in.
func GetAgent(addr address) string {
	stats, exists := getStats(addr.String())
	if !exists {
		return addr.String() + " has not checked in yet."
	}
	return addr.String() +
		" — streak " + strconv.FormatInt(stats.CurrentStreak, 10) +
		" (best " + strconv.FormatInt(stats.BestStreak, 10) + ")" +
		", total check-ins " + strconv.FormatInt(stats.TotalCheckIns, 10) +
		", last message: " + stats.Message
}

// GetStats returns the realm-wide counters.
func GetStats() string {
	return "total check-ins: " + strconv.FormatInt(totalCheckIns, 10) +
		", unique agents: " + strconv.FormatInt(uniqueAgents, 10)
}

func getStats(key string) (*AgentStats, bool) {
	v := agents.Get(key)
	if v == nil {
		return nil, false
	}
	return v.(*AgentStats), true
}

func pushRecent(key string) {
	// Remove an earlier occurrence so the list holds distinct addresses.
	for i, k := range recent {
		if k == key {
			recent = append(recent[:i], recent[i+1:]...)
			break
		}
	}
	recent = append([]string{key}, recent...)
	if len(recent) > recentLimit {
		recent = recent[:recentLimit]
	}
}

// sanitizeInline neutralizes markdown-significant characters in
// user-supplied text before it is written into Render output.
func sanitizeInline(s string) string {
	r := strings.NewReplacer(
		"\n", " ",
		"\r", " ",
		"`", "'",
		"<", "(",
		">", ")",
		"[", "(",
		"]", ")",
		"#", "",
		"*", "",
		"_", "",
		"|", "/",
	)
	return r.Replace(s)
}

// Render is the realm's gnoweb page: live counters, the latest guestbook
// entries, and how to check in.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Agent Guestbook\n\n")
	b.WriteString("A daily check-in and guestbook on gno.land. Check in once per UTC day, ")
	b.WriteString("keep your streak alive, and leave a message for the next visitor.\n\n")
	b.WriteString("**Total check-ins:** " + strconv.FormatInt(totalCheckIns, 10) +
		" · **Unique agents:** " + strconv.FormatInt(uniqueAgents, 10) + "\n\n")

	b.WriteString("## Latest entries\n\n")
	if len(recent) == 0 {
		b.WriteString("No check-ins yet — be the first.\n\n")
	}
	for _, key := range recent {
		stats, ok := getStats(key)
		if !ok {
			continue
		}
		b.WriteString("- **" + key + "** — streak " +
			strconv.FormatInt(stats.CurrentStreak, 10) +
			", " + strconv.FormatInt(stats.TotalCheckIns, 10) + " check-in(s)")
		if stats.Message != "" {
			b.WriteString(": “" + sanitizeInline(stats.Message) + "”")
		}
		b.WriteString("\n")
	}

	b.WriteString("\n## Check in\n\n")
	b.WriteString("From your own gno.land account, call the realm's `CheckIn` function with your message (max 280 bytes):\n\n")
	b.WriteString("```\ngnokey maketx call \\\n")
	b.WriteString("  -pkgpath \"" + RealmPath + "\" \\\n")
	b.WriteString("  -func \"CheckIn\" \\\n")
	b.WriteString("  -args \"your guestbook message\" \\\n")
	b.WriteString("  -gas-fee 1000000ugnot -gas-wanted 2000000 \\\n")
	b.WriteString("  -broadcast -chainid onyx-1 \\\n")
	b.WriteString("  -remote \"https://rpc.onyx.testnets.gno.land:443\" \\\n")
	b.WriteString("  <your-key-name>\n```\n\n")
	b.WriteString("No owner, no admin, no funds held, no token — an activity record only.\n")
	return b.String()
}
