package main

import (
	"std"

	gnome "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao/v1"
)

const member = std.Address("g1e5hud66rs7ye4zgeqmqvwfhurs2mnf408hdqcl")

func init() {
	std.TestSetOrigCaller(member)
}

func main() {
	title := "Test proposal"
	desc := "A test proposal"
	daoPath := "council/main"
	pID := gnome.SubmitGeneralProposal(title, desc, daoPath, 0)
	println(pID)

	markdown := gnome.Render("proposal/1")
	println(markdown)
}

// Output:
// 1
// # #1 Test proposal
// - Type: general
// - Created: 2009-02-13 23:31 UTC
// - Proposer: g1e5hud66rs7ye4zgeqmqvwfhurs2mnf408hdqcl
// - Status: **review**
// - Review Deadline: 2009-02-14 00:31 UTC
// ## Description
// A test proposal
// ## Votes
// The proposal has no votes
