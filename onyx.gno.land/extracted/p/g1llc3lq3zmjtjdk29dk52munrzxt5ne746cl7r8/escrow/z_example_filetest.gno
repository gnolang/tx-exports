// PKGPATH: gno.land/r/example/bounty

// This is the "Using p/escrow in your own realm" example from README.md, kept
// here so that `gno test` compiles and runs it. The realm part (everything
// above main) is what the README shows; main plays two users through one
// quest and prints the result.
package bounty

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"testing"

	"gno.land/p/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/escrow"
	"gno.land/p/nt/avl/v0"
)

var (
	quests avl.Tree // id -> *escrow.Quest
	lastID uint64
)

// Post locks the ugnot sent with the call as the reward.
func Post(cur realm, title string, workBlocks int64) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("direct user calls only")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" {
		panic("send the reward as one ugnot coin")
	}
	lastID++
	q, err := escrow.NewQuest(lastID, cur.Previous().Address(), title, "", sent[0].Amount, workBlocks, runtime.ChainHeight())
	if err != nil {
		panic(err.Error())
	}
	quests.Set(strconv.FormatUint(lastID, 10), q)
	return lastID
}

func Claim(cur realm, id uint64) {
	check(get(id).Claim(cur.Previous().Address(), runtime.ChainHeight()))
}

func Submit(cur realm, id uint64, link string) {
	check(get(id).Submit(cur.Previous().Address(), link, runtime.ChainHeight()))
}

// Approve applies the move first, then pays exactly what the escrow says.
func Approve(cur realm, id uint64) {
	p, err := get(id).Approve(cur.Previous().Address(), runtime.ChainHeight())
	check(err)
	pay(p, cur)
}

func pay(p escrow.Payout, rlm realm) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	b.SendCoins(rlm.Address(), p.To, chain.Coins{{Denom: "ugnot", Amount: p.Amount}})
}

func get(id uint64) *escrow.Quest {
	v := quests.Get(strconv.FormatUint(id, 10))
	if v == nil {
		panic("unknown quest")
	}
	return v.(*escrow.Quest)
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}

// ---- test driver (not part of the README example)

func main(cur realm) {
	poster := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	builder := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	reward := chain.Coins{{Denom: "ugnot", Amount: 2_000_000}}
	testing.IssueCoins(cur.Address(), reward) // what -send does on chain

	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(reward)
	id := Post(cross(cur), "Write a guide", escrow.MinWorkBlocks)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(builder))
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://example.com/guide")

	testing.SetRealm(testing.NewUserRealm(poster))
	Approve(cross(cur), id)

	bk := banker.NewReadonlyBanker()
	println(get(id).State().String(), bk.GetCoin(builder, "ugnot"), bk.GetCoin(cur.Address(), "ugnot"))
}

// Output:
// Paid 2000000 0
