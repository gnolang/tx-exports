package grantround

import (
	"chain/runtime"
	"testing"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
	"gno.land/p/nt/uassert/v0"
)

func TestCreateRound(cur realm, t *testing.T) {
	id, h0 := newRound(cur, e1, s1, e2, s2)
	r := mustGet(id)
	uassert.True(t, id > 0)
	uassert.Equal(t, customer, r.Customer)
	uassert.Equal(t, tGrant, r.Grant)
	uassert.Equal(t, 2, len(r.Evaluators))
	uassert.Equal(t, h0+40, r.HScore)
	uassert.Equal(t, h0+50, r.HSheetReveal)
	uassert.True(t, PhaseOf(r, runtime.ChainHeight()) == PhaseJoin, "phase join")
}

func TestCreateRoundRejects(cur realm, t *testing.T) {
	h := runtime.ChainHeight()
	hash := rulecalc.AppsDigest(testApps(), tSalt)
	evs := evList(e1, s1, e2, s2)
	testing.SetRealm(user(customer))

	noPay()
	uassert.AbortsContains(t, cur, "grant", func() {
		CreateRound(cross(cur), "g", hash, evs, tBond, tSlash, h+10, h+20, h+30, h+40, h+50)
	})
	testing.SetOriginSend(ugnot(tGrant).Add(chainCoin("uatom", 5)))
	uassert.AbortsContains(t, cur, "ugnot", func() {
		CreateRound(cross(cur), "g", hash, evs, tBond, tSlash, h+10, h+20, h+30, h+40, h+50)
	})
	cases := []struct {
		name                            string
		hash, evs                       string
		bond, slash                     int64
		hJoin, hRule, hRev, hScore, hSR int64
		want                            string
	}{
		{"slash>bond", hash, evs, 10, 11, h + 10, h + 20, h + 30, h + 40, h + 50, "slash"},
		{"bond 0", hash, evs, 0, 0, h + 10, h + 20, h + 30, h + 40, h + 50, "bond"},
		{"negative slash", hash, evs, 10, -1, h + 10, h + 20, h + 30, h + 40, h + 50, "slash"},
		{"deadlines order", hash, evs, tBond, tSlash, h + 10, h + 10, h + 30, h + 40, h + 50, "deadline"},
		{"sheet reveal not after score", hash, evs, tBond, tSlash, h + 10, h + 20, h + 30, h + 40, h + 40, "deadline"},
		{"join in past", hash, evs, tBond, tSlash, h, h + 20, h + 30, h + 40, h + 50, "deadline"},
		{"no evaluators", hash, "", tBond, tSlash, h + 10, h + 20, h + 30, h + 40, h + 50, "evaluator"},
		{"duplicate evaluator", hash, evList(e1, s1, e1, s2), tBond, tSlash, h + 10, h + 20, h + 30, h + 40, h + 50, "evaluator"},
		{"invalid evaluator", hash, "nope:" + s1.String(), tBond, tSlash, h + 10, h + 20, h + 30, h + 40, h + 50, "evaluator"},
		{"missing sponsor", hash, e1.String(), tBond, tSlash, h + 10, h + 20, h + 30, h + 40, h + 50, "sponsor"},
		{"invalid sponsor", hash, e1.String() + ":nope", tBond, tSlash, h + 10, h + 20, h + 30, h + 40, h + 50, "sponsor"},
		{"bad hash", "abc", evs, tBond, tSlash, h + 10, h + 20, h + 30, h + 40, h + 50, "hash"},
	}
	for _, c := range cases {
		pay(tGrant)
		uassert.AbortsContains(t, cur, c.want, func() {
			CreateRound(cross(cur), "g", c.hash, c.evs, c.bond, c.slash, c.hJoin, c.hRule, c.hRev, c.hScore, c.hSR)
		}, c.name)
	}
}

func TestJoin(cur realm, t *testing.T) {
	id, _ := newRound(cur, e1, s1, e2, s2)
	joinAll(cur, id, e1, s1)
	r := mustGet(id)
	uassert.Equal(t, s1, r.Sponsors[0])
	uassert.Equal(t, address(""), r.Sponsors[1])
	uassert.Equal(t, 1, r.joined())
}

func TestJoinRejects(cur realm, t *testing.T) {
	id, _ := newRound(cur, e1, s1, e2, s2)
	testing.SetRealm(user(s1))

	pay(tBond - 1)
	uassert.AbortsContains(t, cur, "bond", func() { Join(cross(cur), id, e1) }, "short bond")
	testing.SetOriginSend(ugnot(tBond).Add(chainCoin("uatom", 1)))
	uassert.AbortsContains(t, cur, "ugnot", func() { Join(cross(cur), id, e1) }, "extra denom")
	pay(tBond)
	uassert.AbortsContains(t, cur, "not an evaluator", func() { Join(cross(cur), id, outsider) })

	pay(tBond)
	Join(cross(cur), id, e1)
	pay(tBond)
	uassert.AbortsContains(t, cur, "already joined", func() { Join(cross(cur), id, e1) })

	testing.SkipHeights(11)
	testing.SetRealm(user(s2))
	pay(tBond)
	uassert.AbortsContains(t, cur, "join phase", func() { Join(cross(cur), id, e2) })
}

func TestJoinOnlyDesignatedSponsor(cur realm, t *testing.T) {
	id, _ := newRound(cur, e1, s1, e2, s2)
	testing.SetRealm(user(outsider))
	pay(tBond)
	uassert.AbortsContains(t, cur, "designated sponsor", func() { Join(cross(cur), id, e1) }, "outsider")
	testing.SetRealm(user(s2))
	pay(tBond)
	uassert.AbortsContains(t, cur, "designated sponsor", func() { Join(cross(cur), id, e1) }, "another evaluator's sponsor")
	testing.SetRealm(user(s1))
	pay(tBond)
	Join(cross(cur), id, e1)
	uassert.Equal(t, s1, mustGet(id).Sponsors[0])
}
