package crazy_lottery

import "strconv"

var tickets map[string]int
var drawCalled bool
var winner string

func init() {
	tickets = make(map[string]int)
}

func BuyTicket(_ realm, player string) int {
	tickets[player]++
	return tickets[player]
}

func Draw(_ realm) string {
	if drawCalled {
		panic("already drawn")
	}
	drawCalled = true
	max := 0
	for p, t := range tickets {
		if t > max {
			max = t
			winner = p
		}
	}
	return winner
}

func Render(_ string) string {
	out := "CRAZY LOTTERY\n"
	out += "players: " + strconv.Itoa(len(tickets)) + "\n"
	if drawCalled {
		out += "winner: " + winner + "\n"
	} else {
		out += "status: open\n"
	}
	return out
}
