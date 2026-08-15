package gnoswap

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/mockfarm"
)

// Local / unit-test harvest: ugnot is the stand-in want token and a mock farm
// stands in for GnoSwap emissions. Swap this file for harvest_sapphire.gno
// before deploying to Sapphire (see that file's header).

var localFarm = mockfarm.New()

func pullWant(cur realm, from address, amount int64) {
	if !cur.Previous().IsUserCall() {
		panic("only EOA via MsgCall can fund this")
	}
	if cur.Previous().Address() != from {
		panic("from must be caller")
	}
	sent := unsafe.OriginSend().AmountOf("ugnot")
	if sent != amount {
		panic("send exact ugnot amount")
	}
}

func pushWant(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.Coins{{Denom: "ugnot", Amount: amount}})
}

func harvestProtocol(_ realm) int64 {
	return localFarm.Harvest()
}

func pendingProtocol() int64 {
	return localFarm.Pending()
}

// SeedYield is the local stand-in for GnoSwap reward accrual.
func SeedYield(cur realm, amount int64) {
	mustAdmin(cur)
	localFarm.Accrue(amount)
}
