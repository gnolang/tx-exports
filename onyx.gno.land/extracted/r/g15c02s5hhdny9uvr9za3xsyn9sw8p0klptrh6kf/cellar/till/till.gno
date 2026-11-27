// Package till is a Cellar challenge about native coins and the origin
// send envelope.
package till

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/avl/v0"
)

// Price of a round, in ugnot (0.1 GNOT).
const Price int64 = 100_000

var (
	strongbox = address("g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf") // where the till is emptied
	rounds    = avl.NewTree()                                       // address -> rounds poured
	stolen    int                                                   // rounds the auditor flagged
)

// BuyRound pours you a round once the barkeep sees you sent the price.
// Send the coins with the call: gnokey maketx call -send 100000ugnot.
func BuyRound(cur realm) {
	player := flag.MustPlayer(cur.Previous())
	if unsafe.OriginSend().AmountOf("ugnot") < Price {
		panic("till: a round is " + strconv.FormatInt(Price, 10) + "ugnot; send it with the call")
	}
	n, _ := rounds.Get(player.String()).(int)
	rounds.Set(player.String(), n+1)
	audit(cur, player)
}

// audit counts the till after a round and empties it into the strongbox.
// A round poured with less than its price in the till was not paid for.
func audit(cur realm, player address) {
	bank := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	inTill := bank.GetCoin(cur.Address(), "ugnot")
	if inTill < Price {
		stolen++
		captures.Record(player)
	}
	if inTill > 0 {
		bank.SendCoins(cur.Address(), strongbox, chain.Coins{chain.NewCoin("ugnot", inTill)})
	}
}

// Rounds returns how many rounds addr has been poured.
func Rounds(addr address) int {
	n, _ := rounds.Get(addr.String()).(int)
	return n
}

// Render shows the bar's books.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n**A round:** " + strconv.FormatInt(Price, 10) + "ugnot · **Rounds the auditor flagged:** " +
		strconv.Itoa(stolen) + "\n\n## Rounds poured\n\n")
	if rounds.Size() == 0 {
		b.WriteString("*The bar is quiet.*\n")
	}
	rounds.Iterate("", "", func(addr string, v any) bool {
		b.WriteString("- `" + addr + "`: " + strconv.Itoa(v.(int)) + "\n")
		return false
	})
	b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
	return b.String()
}
