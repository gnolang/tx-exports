package main

import (
	"std"

	pVals "gno.land/p/sys/validators"
	govdao "gno.land/r/gov/dao"
	"gno.land/r/sys/validators"
)

func init() {
	changesFn := func() []pVals.Validator {
		return []pVals.Validator{
			{
				Address:     std.Address("g12345678"),
				PubKey:      "pubkey",
				VotingPower: 10, // add a new validator
			},
			{
				Address:     std.Address("g000000000"),
				PubKey:      "pubkey",
				VotingPower: 10, // add a new validator
			},
			{
				Address:     std.Address("g000000000"),
				PubKey:      "pubkey",
				VotingPower: 0, // remove an existing validator
			},
		}
	}

	// Wraps changesFn to emit a certified event only if executed from a
	// complete governance proposal process.
	executor := validators.NewPropExecutor(changesFn)

	// Create a proposal.
	// XXX: payment
	comment := "manual valset changes proposal example"
	govdao.Propose(comment, executor)
}

func main() {
	println("--")
	println(govdao.Render(""))
	println("--")
	println(govdao.Render("1"))
	println("--")
	govdao.VoteOnProposal(1, "YES")
	println("--")
	println(govdao.Render("1"))
	println("--")
	println(validators.Render(""))
	println("--")
	govdao.ExecuteProposal(1)
	println("--")
	println(govdao.Render("1"))
	println("--")
	println(validators.Render(""))
}

// Output:
// --
// - [/r/gov/dao:0](0) - manual valset changes proposal example (by g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
// --
// # Prop#0
//
// manual valset changes proposal example
// Status: active
// Author: g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
// --
// --
// # Prop#0
//
// manual valset changes proposal example
// Status: accepted
// Author: g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
// --
// No valset changes to apply.
// --
// --
// # Prop#0
//
// manual valset changes proposal example
// Status: succeeded
// Author: g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
// --
// Valset changes:
// - #123: g12345678 (10)
// - #123: g000000000 (10)
// - #123: g000000000 (0)
