package luckypick

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/drand/v0"
)

const lookaheadSeconds = 60

type guess struct {
	player address
	choice int
	result int // 0 until settled
	roomID string
	round  uint64
}

var guesses avl.Tree

// Pick commits the number and the beacon request in one transaction.
func Pick(cur realm, number int) string {
	return requestGuess(number, "", cur)
}

func requestGuess(number int, roomID string, scope realm) string {
	if number < 1 || number > 4 {
		panic("pick a number from 1 to 4")
	}
	id := drand.RequestAfter(cross(scope), time.Now().Unix()+lookaheadSeconds)
	round, ready := drand.Status(id)
	if round == 0 || ready {
		panic("expected an unpublished round")
	}
	guesses.Set(id, guess{player: scope.Previous().Address(), choice: number, round: round, roomID: roomID})
	return id
}

func get(id string) guess {
	item := guesses.Get(id)
	if item == nil {
		panic("unknown pick")
	}
	return item.(guess)
}

// Settle is permissionless. Every retry returns the same result.
func Settle(cur realm, id string) int {
	g := get(id)
	if g.result == 0 {
		value := drand.MustGet(id)
		g.result = int(value[0]%4) + 1
		if g.roomID != "" {
			payRoom(id, g, cur)
		}
		guesses.Set(id, g)
	}
	return g.result
}

// Receipt gives clients typed values independent of the page layout.
func Receipt(id string) (uint64, int, int) {
	g := get(id)
	return g.round, g.choice, g.result
}

func Render(path string) string {
	if strings.HasPrefix(path, "room/") {
		return renderRoom(strings.TrimPrefix(path, "room/"))
	}
	if path != "" {
		item := guesses.Get(path)
		if item == nil {
			return "Pick not found."
		}
		g := item.(guess)
		out := "# Lucky Pick receipt\n\nPlayer: " + g.player.String() +
			"\n\nPicked: " + strconv.Itoa(g.choice) +
			"\n\ndrand request: [" + path + "](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/drand/v0:request/" + path + ")" +
			"\n\nevmnet round: " + strconv.FormatUint(g.round, 10)
		if g.roomID != "" {
			out += "\n\n[Room " + g.roomID + "](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick:room/" + g.roomID + ") · Entry 0.1 test GNOT · Prize 0.4 test GNOT"
		}
		if g.result == 0 {
			if _, ready := drand.Status(path); ready {
				return out + "\n\nProof verified. [Ready to settle](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick$help&func=Settle&id=" + path + ")."
			}
			return out + "\n\nWaiting for the signed beacon."
		}
		out += "\n\nDrawn: " + strconv.Itoa(g.result)
		if g.choice == g.result {
			out += " · Match"
			if g.roomID != "" {
				out += "\n\nPaid 0.4 test GNOT to the player and 0.1 test GNOT to the host."
			}
			return out
		}
		out += " · Miss"
		if g.roomID != "" {
			r := getRoom(g.roomID)
			out += "\n\nPaid 0.1 test GNOT to the host."
			if len(r.picks) == maxPicks && r.picks[maxPicks-1] == path {
				out += " Returned the 0.4 test GNOT prize to the host."
			}
		}
		return out
	}
	var page strings.Builder
	page.WriteString(renderLobby() + "\n\n## Recent picks\n\n")
	if guesses.Size() == 0 {
		page.WriteString("No picks yet.")
	}
	guesses.ReverseIterateByOffset(0, 10, func(id string, _ any) bool {
		page.WriteString("- [" + id + "](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick:" + id + ")\n")
		return false
	})
	return page.String()
}
