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
	gnome.SubmitGeneralProposal(title, desc, daoPath, 1)
}

// Error:
// voting period deadline must be between 2 and 10 days
