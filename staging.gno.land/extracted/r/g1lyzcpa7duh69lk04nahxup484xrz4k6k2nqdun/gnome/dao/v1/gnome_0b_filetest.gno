package main

import (
	"std"

	gnome "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao/v1"
)

const nonMember = std.Address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

func init() {
	std.TestSetOriginCaller(nonMember)
}

func main() {
	title := "Test proposal"
	desc := "A test proposal"
	daoPath := "council/main"
	gnome.SubmitGeneralProposal(title, desc, daoPath, 0)
}

// Error:
// you must be a DAO member to create a proposal
