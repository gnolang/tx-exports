package arena

import (
	"chain"
	"strconv"

	"gno.land/r/g1rzgxl6njyu4c2x89gxvaa9cswrt73rz8mlp7l6/gnotif/v0"
)

// self is the arena's package path; a deploy under another path changes it.
var self string

// init declares the arena's two gnotif triggers. Each event carries the address it
// notifies in "to", so a browser opts in with its wallet's address.
func init(cur realm) {
	self = cur.PkgPath()
	gnotif.Declare(cross(cur), self, "Turn", "", "to", "Your move in Gnomehall", "{text}", "/?match={match}")
	gnotif.Declare(cross(cur), self, "Ended", "", "to", "Match over", "{text}", "/?match={match}")
}

// tell emits kind to player about match id. It emits nothing when player made the call,
// so an event never names its caller.
func tell(kind string, player, caller address, id int, text string) {
	if player == caller {
		return
	}
	chain.Emit(kind, "to", player.String(), "match", strconv.Itoa(id), "text", text)
}

// tellEnded sends Ended to each player of the finished match m, numbered id, but caller,
// one event each, since gnotif reads only the first value of a repeated attribute.
func tellEnded(m record, id int, caller address) {
	tell("Ended", m.challenger, caller, id, endText(m, 0))
	if m.acceptor != m.challenger {
		tell("Ended", m.acceptor, caller, id, endText(m, 1))
	}
}

// endText says how m ended to the player on side.
func endText(m record, side int) string {
	won := m.result == "a" && side == 0 || m.result == "b" && side == 1
	switch m.reason {
	case "hp":
		last := m.hp[plansMade(m.plans[0])-1]
		score := strconv.Itoa(last[side]) + " to " + strconv.Itoa(last[1-side]) + "."
		switch {
		case m.result == "draw":
			return "Draw on HP, " + score
		case won:
			return "You won on HP, " + score
		}
		return "You lost on HP, " + score
	case "knockout":
		switch {
		case m.result == "draw":
			return "Both gnomes fell: a draw."
		case won:
			return "You won by knockout."
		}
		return "You lost by knockout."
	case "resign":
		if won {
			return "Your opponent resigned. You won."
		}
		return "You resigned."
	}
	if won {
		return "You won by forfeit."
	}
	return "You lost by forfeit."
}
