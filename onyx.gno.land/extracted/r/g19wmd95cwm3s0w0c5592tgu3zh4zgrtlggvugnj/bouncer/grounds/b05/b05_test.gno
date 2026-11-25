package b05

import (
	"chain"
	"chain/runtime"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const pkgPath = "gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/grounds/b05"

var (
	honest = address("g1honest00000000000000000000000000000000")
	hunter = address("g1hunter00000000000000000000000000000000")
)

func TestHonestTipCannotClaim(cur realm, t *testing.T) {
	// A MsgCall with -send: the coins really arrive.
	testing.IssueCoins(chain.PackageAddress(pkgPath), chain.Coins{chain.NewCoin("ugnot", 300)})
	testing.SetRealm(testing.NewUserRealm(honest))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 300)})
	Tip(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, int64(300), CreditOf(honest))
	uassert.False(t, Broken())
	testing.SetRealm(testing.NewUserRealm(honest))
	uassert.AbortsWithMessage(t, cur, "not broken for your address: you are credited 300 ugnot and 300 ugnot arrived", func() {
		Claim(cross(cur))
	})
}

func TestMsgRunBreaksAndClaims(cur realm, t *testing.T) {
	// A MsgRun: OriginSend says 1000, but nothing reaches this realm.
	testing.SetRealm(runtime.NewRealm(hunter, "gno.land/e/"+hunter.String()+"/run"))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 1000)})
	Tip(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	uassert.True(t, Broken())

	testing.SetRealm(testing.NewUserRealm(hunter))
	Claim(cross(cur))
	hs := Hunters()
	uassert.Equal(t, 1, len(hs))
	uassert.Equal(t, int64(1000), hs[0].Credited)
	uassert.Equal(t, int64(0), hs[0].Received)
	uassert.True(t, strings.Contains(Render(""), "| 1 | `"+hunter.String()+"` | 1000 | 0 |"), Render(""))
	testing.SetRealm(testing.NewUserRealm(hunter))
	uassert.AbortsWithMessage(t, cur, "already on the hunters board", func() {
		Claim(cross(cur))
	})
}
