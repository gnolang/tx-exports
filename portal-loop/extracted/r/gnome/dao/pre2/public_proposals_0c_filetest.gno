package main

import (
	"std"

	gnome "gno.land/r/gnome/dao/pre2"
)

const member = std.Address("g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun")

func init() {
	std.TestSetOriginCaller(member)
}

func main() {
	title := "Test proposal"
	desc := "A test proposal"
	daoPath := "council/main"
	gnome.SubmitGeneralProposal(title, desc, daoPath, 1)
}

// Error:
// voting period deadline must be between 2 and 10 days
