package continuity

import (
	"chain/runtime/unsafe"
	"strconv"
)

const maintainer = address("g18r7ee0utsm07jd6f7qnxc9us7yz2qpk8rednrs")

var revision int
var active bool

func Publish(_ realm) {
	if unsafe.OriginCaller() != maintainer {
		panic("maintainer signature required")
	}
	if active {
		panic("notice is already active")
	}
	revision++
	active = true
}

func Withdraw(_ realm, expectedRevision int) {
	if unsafe.OriginCaller() != maintainer {
		panic("maintainer signature required")
	}
	if !active || expectedRevision != revision {
		panic("notice is inactive or revision has changed")
	}
	active = false
}

func Render(_ string) string {
	if !active {
		return "# Release notice\n\nStatus: withdrawn or unpublished.\n\nRevision: " + strconv.Itoa(revision) + "."
	}
	return "# Release notice\n\nStatus: active.\n\nRevision: " + strconv.Itoa(revision) +
		".\n\n[Withdraw release notice](/r/g18r7ee0utsm07jd6f7qnxc9us7yz2qpk8rednrs/continuity$help&func=Withdraw&expectedRevision=" + strconv.Itoa(revision) + ")"
}
