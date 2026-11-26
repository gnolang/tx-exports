// Package signal_room owns the published clue and Signal Room completions.
package signal_room

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1vkjcgep877a4gwchg34qfprsjpg2msjmhysh0z/relay_worlds/lobby/v1"
)

type puzzle struct {
	sequence    string
	legend      string
	switchOrder string
	answer      string
}

var (
	published   puzzle
	completions avl.Tree
)

// PublishPuzzle publishes the room's one clue as the wallet owning its namespace.
func PublishPuzzle(cur realm, sequence string, legend string, switchOrder string) {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("Connect a wallet and call the Signal Room directly.")
	}
	prefix := "gno.land/r/" + cur.Previous().Address().String() + "/"
	if !strings.HasPrefix(cur.PkgPath(), prefix) {
		panic("Only the namespace owner can publish the puzzle.")
	}
	if published.answer != "" {
		panic("The puzzle has already been published.")
	}
	published = parsePuzzle(sequence, legend, switchOrder)
}

// Solve records a correct answer from Player A for an accepted run.
func Solve(cur realm, runID int64, answer string) {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("Connect a wallet and call the Signal Room directly.")
	}
	playerA, _, accepted, exists := lobby.GetRun(runID)
	if !exists {
		panic("Run does not exist.")
	}
	if !accepted {
		panic("Player B must accept the invitation first.")
	}
	if cur.Previous().Address() != playerA {
		panic("Only Player A can solve the Signal Room.")
	}
	if published.answer == "" {
		panic("The Signal Room puzzle is unavailable.")
	}
	if strings.ToUpper(strings.TrimSpace(answer)) != published.answer {
		panic("That code is incorrect.")
	}
	if IsComplete(runID) {
		return
	}

	completions.Set(strconv.FormatInt(runID, 10), true)
}

// IsComplete reports whether a run has a recorded Signal Room solve.
func IsComplete(runID int64) bool {
	return completions.Has(strconv.FormatInt(runID, 10))
}

func parsePuzzle(sequence string, legend string, switchOrder string) puzzle {
	colors := strings.Fields(sequence)
	entries := strings.Fields(legend)
	switches := strings.Fields(switchOrder)
	if len(colors) == 0 || len(entries) == 0 || len(switches) == 0 {
		panic("Supply a color sequence, a legend, and a switch order.")
	}

	letters := make(map[string]string)
	for _, entry := range entries {
		parts := strings.SplitN(entry, "=", 2)
		if len(parts) != 2 || !isColorName(parts[0]) ||
			len(parts[1]) != 1 || parts[1][0] < 'A' || parts[1][0] > 'Z' {
			panic("Use lowercase color names and one uppercase letter per legend entry.")
		}
		if _, exists := letters[parts[0]]; exists {
			panic("Each color may appear only once in the legend.")
		}
		letters[parts[0]] = parts[1]
	}

	var answer strings.Builder
	for _, color := range colors {
		letter, exists := letters[color]
		if !exists {
			panic("Every color in the sequence needs a legend entry.")
		}
		answer.WriteString(letter)
	}

	seen := make(map[int64]bool)
	for _, position := range switches {
		number, err := strconv.ParseInt(position, 10, 64)
		if err != nil || number < 1 || number > int64(len(switches)) ||
			strconv.FormatInt(number, 10) != position || seen[number] {
			panic("The switch order must list each switch number once, starting from 1.")
		}
		seen[number] = true
	}

	return puzzle{
		sequence:    strings.Join(colors, " "),
		legend:      strings.Join(entries, " "),
		switchOrder: strings.Join(switches, " "),
		answer:      answer.String(),
	}
}

func isColorName(name string) bool {
	if name == "" {
		return false
	}
	for _, letter := range name {
		if letter < 'a' || letter > 'z' {
			return false
		}
	}
	return true
}

// Render shows the clue and the next action for a run's canonical decimal ID.
func Render(path string) string {
	page := "# Signal Room\n\n"
	base := strings.TrimPrefix(packagePath, "gno.land")
	lobbyBase := strings.TrimPrefix("gno.land/r/g1vkjcgep877a4gwchg34qfprsjpg2msjmhysh0z/relay_worlds/lobby/v1", "gno.land")
	if path == "" {
		if published.answer == "" {
			return page + "The Signal Room puzzle is unavailable.\n"
		}
		return page + "Open this room with your run ID after accepting the invitation in the " +
			"[Lobby](" + lobbyBase + "). Add a colon and the run ID to this page's URL.\n"
	}

	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil || id <= 0 || strconv.FormatInt(id, 10) != path {
		return page + "Run does not exist.\n"
	}
	playerA, playerB, accepted, exists := lobby.GetRun(id)
	if !exists {
		return page + "Run does not exist.\n"
	}

	page += "## Run " + path + "\n\nPlayer A · " + playerA.String() +
		"\n\nPlayer B · " + playerB.String() + "\n\n" +
		"[Back to the Lobby run](" + lobbyBase + ":" + path + ")\n\n"
	if !accepted {
		return page + "**Awaiting acceptance.** Player B must accept the invitation in the Lobby.\n"
	}
	if published.answer == "" {
		return page + "The Signal Room puzzle is unavailable.\n"
	}

	page += "**Color sequence** · " + published.sequence + "\n\n**Color key** · " + published.legend + "\n\n"
	if IsComplete(id) {
		return page + "**Signal decoded.** Switch order · " + published.switchOrder + "\n"
	}
	return page + "Use the color key to read the code in order. Player A submits the answer.\n\n" +
		"[Enter the code](" + base + "$help&func=Solve&runID=" + path + ")\n"
}
