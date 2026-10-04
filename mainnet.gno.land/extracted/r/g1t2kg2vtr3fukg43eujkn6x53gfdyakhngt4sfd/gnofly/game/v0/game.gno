package game

import (
	"strconv"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ownable/v0"
)

// The whole state of the realm. Everything is unexported and nothing below is
// ever returned by reference: the trees and the ownable are /p/ types with
// mutator methods, so handing one out would be handing out write access to
// the realm.
var (
	owner    *ownable.Ownable // the single owner, always an admin
	admins   bptree.BPTree    // extra admins, managed by the owner: address -> nil
	referees bptree.BPTree    // game servers allowed to submit kills: address -> nil
	treasury address          // where the sales of the skins and planes realms go

	version int64 // bumps on every admin write, see Version

	params []*param      // fixed registry, in display order
	pilots bptree.BPTree // player address -> int64 kills, allocated at the first kill

	killers ranking // the top players by kills recorded on-chain, see rankings.gno

	webPath string // "/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/game/v0", used to build links in Render
)

// init runs once, when the package is added to the chain. This is the only
// moment cur.Previous() is the deployer, so it is recorded here: the deployer
// starts as owner, referee and treasury.
//
// Under `gno test` there is no deployer and the address is empty. The tests
// call bootstrap themselves with a real address.
func init(cur realm) {
	bootstrap(cur.Previous().Address(), cur.PkgPath())
}

// bootstrap (re)creates the initial state: roles and params.
func bootstrap(deployer address, pkgPath string) {
	owner = ownable.NewWithAddress(deployer)
	admins = bptree.BPTree{}
	referees = bptree.BPTree{}
	referees.Set(deployer.String(), nil)
	treasury = deployer

	params = defaultParams()
	pilots = bptree.BPTree{}
	killers = ranking{}
	webPath = webPathOf(pkgPath)

	version = 1
}

// Version returns a counter that bumps on every admin write: params,
// treasury and roles. Referee actions (kills) do not bump it. A reader that cached StateJSON only has to read it
// again when Version changed.
func Version() int64 {
	return version
}

// bump marks the admin-tunable state as changed.
func bump() {
	version++
}

// webPathOf turns "gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/game/v0" into "/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/game/v0".
func webPathOf(pkgPath string) string {
	for i := 0; i < len(pkgPath); i++ {
		if pkgPath[i] == '/' {
			return pkgPath[i:]
		}
	}
	return ""
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}
