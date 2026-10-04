package game

import "strings"

// Render returns the state of the game as markdown, for gnoweb:
//
//	""               overview
//	"leaderboard"    the top players by kills
//	"params"         the game parameters and their bounds
//	"player/<addr>"  one player
//
// Everything printed here was validated against a narrow charset when it was
// written (see validate.gno), and the only caller-supplied value, the address
// of a player page, is printed only if it is a valid address. Nothing needs
// markdown escaping.
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case path == "leaderboard":
		return renderLeaderboard()
	case path == "params":
		return renderParams()
	case strings.HasPrefix(path, "player/"):
		return renderPlayer(address(strings.TrimPrefix(path, "player/")))
	}
	return "# gnofly\n\nPage not found. Go back to the [overview](" + link("") + ").\n"
}

// link returns the gnoweb URL of a Render path of this realm.
func link(path string) string {
	if path == "" {
		return webPath
	}
	return webPath + ":" + path
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# gnofly\n\n")
	b.WriteString("A multiplayer plane game. Fly through rings, pop balloons, shoot down the other pilots.\n")
	b.WriteString("This realm holds the rules of the game: parameters, roles and the kills that count.\n\n")

	b.WriteString("- [Leaderboard](" + link("leaderboard") + "): " + itoa(int64(len(killers.addrs))) + " ranked pilots\n")
	b.WriteString("- [Parameters](" + link("params") + "): " + itoa(int64(len(params))) + "\n\n")

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Version | " + itoa(version) + " |\n")
	b.WriteString("| Owner | " + owner.Owner().String() + " |\n")
	b.WriteString("| Treasury | " + treasury.String() + " |\n")
	b.WriteString("| Admins | " + itoa(int64(admins.Size())) + " besides the owner |\n")
	b.WriteString("| Referees | " + itoa(int64(referees.Size())) + " |\n")
	b.WriteString("| Pilots on record | " + itoa(int64(pilots.Size())) + " |\n")
	return b.String()
}

func renderLeaderboard() string {
	var b strings.Builder
	b.WriteString("# gnofly leaderboard\n\n")
	b.WriteString("## Most kills\n\n")
	b.WriteString("Kills recorded on-chain by the game servers. The table keeps its top " +
		itoa(int64(leaderboardSize())) + " pilots.\n\n")
	if len(killers.addrs) == 0 {
		b.WriteString("No kill was recorded yet.\n")
	} else {
		b.WriteString("| Rank | Pilot | Kills |\n|---|---|---|\n")
		for i, a := range killers.addrs {
			b.WriteString("| " + itoa(int64(i+1)) + " | " + pilotLink(a) + " | " + itoa(killers.scores[i]) + " |\n")
		}
	}
	b.WriteString("\n[Back to the overview](" + link("") + ")\n")
	return b.String()
}

// pilotLink returns a markdown link to the page of a player.
func pilotLink(addr address) string {
	a := addr.String()
	return "[" + a + "](" + link("player/"+a) + ")"
}

func renderParams() string {
	var b strings.Builder
	b.WriteString("# gnofly parameters\n\n")
	b.WriteString("Admins change a value with `SetParam`, within its bounds.\n\n")
	b.WriteString("| Key | Value | Min | Max | Meaning |\n|---|---|---|---|---|\n")
	for _, p := range params {
		b.WriteString("| " + p.key + " | " + itoa(p.value) + " | " + itoa(p.min) + " | " + itoa(p.max) + " | " + p.doc + " |\n")
	}
	b.WriteString("\n[Back to the overview](" + link("") + ")\n")
	return b.String()
}

func renderPlayer(addr address) string {
	// The address comes from the URL: never print it unless it is one.
	if !validAddress(addr) {
		return "# gnofly pilot\n\nThis is not a valid address. Go back to the [overview](" + link("") + ").\n"
	}
	var b strings.Builder
	b.WriteString("# gnofly pilot\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Address | " + addr.String() + " |\n")
	b.WriteString("| Kills | " + itoa(recordedKills(addr)) + " |\n")
	b.WriteString("\n[Leaderboard](" + link("leaderboard") + ") | [Overview](" + link("") + ")\n")
	return b.String()
}
