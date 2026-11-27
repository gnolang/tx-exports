package till

import (
	"chain"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

var tillAddr = chain.PackageAddress("gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/till")

func TestNoMoneyNoRound(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", Price-1)})
	uassert.AbortsContains(t, cur, "send it with the call", func() { BuyRound(cross(cur)) })
}

func TestPaidRoundIsNotStolen(cur realm, t *testing.T) {
	paid := chain.Coins{chain.NewCoin("ugnot", Price)}
	testing.SetRealm(testing.NewUserRealm(ash))
	testing.SetOriginSend(paid)
	testing.IssueCoins(tillAddr, paid) // the chain credits the till before the call runs
	BuyRound(cross(cur))
	uassert.Equal(t, 1, Rounds(ash))
	uassert.False(t, captures.Captured(ash))
}
