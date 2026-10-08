// Package fishlab is a small onyx trial of the corrected kill rule.
// A full copy of shoal/fish did not become live under the deploy deposit.
// This realm does not replace gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/shoal/fish.
// Strike has no size penalty and no prey bonus.
// PayCovered draws 1 whole FISH per 1 whole GNOT of the covered stake.
// The covered stake is the smaller of the two pools. A zero stake pays nothing.
// The draw comes from an approved reserve. It does not mint FISH.
package fishlab

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	shoaltoken "gno.land/r/g10ragdr3cjqkael8rslpw4y6rlelhev4h0fswcx/fishcoin"
)

const unit int64 = 1_000_000

var (
	inited  bool
	self    address
	reserve address
	creator address
)

func Init(cur realm, who address) {
	if !cur.IsCurrent() {
		panic("fishlab: realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("fishlab: eoa")
	}
	takeExact(0)
	if inited {
		panic("fishlab: init")
	}
	if !who.IsValid() {
		panic("fishlab: reserve")
	}
	inited = true
	self = cur.Address()
	reserve = who
	creator = cur.Previous().Address()
	chain.Emit("Init", "self", self.String(), "reserve", who.String())
}

func Realm() string {
	return self.String()
}

func Reserve() string {
	return reserve.String()
}

func Strike(bite, hpMax int) int {
	if hpMax < 0 {
		hpMax = 0
	}
	dmg := bite * 100 / (hpMax + 100)
	if dmg < 1 {
		return 1
	}
	return dmg
}

func PayCovered(cur realm, coveredUgnot int64) int64 {
	if !cur.IsCurrent() {
		panic("fishlab: realm")
	}
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("fishlab: eoa")
	}
	takeExact(0)
	if !inited {
		panic("fishlab: init")
	}
	if coveredUgnot <= 0 {
		return 0
	}
	whole := coveredUgnot / unit
	if whole <= 0 {
		return 0
	}
	if shoaltoken.Spender() != self {
		panic("fishlab: spender")
	}
	units := whole * unit
	got := shoaltoken.Draw(cross(cur), reserve, caller.Address(), units)
	chain.Emit("PayCovered", "whole", strconv.FormatInt(whole, 10), "got", strconv.FormatInt(got, 10))
	return got
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("fishlab: payment")
		}
		return
	}
	panic("fishlab: payment")
}
