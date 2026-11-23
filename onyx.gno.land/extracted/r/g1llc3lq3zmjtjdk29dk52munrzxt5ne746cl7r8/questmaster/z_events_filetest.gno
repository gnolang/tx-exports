// PKGPATH: gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster/filetests/z_events_filetest

// Every state change emits one event with the quest id, the acting address
// and, where money moves, the amount and recipient.
package z_events_filetest

import (
	"chain"
	"testing"

	"gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
)

const (
	poster  = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5") // test1
	builder = address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj") // test2
	other   = address("g1rzuwh5frve732k4futyw45y78rzuty4626zy6h") // test3
)

func post(cur realm, reward int64) uint64 {
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: reward}})
	testing.IssueCoins(chain.PackageAddress("gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"), chain.Coins{{Denom: "ugnot", Amount: reward}})
	id := questmaster.PostQuest(cross(cur), "Event quest", "", 1000)
	testing.SetOriginSend(nil)
	return id
}

func main(cur realm) {
	// quest 1: claim, unclaim, claim, release, claim, submit, reject, claim, submit, approve
	id := post(cur, 2_000_000)
	testing.SetRealm(testing.NewUserRealm(builder))
	questmaster.ClaimQuest(cross(cur), id)
	questmaster.UnclaimQuest(cross(cur), id)
	questmaster.ClaimQuest(cross(cur), id)
	testing.SkipHeights(1001)
	testing.SetRealm(testing.NewUserRealm(other))
	questmaster.ReleaseQuest(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(builder))
	questmaster.ClaimQuest(cross(cur), id)
	questmaster.SubmitWork(cross(cur), id, "https://example.com/1")
	testing.SetRealm(testing.NewUserRealm(poster))
	questmaster.RejectWork(cross(cur), id, "needs tests")
	testing.SetRealm(testing.NewUserRealm(builder))
	questmaster.ClaimQuest(cross(cur), id)
	questmaster.SubmitWork(cross(cur), id, "https://example.com/2")
	testing.SetRealm(testing.NewUserRealm(poster))
	questmaster.ApproveWork(cross(cur), id)

	// quest 2: cancel with refund
	id2 := post(cur, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(poster))
	questmaster.CancelQuest(cross(cur), id2)

	// quest 3: payout after the review window
	id3 := post(cur, 3_000_000)
	testing.SetRealm(testing.NewUserRealm(builder))
	questmaster.ClaimQuest(cross(cur), id3)
	questmaster.SubmitWork(cross(cur), id3, "https://example.com/3")
	testing.SkipHeights(172_801)
	questmaster.ClaimPayout(cross(cur), id3)

	// quest 4: claimed, closed by the poster, unclaimed -> refund
	id4 := post(cur, 4_000_000)
	testing.SetRealm(testing.NewUserRealm(builder))
	questmaster.ClaimQuest(cross(cur), id4)
	testing.SetRealm(testing.NewUserRealm(poster))
	questmaster.CancelQuest(cross(cur), id4)
	testing.SetRealm(testing.NewUserRealm(builder))
	questmaster.UnclaimQuest(cross(cur), id4)

	t := questmaster.GetTotals()
	println(t.Posted, t.Locked, t.Paid, t.Refunded)
}

// Output:
// 10000000 0 5000000 5000000

// Events:
// [
//   {
//     "type": "QuestPosted",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "amount",
//         "value": "2000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestClaimed",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestUnclaimed",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestClaimed",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestReleased",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1rzuwh5frve732k4futyw45y78rzuty4626zy6h"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestClaimed",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "WorkSubmitted",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "WorkRejected",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "builder",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestClaimed",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "WorkSubmitted",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestPaid",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       },
//       {
//         "key": "actor",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "to",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "amount",
//         "value": "2000000"
//       },
//       {
//         "key": "how",
//         "value": "approved"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestPosted",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "2"
//       },
//       {
//         "key": "actor",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "amount",
//         "value": "1000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestCancelled",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "2"
//       },
//       {
//         "key": "actor",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "to",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "amount",
//         "value": "1000000"
//       },
//       {
//         "key": "how",
//         "value": "open"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestPosted",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "3"
//       },
//       {
//         "key": "actor",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "amount",
//         "value": "3000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestClaimed",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "3"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "WorkSubmitted",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "3"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestPaid",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "3"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "to",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "amount",
//         "value": "3000000"
//       },
//       {
//         "key": "how",
//         "value": "timeout"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestPosted",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "4"
//       },
//       {
//         "key": "actor",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "amount",
//         "value": "4000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestClaimed",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "4"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestClosing",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "4"
//       },
//       {
//         "key": "actor",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestUnclaimed",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "4"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   },
//   {
//     "type": "QuestCancelled",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "4"
//       },
//       {
//         "key": "actor",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "to",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "amount",
//         "value": "4000000"
//       },
//       {
//         "key": "how",
//         "value": "unclaimed"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster"
//   }
// ]
