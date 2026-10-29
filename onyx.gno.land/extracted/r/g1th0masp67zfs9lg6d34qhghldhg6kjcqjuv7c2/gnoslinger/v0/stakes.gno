package gnoslinger

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/engine/v0"
)

// Stakes (this project's, not the board game's): a showdown may be played
// for GNOT. The creator sends the stake with CreateGame, and every joiner
// sends the same with JoinGame; the realm holds them, the pot. When the
// showdown ends the house keeps HouseCutPercent of the pot for events, and
// the winner takes the rest; a draw splits it between the seats tied for
// the most victory points (what does not divide evenly goes to the house).
// A showdown that ends with nobody left in the fight, everyone out of time,
// or cancelled before it starts, gives every stake back in full. The admin, the deployer at
// first, may send the house's funds out (WithdrawHouse): a later version of
// the realm cannot reach this one's balance.

const (
	// Denom is the only coin a stake is paid in.
	Denom = "ugnot"
	// HouseCutPercent is the share of a pot the house keeps, for events.
	HouseCutPercent = 5
)

var (
	// house is what the realm holds for events: the house's cuts, less
	// what the admin withdrew. The rest of the realm's balance is the pots
	// of the showdowns not over yet.
	house int64
	// admin may withdraw the house's funds; the deployer at first.
	admin = unsafe.OriginCaller()
)

// sentStake returns the ugnot sent with the call, 0 for none. Coins can
// only come straight from a user's call: a realm in between could have
// spent the send it reports (unsafe.OriginSend is the whole message's).
func sentStake(cur realm) int64 {
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		return 0
	}
	if !cur.Previous().IsUserCall() {
		panic("gnoslinger: a stake can only be sent by a direct call")
	}
	if len(sent) != 1 || sent[0].Denom != Denom || sent[0].Amount <= 0 {
		panic("gnoslinger: a stake is paid in " + Denom + " only")
	}
	return sent[0].Amount
}

// assertNoSend refuses coins sent with a call that takes none: they would
// sit in the realm's balance with no showdown to pay them out.
func assertNoSend() {
	if len(unsafe.OriginSend()) > 0 {
		panic("gnoslinger: this call takes no coins")
	}
}

// pay sends amount ugnot from the realm to addr.
func pay(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin(Denom, amount)})
}

// refundStakes gives every seated player its stake back: the showdown
// was cancelled, or nobody was left to win it. Payouts records it, so a finished game says
// what each seat got.
func (g *Game) refundStakes(cur realm) {
	if g.Pot == 0 {
		return
	}
	g.Payouts = make([]int64, g.seats())
	for i, p := range g.Players {
		if p.Addr == "" {
			continue
		}
		pay(cur, p.Addr, g.Stake)
		g.Payouts[i] = g.Stake
		emit("StakeRefunded", "id", g.ID, "seat", strconv.Itoa(i), "player", p.Addr.String(), "amount", strconv.FormatInt(g.Stake, 10))
	}
}

// payPot pays the pot of a finished showdown: the house's cut, then the
// winner, or the seats tied for the most victory points in equal shares.
func (g *Game) payPot(cur realm) {
	if g.Pot == 0 || g.Payouts != nil {
		return
	}
	if g.nobodyWon() {
		g.refundStakes(cur)
		return
	}
	best := g.VP[0]
	for _, v := range g.VP {
		if v > best {
			best = v
		}
	}
	var winners []int
	for i, v := range g.VP {
		if v == best {
			winners = append(winners, i)
		}
	}
	cut := g.Pot * HouseCutPercent / 100
	share := (g.Pot - cut) / int64(len(winners))
	cut = g.Pot - share*int64(len(winners))
	g.Payouts = make([]int64, g.seats())
	for _, w := range winners {
		pay(cur, g.Players[w].Addr, share)
		g.Payouts[w] = share
		emit("PotPaid", "id", g.ID, "seat", strconv.Itoa(w), "player", g.Players[w].Addr.String(), "amount", strconv.FormatInt(share, 10))
	}
	g.HouseCut = cut
	house += cut
}

// nobodyWon tells a showdown that ended with nobody left in the fight
// because everyone ran out of time: nobody played it to the end, nothing
// was won.
func (g *Game) nobodyWon() bool {
	return g.EndReason == "timeout" && engine.AliveCount(g.State) == 0
}

// WithdrawHouse sends amount ugnot of the house's funds to an address.
// Admin only.
func WithdrawHouse(cur realm, to address, amount int64) {
	assertNoSend()
	assertAdmin(cur)
	if !to.IsValid() {
		panic("gnoslinger: invalid address")
	}
	if amount <= 0 || amount > house {
		panic("gnoslinger: the house holds " + strconv.FormatInt(house, 10) + Denom)
	}
	house -= amount
	pay(cur, to, amount)
	emit("HouseWithdrawn", "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// SetAdmin hands the house's funds over to another admin. Admin only.
func SetAdmin(cur realm, addr address) {
	assertNoSend()
	assertAdmin(cur)
	if !addr.IsValid() {
		panic("gnoslinger: invalid address")
	}
	admin = addr
	emit("AdminChanged", "admin", addr.String())
}

func assertAdmin(cur realm) {
	if prev := cur.Previous(); !prev.IsUser() || prev.Address() != admin {
		panic("gnoslinger: admin only")
	}
}

// House is the ugnot the house holds for events.
func House() int64 { return house }

// Admin is who may withdraw the house's funds.
func Admin() address { return admin }
