// PKGPATH: gno.land/r/demo/grc1155events

// Every state change emits an event: NewToken on creation, TransferSingle
// for single mint/transfer/burn, TransferBatch for batch ops (mint/burn
// included, with empty from/to), ApprovalForAll on operator grants, and URI
// on template/override changes. Batch ids and values are comma-joined.
package grc1155events

import (
	"chain"

	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
)

func main(cur realm) {
	me := cur.Address()
	other := chain.PackageAddress("other")
	third := chain.PackageAddress("third")

	tok, led := grc1155.NewToken("Forge", "FORGE", "item/{id}", 0, cur)
	_ = tok

	must(led.Mint(me, "wood", 3))
	must(led.MintBatch(me, []grc1155.TokenID{"ore", "wood"}, []int64{2, 1}))
	must(led.SetApprovalForAll(me, other, true))
	must(led.TransferFrom(other, me, third, "wood", 1))
	must(led.BatchTransferFrom(other, me, third,
		[]grc1155.TokenID{"ore", "wood"}, []int64{1, 1}))
	must(led.SetURI("wood", "custom/{id}"))
	must(led.SetDefaultURI("tpl/{id}"))
	must(led.Burn(me, "wood", 1))
	must(led.BurnBatch(me, []grc1155.TokenID{"ore", "wood"}, []int64{1, 1}))

	println("done")
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// Output:
// done

// Events:
// [
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "name",
//         "value": "Forge"
//       },
//       {
//         "key": "symbol",
//         "value": "FORGE"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "TransferSingle",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "operator",
//         "value": ""
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g13x85kcqcez3d0e98hw48npkhxl95zxutum9z3l"
//       },
//       {
//         "key": "id",
//         "value": "wood"
//       },
//       {
//         "key": "value",
//         "value": "3"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "TransferBatch",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "operator",
//         "value": ""
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g13x85kcqcez3d0e98hw48npkhxl95zxutum9z3l"
//       },
//       {
//         "key": "ids",
//         "value": "ore,wood"
//       },
//       {
//         "key": "values",
//         "value": "2,1"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "ApprovalForAll",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "owner",
//         "value": "g13x85kcqcez3d0e98hw48npkhxl95zxutum9z3l"
//       },
//       {
//         "key": "to",
//         "value": "g13fsmhgszsqlqc0keqgevgw954k8wuj9f4vdyca"
//       },
//       {
//         "key": "approved",
//         "value": "true"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "TransferSingle",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "operator",
//         "value": "g13fsmhgszsqlqc0keqgevgw954k8wuj9f4vdyca"
//       },
//       {
//         "key": "from",
//         "value": "g13x85kcqcez3d0e98hw48npkhxl95zxutum9z3l"
//       },
//       {
//         "key": "to",
//         "value": "g10w4yk7qlms7sqemq2fwl6snfk5g0ewq2vnh4zn"
//       },
//       {
//         "key": "id",
//         "value": "wood"
//       },
//       {
//         "key": "value",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "TransferBatch",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "operator",
//         "value": "g13fsmhgszsqlqc0keqgevgw954k8wuj9f4vdyca"
//       },
//       {
//         "key": "from",
//         "value": "g13x85kcqcez3d0e98hw48npkhxl95zxutum9z3l"
//       },
//       {
//         "key": "to",
//         "value": "g10w4yk7qlms7sqemq2fwl6snfk5g0ewq2vnh4zn"
//       },
//       {
//         "key": "ids",
//         "value": "ore,wood"
//       },
//       {
//         "key": "values",
//         "value": "1,1"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "URI",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "id",
//         "value": "wood"
//       },
//       {
//         "key": "value",
//         "value": "custom/{id}"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "URI",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "value",
//         "value": "tpl/{id}"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "TransferSingle",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "operator",
//         "value": ""
//       },
//       {
//         "key": "from",
//         "value": "g13x85kcqcez3d0e98hw48npkhxl95zxutum9z3l"
//       },
//       {
//         "key": "to",
//         "value": ""
//       },
//       {
//         "key": "id",
//         "value": "wood"
//       },
//       {
//         "key": "value",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "TransferBatch",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155events.FORGE"
//       },
//       {
//         "key": "operator",
//         "value": ""
//       },
//       {
//         "key": "from",
//         "value": "g13x85kcqcez3d0e98hw48npkhxl95zxutum9z3l"
//       },
//       {
//         "key": "to",
//         "value": ""
//       },
//       {
//         "key": "ids",
//         "value": "ore,wood"
//       },
//       {
//         "key": "values",
//         "value": "1,1"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   }
// ]
