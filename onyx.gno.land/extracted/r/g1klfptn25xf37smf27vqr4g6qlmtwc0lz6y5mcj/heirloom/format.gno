package heirloom

import (
	"time"

	"gno.land/p/nt/ufmt/v0"
)

func formatTime(t time.Time) string {
	return t.UTC().Format("2006-01-02 15:04 UTC")
}

func formatTimeFrom(t time.Time) string {
	if m := t.Truncate(time.Minute); m.Before(t) {
		t = m.Add(time.Minute)
	}
	return formatTime(t)
}

func formatDuration(d time.Duration) string {
	days, hours, minutes := int(d/day), int(d%day/time.Hour), int(d%time.Hour/time.Minute)
	switch {
	case days > 0 && hours > 0:
		return ufmt.Sprintf("%dd %dh", days, hours)
	case days > 0:
		return ufmt.Sprintf("%dd", days)
	case hours > 0 && minutes > 0:
		return ufmt.Sprintf("%dh %dm", hours, minutes)
	case hours > 0:
		return ufmt.Sprintf("%dh", hours)
	case minutes > 0:
		return ufmt.Sprintf("%dm", minutes)
	}
	return "<1m"
}

func shortAddr(addr address) string {
	s := addr.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}
