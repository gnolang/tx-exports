package heirloom

import (
	"chain"
	"chain/banker"

	"gno.land/r/nt/grc20reg/v0"
)

const gnot = "ugnot"

func credit(w *Will, asset string, amount int64) {
	w.add(asset, amount)
	if asset == gnot {
		state.totalGNOT += amount
	}
}

func payOut(cur realm, w *Will, asset string, to address, amount int64) {
	w.take(asset, amount)
	if asset == gnot {
		state.totalGNOT -= amount
	}
	send(cur, asset, to, amount)
}

func pullToken(cur realm, w *Will, token string, amount int64) {
	grc20reg.TransferFrom(0, cur, token, w.Owner, cur.Address(), amount)
	credit(w, token, amount)
}

func send(cur realm, asset string, to address, amount int64) {
	if asset != gnot {
		grc20reg.Transfer(0, cur, asset, to, amount)
		return
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).
		SendCoins(cur.Address(), to, chain.Coins{{gnot, amount}})
}
