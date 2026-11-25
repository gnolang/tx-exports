// PKGPATH: gno.land/r/demo/grc1155atomic

// Library writes return errors rather than panicking, and a returned error
// does not revert the transaction — so a failed batch must leave zero state
// changes and emit nothing. The failing batches below duplicate a tid so the
// per-id total is what overflows the balance; the ore entry that alone would
// have succeeded must not partially apply either. The final successful mint
// proves the event stream simply skipped the failures.
package grc1155atomic

import (
	"chain"

	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
)

func main(cur realm) {
	me := cur.Address()
	sink := chain.PackageAddress("sink")

	tok, led := grc1155.NewToken("Forge", "FORGE", "item/{id}", 0, cur)

	must(led.Mint(me, "wood", 10))
	must(led.Mint(me, "ore", 4))

	// wood needs 7+7=14 > 10 held: ErrInsufficientBalance, nothing moves,
	// nothing emits — including the ore leg that alone would fit.
	err := led.BatchTransferFrom(me, me, sink,
		[]grc1155.TokenID{"wood", "wood", "ore"}, []int64{7, 7, 1})
	println("dup batch err is ErrInsufficientBalance:", err == grc1155.ErrInsufficientBalance)

	// Second entry has an invalid id: ErrInvalidTokenID before any write.
	err = led.MintBatch(me, []grc1155.TokenID{"stone", "bad:id"}, []int64{1, 1})
	println("mint batch err is ErrInvalidTokenID:", err == grc1155.ErrInvalidTokenID)

	// A batch whose duplicate tids overflow int64 in aggregate is rejected
	// before any write as well.
	err = led.MintBatch(me, []grc1155.TokenID{"gem", "gem"},
		[]int64{int64(^uint64(0) >> 1), 1})
	println("sum overflow err is ErrOverflow:", err == grc1155.ErrOverflow)

	wood, _ := tok.BalanceOf(me, "wood")
	ore, _ := tok.BalanceOf(me, "ore")
	stone, _ := tok.BalanceOf(me, "stone")
	gem, _ := tok.BalanceOf(me, "gem")
	sinkWood, _ := tok.BalanceOf(sink, "wood")
	sinkOre, _ := tok.BalanceOf(sink, "ore")
	println("me wood:", wood, "ore:", ore, "stone:", stone, "gem:", gem)
	println("sink wood:", sinkWood, "ore:", sinkOre)
	println("wood supply:", tok.TotalSupply("wood"))
	println("exists stone:", tok.Exists("stone"), "exists gem:", tok.Exists("gem"))

	// A valid op afterwards emits normally.
	must(led.Mint(me, "stone", 1))
	println("done")
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// Output:
// dup batch err is ErrInsufficientBalance: true
// mint batch err is ErrInvalidTokenID: true
// sum overflow err is ErrOverflow: true
// me wood: 10 ore: 4 stone: 0 gem: 0
// sink wood: 0 ore: 0
// wood supply: 10
// exists stone: false exists gem: false
// done

// Events:
// [
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155atomic.FORGE"
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
//         "value": "gno.land/r/demo/grc1155atomic.FORGE"
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
//         "value": "g1rr530wgyp50ud2d5yg7adsynrfkh2mgpawcgwp"
//       },
//       {
//         "key": "id",
//         "value": "wood"
//       },
//       {
//         "key": "value",
//         "value": "10"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "TransferSingle",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155atomic.FORGE"
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
//         "value": "g1rr530wgyp50ud2d5yg7adsynrfkh2mgpawcgwp"
//       },
//       {
//         "key": "id",
//         "value": "ore"
//       },
//       {
//         "key": "value",
//         "value": "4"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   },
//   {
//     "type": "TransferSingle",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc1155atomic.FORGE"
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
//         "value": "g1rr530wgyp50ud2d5yg7adsynrfkh2mgpawcgwp"
//       },
//       {
//         "key": "id",
//         "value": "stone"
//       },
//       {
//         "key": "value",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
//   }
// ]
