package main

// SEND: 200000000ugnot

import (
	"std"

	"gno.land/p/demo/testutils"
	"gno.land/r/demo/users"
)

const admin = std.Address("g1manfred47kzduec920z88wfr64ylksmdcedlf5")

func main() {
	caller := std.OriginCaller() // main
	users.Register("", "gnouser", "my profile")
	// as admin, grant invites to gnouser
	std.TestSetOriginCaller(admin)
	users.GrantInvites(caller.String() + ":1")
	// switch back to caller
	std.TestSetOriginCaller(caller)
	// invite another addr
	test1 := testutils.TestAddress("test1")
	users.Invite(test1.String())
	// switch to test1
	std.TestSetOriginCaller(test1)
	std.TestSetOriginSend(std.Coins{{"dontcare", 1}}, nil)
	users.Register(caller, "satoshi", "my other profile")
	println(users.Render(""))
	println("========================================")
	println(users.Render("gnouser"))
	println("========================================")
	println(users.Render("satoshi"))
	println("========================================")
	println(users.Render("badname"))
}

// Output:
// * [archives](/r/demo/users:archives)
//  * [demo](/r/demo/users:demo)
//  * [gno](/r/demo/users:gno)
//  * [gnoland](/r/demo/users:gnoland)
//  * [gnolang](/r/demo/users:gnolang)
//  * [gnouser](/r/demo/users:gnouser)
//  * [gov](/r/demo/users:gov)
//  * [nt](/r/demo/users:nt)
//  * [satoshi](/r/demo/users:satoshi)
//  * [sys](/r/demo/users:sys)
//  * [test1](/r/demo/users:test1)
//  * [x](/r/demo/users:x)
//
// ========================================
// ## user gnouser
//
//  * address = g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
//  * 9 invites
//
// my profile
//
// ========================================
// ## user satoshi
//
//  * address = g1w3jhxap3ta047h6lta047h6lta047h6l4mfnm7
//  * 0 invites
//  * invited by g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
//
// my other profile
//
// ========================================
// unknown username badname
