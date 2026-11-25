package grantround

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"testing"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
	"gno.land/p/nt/testutils/v0"
)

var (
	pkgAddr  = chain.PackageAddress("gno.land/r/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/grantround/v1")
	customer = testutils.TestAddress("customer")
	e1       = testutils.TestAddress("eval1")
	e2       = testutils.TestAddress("eval2")
	e3       = testutils.TestAddress("eval3")
	s1       = testutils.TestAddress("sponsor1")
	s2       = testutils.TestAddress("sponsor2")
	s3       = testutils.TestAddress("sponsor3")
	p0       = testutils.TestAddress("payout0")
	p1       = testutils.TestAddress("payout1")
	outsider = testutils.TestAddress("outsider")
)

const (
	tGrant = int64(1000000)
	tBond  = int64(100000)
	tSlash = int64(40000)
	tSalt  = "0123456789abcdef0123456789abcdef" // exactly 32 characters
	tWrong = "ffffffffffffffffffffffffffffffff" // long enough, but not the committed salt
)

func ugnot(n int64) chain.Coins { return chain.Coins{{"ugnot", n}} }

// user is used inline as testing.SetRealm(user(a)): SetRealm applies to the
// calling frame, so it must run in the function that makes the cross call.
func user(a address) runtime.Realm { return testing.NewUserRealm(a) }

// pay simulates a user call that attaches n ugnot: the envelope and the realm balance.
func pay(n int64) {
	testing.SetOriginSend(ugnot(n))
	testing.IssueCoins(pkgAddr, ugnot(n))
}

func noPay() { testing.SetOriginSend(chain.Coins{}) }

func bal(a address) int64 { return banker.NewReadonlyBanker().GetCoins(a).AmountOf("ugnot") }

func testApps() []rulecalc.App {
	return []rulecalc.App{
		{Title: "Alpha", PkgPath: "gno.land/r/x/alpha", Payout: p0},
		{Title: "Beta", PkgPath: "gno.land/r/x/beta", Payout: p1},
	}
}

func testAppsEncoded() string {
	return "Alpha|gno.land/r/x/alpha|" + p0.String() + "\nBeta|gno.land/r/x/beta|" + p1.String()
}

// evList encodes eval,sponsor pairs as "eval:sponsor,eval:sponsor".
func evList(pairs ...address) string {
	s := ""
	for i := 0; i+1 < len(pairs); i += 2 {
		if i > 0 {
			s += ","
		}
		s += pairs[i].String() + ":" + pairs[i+1].String()
	}
	return s
}

// newRound creates a round for eval,sponsor pairs with deadlines h0+10/20/30/40/50
// and returns its id and h0.
func newRound(cur realm, pairs ...address) (int, int64) {
	return newRoundSalted(cur, tSalt, pairs...)
}

func newRoundSalted(cur realm, salt string, pairs ...address) (int, int64) {
	h0 := runtime.ChainHeight()
	testing.SetRealm(user(customer))
	pay(tGrant)
	id := CreateRound(cross(cur), "Fund one useful Gno package", rulecalc.AppsDigest(testApps(), salt),
		evList(pairs...), tBond, tSlash, h0+10, h0+20, h0+30, h0+40, h0+50)
	return id, h0
}

func joinAll(cur realm, id int, pairs ...address) {
	for i := 0; i+1 < len(pairs); i += 2 {
		testing.SetRealm(user(pairs[i+1]))
		pay(tBond)
		Join(cross(cur), id, pairs[i])
	}
}
