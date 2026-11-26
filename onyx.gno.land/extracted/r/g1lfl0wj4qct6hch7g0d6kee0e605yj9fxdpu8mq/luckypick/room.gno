package luckypick

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	prize    = int64(400000)
	entry    = int64(100000)
	maxPicks = 5
)

type room struct {
	host    address
	picks   []string
	pending string
	closed  string
}

var (
	rooms        avl.Tree
	pendingPicks avl.Tree
	roomIDs      seqid.ID
)

func getRoom(id string) room {
	item := rooms.Get(id)
	if item == nil {
		panic("unknown room")
	}
	return item.(room)
}

func requireDeposit(amount int64) {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != amount {
		panic("send exactly " + strconv.FormatInt(amount, 10) + "ugnot")
	}
}

// OpenRoom locks the host's prize until the room ends.
func OpenRoom(cur realm) string {
	runtime.AssertOriginCall()
	requireDeposit(prize)
	id := roomIDs.Next().String()
	rooms.Set(id, room{host: cur.Previous().Address()})
	return id
}

// JoinRoom accepts a single paid guess when the room is idle.
func JoinRoom(cur realm, roomID string, number int) string {
	r := getRoom(roomID)
	if r.closed != "" || r.pending != "" {
		panic("room is closed or awaiting settlement")
	}
	runtime.AssertOriginCall()
	requireDeposit(entry)
	id := requestGuess(number, roomID, cur)
	r.picks = append(r.picks, id)
	r.pending = id
	pendingPicks.Set(id, true)
	rooms.Set(roomID, r)
	return id
}

func payRoom(requestID string, g guess, scope realm) {
	r := getRoom(g.roomID)
	if r.pending != requestID || r.closed != "" {
		panic("request does not match pending room pick")
	}
	hostAmount := entry
	b := banker.NewBanker(banker.BankerTypeRealmSend, scope)
	if g.result == g.choice {
		b.SendCoins(scope.Address(), g.player, chain.Coins{{"ugnot", prize}})
		r.closed = "Player won"
	} else if len(r.picks) == maxPicks {
		hostAmount += prize
		r.closed = "Host won"
	}
	b.SendCoins(scope.Address(), r.host, chain.Coins{{"ugnot", hostAmount}})
	r.pending = ""
	pendingPicks.Remove(requestID)
	rooms.Set(g.roomID, r)
}

// CloseRoom returns the prize to its host before the first guess.
func CloseRoom(cur realm, roomID string) {
	r := getRoom(roomID)
	if cur.Previous().Address() != r.host {
		panic("host only")
	}
	if r.closed != "" || r.pending != "" {
		panic("room is closed or awaiting settlement")
	}
	if len(r.picks) > 0 {
		panic("only rooms with no guesses can be closed")
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), r.host, chain.Coins{{"ugnot", prize}})
	r.closed = "Prize returned to host"
	rooms.Set(roomID, r)
}

// PendingPicks returns up to 20 unsettled room request IDs after the cursor.
func PendingPicks(after string) string {
	var ids []string
	pendingPicks.Iterate(after, "", func(id string, _ any) bool {
		if id != after {
			ids = append(ids, id)
		}
		return len(ids) == 20
	})
	return strings.Join(ids, ",")
}

func (r room) status() string {
	if r.closed != "" {
		return r.closed
	}
	if r.pending != "" {
		return "Awaiting draw"
	}
	return "Open"
}

func renderLobby() string {
	var p strings.Builder
	p.WriteString("# Lucky Pick\n\nPick 1–4. First match wins 0.4 test GNOT. Each guess costs 0.1 test GNOT; the host receives each entry fee. After five misses, the host gets the prize back.\n\n[Open a room](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick$help&func=OpenRoom&.send=400000ugnot) · Send 400000ugnot with this action.\n\n## Recent rooms\n\n")
	if rooms.Size() == 0 {
		p.WriteString("No rooms yet.")
	}
	rooms.ReverseIterateByOffset(0, 10, func(id string, item any) bool {
		r := item.(room)
		p.WriteString("- [Room " + id + "](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick:room/" + id + ") · " + r.status() + "\n")
		return false
	})
	return p.String()
}

func renderRoom(id string) string {
	if rooms.Get(id) == nil {
		return "Room not found."
	}
	r := getRoom(id)
	var p strings.Builder
	p.WriteString("# Room " + id + "\n\n" + r.status() + " · Host: " + r.host.String())
	p.WriteString("\n\nPrize: 0.4 test GNOT · Entry: 0.1 test GNOT · Guesses: " + strconv.Itoa(len(r.picks)) + "/5")
	if r.closed == "" && r.pending == "" {
		p.WriteString("\n\n[Pick a number](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick$help&func=JoinRoom&roomID=" + id + "&.send=100000ugnot) · Send 100000ugnot.")
		if len(r.picks) == 0 {
			p.WriteString("\n\n[Close room](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick$help&func=CloseRoom&roomID=" + id + ") · Host only, before the first guess.")
		}
	}
	for i, req := range r.picks {
		g := get(req)
		p.WriteString("\n\n[Guess " + strconv.Itoa(i+1) + "](/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick:" + req + ") · Picked " + strconv.Itoa(g.choice))
		if g.result == 0 {
			p.WriteString(" · Pending")
		} else {
			p.WriteString(" · Drawn " + strconv.Itoa(g.result))
		}
	}
	return p.String()
}
