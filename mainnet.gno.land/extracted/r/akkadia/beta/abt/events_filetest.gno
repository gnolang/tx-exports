// PKGPATH: gno.land/r/akkadia/beta/abt_events
package abt_events

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/akkadia/beta/abt"
	"gno.land/r/akkadia/beta/admin"
)

func main(cur realm) {
	caller := testutils.TestAddress("abtEventAdmin")
	testing.SetOriginCaller(admin.GetAdmin())
	testing.SetRealm(testing.NewUserRealm(admin.GetAdmin()))
	admin.TransferAdmin(cross(cur), caller)
	testing.SetOriginCaller(caller)
	testing.SetRealm(testing.NewUserRealm(caller))
	admin.AcceptAdmin(cross(cur))
	abt.Mint(cross(cur), caller, 10)
	abt.SetFrozen(cross(cur), true) // No event for the initial value.
	abt.SetFrozen(cross(cur), false)
	abt.SetFrozen(cross(cur), false) // No duplicate event.
	abt.SetFrozen(cross(cur), true)
	println(abt.TotalSupply(), abt.IsFrozen())
}

// Output:
// 10 true

// Events:
// [
//   {
//     "type": "TransferAdmin",
//     "attrs": [
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1v938g3tkv4h8gstyd45kuh6lta047h6lx2s576"
//       }
//     ],
//     "pkg_path": "gno.land/r/akkadia/beta/admin"
//   },
//   {
//     "type": "AcceptAdmin",
//     "attrs": [
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1v938g3tkv4h8gstyd45kuh6lta047h6lx2s576"
//       }
//     ],
//     "pkg_path": "gno.land/r/akkadia/beta/admin"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/akkadia/beta/abt.abt.0000000"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1v938g3tkv4h8gstyd45kuh6lta047h6lx2s576"
//       },
//       {
//         "key": "value",
//         "value": "10"
//       }
//     ],
//     "pkg_path": "gno.land/p/nt/grc20/v0"
//   },
//   {
//     "type": "FrozenChanged",
//     "attrs": [
//       {
//         "key": "executor",
//         "value": "g1v938g3tkv4h8gstyd45kuh6lta047h6lx2s576"
//       },
//       {
//         "key": "previous",
//         "value": "true"
//       },
//       {
//         "key": "frozen",
//         "value": "false"
//       }
//     ],
//     "pkg_path": "gno.land/r/akkadia/beta/abt"
//   },
//   {
//     "type": "FrozenChanged",
//     "attrs": [
//       {
//         "key": "executor",
//         "value": "g1v938g3tkv4h8gstyd45kuh6lta047h6lx2s576"
//       },
//       {
//         "key": "previous",
//         "value": "false"
//       },
//       {
//         "key": "frozen",
//         "value": "true"
//       }
//     ],
//     "pkg_path": "gno.land/r/akkadia/beta/abt"
//   }
// ]
