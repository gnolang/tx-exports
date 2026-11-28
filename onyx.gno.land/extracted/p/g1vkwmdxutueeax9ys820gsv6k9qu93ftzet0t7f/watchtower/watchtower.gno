// Package watchtower provides shared status logic for the Watchtower
// status-board realm (gno.land/r/g1vkwmdxutueeax9ys820gsv6k9qu93ftzet0t7f/watchtower).
//
// Other realms can import this package to report their own status into a
// Watchtower board, or reuse the status computation locally.
//
// NOTE (scaffold): verify import paths and stdlib surface against the
// current Gno version before deploying — see ROADMAP.md Fase 0.
package watchtower

import (
	"time"
)

// Status values for a monitored service.
const (
	StatusUnknown     = "unknown"
	StatusOperational = "operational"
	StatusDegraded    = "degraded"
	StatusDown        = "down"
	StatusMaintenance = "maintenance"
)

// Manual overrides a service owner can set. ManualNone means the status is
// derived purely from heartbeat age.
const (
	ManualNone        = ""
	ManualMaintenance = StatusMaintenance
	ManualDown        = StatusDown
)

// ComputeStatus derives a service status from its heartbeat age.
//
//   - manual override always wins (maintenance / forced down)
//   - age <= interval            -> operational
//   - age <= 3*interval          -> degraded
//   - otherwise                  -> down
//   - lastBeat == 0 (never seen) -> unknown
func ComputeStatus(lastBeatUnix int64, intervalSec int64, manual string, now time.Time) string {
	if manual == ManualMaintenance || manual == ManualDown {
		return manual
	}
	if lastBeatUnix == 0 {
		return StatusUnknown
	}
	if intervalSec <= 0 {
		intervalSec = 300 // default 5 minutes
	}
	age := now.Unix() - lastBeatUnix
	switch {
	case age <= intervalSec:
		return StatusOperational
	case age <= 3*intervalSec:
		return StatusDegraded
	default:
		return StatusDown
	}
}

// StatusMark returns a short marker used by Render() boards.
// Kept ASCII/emoji-free in the realm; the CLI adds colour for terminals.
func StatusMark(status string) string {
	switch status {
	case StatusOperational:
		return "[OK]"
	case StatusDegraded:
		return "[DEGRADED]"
	case StatusDown:
		return "[DOWN]"
	case StatusMaintenance:
		return "[MAINTENANCE]"
	default:
		return "[UNKNOWN]"
	}
}

// FormatAge renders a heartbeat age as e.g. "42s", "3m", "2h", "1d".
func FormatAge(ageSec int64) string {
	if ageSec < 0 {
		ageSec = 0
	}
	switch {
	case ageSec < 60:
		return itoa(ageSec) + "s"
	case ageSec < 3600:
		return itoa(ageSec/60) + "m"
	case ageSec < 86400:
		return itoa(ageSec/3600) + "h"
	default:
		return itoa(ageSec/86400) + "d"
	}
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
