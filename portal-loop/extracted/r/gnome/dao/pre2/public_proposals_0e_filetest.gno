package main

import (
	"std"

	gnome "gno.land/r/gnome/dao/pre2"
)

const member = std.Address("g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun")

func init() {
	std.TestSetOrigCaller(member)
}

func main() {
	title := "Test proposal"
	daoPath := "council/main"
	gnome.SubmitGeneralProposal(title, "", daoPath, 0)
}

// Error:
// proposal description is required
