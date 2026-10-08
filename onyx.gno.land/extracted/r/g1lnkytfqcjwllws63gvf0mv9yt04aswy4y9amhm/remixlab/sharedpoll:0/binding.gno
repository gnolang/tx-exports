package sharedpoll

import (
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/sharedmembers"
)

// sharedPath is the reviewed shared membership realm this app is bound to.
const sharedPath = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/sharedmembers"

// sharedReader adapts the shared membership realm to core.MembershipReader.
// It is read-only: it can look roles up and take snapshots, nothing else.
type sharedReader struct{}

func (sharedReader) RoleOf(addr address) core.Role { return sharedmembers.RoleOf(addr) }
func (sharedReader) Size() int                     { return sharedmembers.Size() }
func (sharedReader) Snapshot(minRole core.Role, max int) ([]address, bool) {
	return sharedmembers.Snapshot(minRole, max)
}

// electorate is the membership source for poll electorates. Tests replace
// it with a local fake; production code never reassigns it.
var electorate core.MembershipReader = sharedReader{}
