// Package lobby owns run IDs, invitations, and player assignments.
package lobby

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

type run struct {
	playerA  address
	playerB  address
	accepted bool
}

var (
	lastRunID int64
	runs      avl.Tree
)

// CreateRun invites a second wallet and returns the new run ID.
func CreateRun(cur realm, invited address) int64 {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("Connect a wallet and call the Lobby directly.")
	}
	player := cur.Previous().Address()
	if !invited.IsValid() || invited == player {
		panic("Invite a valid wallet different from your own.")
	}

	lastRunID++
	runs.Set(strconv.FormatInt(lastRunID, 10), run{playerA: player, playerB: invited})
	return lastRunID
}

// AcceptRun activates a pending run for its invited wallet.
func AcceptRun(cur realm, runID int64) {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("Connect a wallet and call the Lobby directly.")
	}
	key := strconv.FormatInt(runID, 10)
	entry, exists := runs.Get(key).(run)
	if !exists {
		panic("Run does not exist.")
	}
	if cur.Previous().Address() != entry.playerB {
		panic("Only the invited wallet can accept this run.")
	}
	if entry.accepted {
		return
	}

	entry.accepted = true
	runs.Set(key, entry)
}

// GetRun reports a run's two players and invitation status.
func GetRun(runID int64) (playerA address, playerB address, accepted bool, exists bool) {
	entry, exists := runs.Get(strconv.FormatInt(runID, 10)).(run)
	return entry.playerA, entry.playerB, entry.accepted, exists
}

// Render shows the Lobby or one run when path is its canonical decimal ID.
func Render(path string) string {
	page := "# Relay Worlds Lobby\n\n"
	base := strings.TrimPrefix(packagePath, "gno.land")
	if path == "" {
		page += "[Invite a second player](" + base + "$help&func=CreateRun)\n\n"
		if lastRunID == 0 {
			return page + "No runs have been created.\n"
		}
		page += "## Recent runs\n\n"
		for id := lastRunID; id > 0 && lastRunID-id < 10; id-- {
			key := strconv.FormatInt(id, 10)
			page += "- [Run " + key + "](" + base + ":" + key + ")\n"
		}
		return page
	}

	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil || id <= 0 || strconv.FormatInt(id, 10) != path {
		return page + "Run does not exist.\n"
	}
	playerA, playerB, accepted, exists := GetRun(id)
	if !exists {
		return page + "Run does not exist.\n"
	}

	page += "## Run " + path + "\n\nPlayer A · " + playerA.String() +
		"\n\nPlayer B · " + playerB.String() + "\n\n"
	if accepted {
		return page + "**Invitation accepted.** Player A can solve the Signal Room for run " + path + ".\n"
	}
	return page + "**Awaiting acceptance.** Share this page with Player B.\n\n" +
		"[Accept invitation](" + base + "$help&func=AcceptRun&runID=" + path + ")\n"
}
