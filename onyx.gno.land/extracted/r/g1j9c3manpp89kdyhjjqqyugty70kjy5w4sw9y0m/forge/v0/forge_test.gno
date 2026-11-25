package forge

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

// NOTE: testing.SetRealm/SetOriginCaller mutate the cur of the frame that
// calls them, and cross(cur) hands that same realm value to the callee as
// its Previous(). So every crossing call below is preceded by a SetRealm
// in the same function frame — never inside a t.Run closure or a
// non-crossing helper, where the override would land on the wrong frame.

// resetMeta clears per-player meta state (cooldowns, renown, leaderboard)
// between tests; token balances are isolated by using fresh addresses.
func resetMeta() {
	lastGather = avl.Tree{}
	renown = avl.Tree{}
	topTen = nil
}

func balOf(t *testing.T, addr address, id string) int64 {
	b, err := token.BalanceOf(addr, grc1155.TokenID(id))
	urequire.NoError(t, err)
	return b
}

// craftAs is a crossing helper: it must receive cur via cross() so that
// the SetRealm below mutates the same frame whose cur is passed on to
// Craft. Mints enough ore for n ingot crafts, then crafts them.
func craftAs(cur realm, t *testing.T, name string, n int) address {
	player := testutils.TestAddress(name)
	urequire.NoError(t, ledger.Mint(player, "ore", int64(2*n)))
	testing.SetRealm(testing.NewUserRealm(player))
	for i := 0; i < n; i++ {
		Craft(cross(cur), "ingot")
	}
	return player
}

func TestGather(cur realm, t *testing.T) {
	resetMeta()
	player := testutils.TestAddress("forger-gather")

	// First gather at height 100 pays out 2 wood + 1 ore.
	testing.SetHeight(100)
	testing.SetRealm(testing.NewUserRealm(player))
	Gather(cross(cur))
	uassert.Equal(t, int64(2), balOf(t, player, "wood"))
	uassert.Equal(t, int64(1), balOf(t, player, "ore"))

	// Five blocks later the cooldown still has five to run.
	testing.SetHeight(105)
	uassert.AbortsContains(t, cur, "still settling", func() {
		Gather(cross(cur))
	})
	uassert.Equal(t, int64(2), balOf(t, player, "wood"))

	// At height 110 the cooldown has elapsed and gathering pays again.
	testing.SetHeight(110)
	Gather(cross(cur))
	uassert.Equal(t, int64(4), balOf(t, player, "wood"))
	uassert.Equal(t, int64(2), balOf(t, player, "ore"))

	// A code realm calling on a user's behalf is refused.
	resetMeta()
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/gatherbot"))
	uassert.AbortsContains(t, cur, "direct player calls only", func() {
		Gather(cross(cur))
	})
}

func TestCraftRecipes(cur realm, t *testing.T) {
	resetMeta()

	// ingot: 2 ore -> 1 ingot, renown 1.
	ingotter := testutils.TestAddress("forger-ingot")
	urequire.NoError(t, ledger.Mint(ingotter, "ore", 2))
	testing.SetRealm(testing.NewUserRealm(ingotter))
	Craft(cross(cur), "ingot")
	uassert.Equal(t, int64(0), balOf(t, ingotter, "ore"))
	uassert.Equal(t, int64(1), balOf(t, ingotter, "ingot"))
	uassert.Equal(t, int64(1), renownScore(ingotter))

	// sword: 1 ingot + 2 wood -> 1 sword, renown 3.
	smith := testutils.TestAddress("forger-sword")
	urequire.NoError(t, ledger.MintBatch(smith,
		[]grc1155.TokenID{"ingot", "wood"}, []int64{1, 2}))
	testing.SetRealm(testing.NewUserRealm(smith))
	Craft(cross(cur), "sword")
	uassert.Equal(t, int64(0), balOf(t, smith, "ingot"))
	uassert.Equal(t, int64(0), balOf(t, smith, "wood"))
	uassert.Equal(t, int64(1), balOf(t, smith, "sword"))
	uassert.Equal(t, int64(3), renownScore(smith))

	// shield: 1 ingot + 3 wood -> 1 shield, renown 3.
	buckler := testutils.TestAddress("forger-shield")
	urequire.NoError(t, ledger.MintBatch(buckler,
		[]grc1155.TokenID{"ingot", "wood"}, []int64{1, 3}))
	testing.SetRealm(testing.NewUserRealm(buckler))
	Craft(cross(cur), "shield")
	uassert.Equal(t, int64(0), balOf(t, buckler, "ingot"))
	uassert.Equal(t, int64(0), balOf(t, buckler, "wood"))
	uassert.Equal(t, int64(1), balOf(t, buckler, "shield"))
	uassert.Equal(t, int64(3), renownScore(buckler))

	// Unknown recipe is refused before anything is touched.
	broke := testutils.TestAddress("forger-badrecipe")
	testing.SetRealm(testing.NewUserRealm(broke))
	uassert.AbortsContains(t, cur, "unknown recipe", func() {
		Craft(cross(cur), "dragonfire")
	})

	// Insufficient materials: refused, and no partial state remains.
	poor := testutils.TestAddress("forger-broke")
	urequire.NoError(t, ledger.Mint(poor, "wood", 1)) // sword needs 2
	testing.SetRealm(testing.NewUserRealm(poor))
	uassert.AbortsContains(t, cur, "not enough", func() {
		Craft(cross(cur), "sword")
	})
	uassert.Equal(t, int64(1), balOf(t, poor, "wood"))
	uassert.Equal(t, int64(0), balOf(t, poor, "ingot"))
	uassert.Equal(t, int64(0), balOf(t, poor, "sword"))
	uassert.Equal(t, int64(0), renownScore(poor))

	// A code realm cannot craft on a user's behalf either.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/craftbot"))
	uassert.AbortsContains(t, cur, "direct player calls only", func() {
		Craft(cross(cur), "ingot")
	})
}

func TestTransferAndBatch(cur realm, t *testing.T) {
	resetMeta()
	player := testutils.TestAddress("forger-trader")
	bob := testutils.TestAddress("forger-bob")
	urequire.NoError(t, ledger.MintBatch(player,
		[]grc1155.TokenID{"wood", "ore"}, []int64{5, 3}))

	testing.SetRealm(testing.NewUserRealm(player))

	// Transfer moves a single stack.
	Transfer(cross(cur), bob, "wood", 2)
	uassert.Equal(t, int64(3), balOf(t, player, "wood"))
	uassert.Equal(t, int64(2), balOf(t, bob, "wood"))

	// More than held is refused and moves nothing.
	uassert.AbortsContains(t, cur, "insufficient balance", func() {
		Transfer(cross(cur), bob, "wood", 99)
	})
	uassert.Equal(t, int64(3), balOf(t, player, "wood"))

	// An id outside the TokenID charset is refused by the library.
	uassert.AbortsContains(t, cur, "invalid token id", func() {
		Transfer(cross(cur), bob, "bad:id", 1)
	})

	// BatchTransfer moves several stacks at once.
	BatchTransfer(cross(cur), bob, "wood,ore", "1,2")
	uassert.Equal(t, int64(2), balOf(t, player, "wood"))
	uassert.Equal(t, int64(1), balOf(t, player, "ore"))
	uassert.Equal(t, int64(3), balOf(t, bob, "wood"))
	uassert.Equal(t, int64(2), balOf(t, bob, "ore"))

	// Malformed batches are all refused before any ledger write.
	uassert.AbortsContains(t, cur, "same number of entries", func() {
		BatchTransfer(cross(cur), bob, "wood,ore", "1")
	})
	uassert.AbortsContains(t, cur, "empty item id", func() {
		BatchTransfer(cross(cur), bob, "wood,,ore", "1,1,1")
	})
	uassert.AbortsContains(t, cur, "invalid amount", func() {
		BatchTransfer(cross(cur), bob, "wood", "lots")
	})
	uassert.AbortsContains(t, cur, "invalid amount", func() {
		BatchTransfer(cross(cur), bob, "wood", "0")
	})

	// Nothing moved during the refused batches.
	uassert.Equal(t, int64(2), balOf(t, player, "wood"))
	uassert.Equal(t, int64(1), balOf(t, player, "ore"))
	uassert.Equal(t, int64(3), balOf(t, bob, "wood"))
	uassert.Equal(t, int64(2), balOf(t, bob, "ore"))
}

func TestSetApprovalForAll(cur realm, t *testing.T) {
	resetMeta()
	player := testutils.TestAddress("forger-approver")
	operator := testutils.TestAddress("forger-operator")

	testing.SetRealm(testing.NewUserRealm(player))
	SetApprovalForAll(cross(cur), operator, true)
	uassert.True(t, token.IsApprovedForAll(player, operator))

	SetApprovalForAll(cross(cur), operator, false)
	uassert.False(t, token.IsApprovedForAll(player, operator))

	// The zero address is not a valid operator.
	uassert.AbortsContains(t, cur, "invalid address", func() {
		SetApprovalForAll(cross(cur), address(""), true)
	})
}

func TestLeaderboard(cur realm, t *testing.T) {
	resetMeta()

	// low crafts 1 ingot (renown 1), mid 2 (renown 2), high 3 (renown 3).
	low := craftAs(cross(cur), t, "forger-lb-low", 1)
	mid := craftAs(cross(cur), t, "forger-lb-mid", 2)
	high := craftAs(cross(cur), t, "forger-lb-high", 3)

	uassert.Equal(t, 3, len(topTen))
	uassert.Equal(t, high, topTen[0].addr)
	uassert.Equal(t, int64(3), topTen[0].score)
	uassert.Equal(t, mid, topTen[1].addr)
	uassert.Equal(t, int64(2), topTen[1].score)
	uassert.Equal(t, low, topTen[2].addr)
	uassert.Equal(t, int64(1), topTen[2].score)

	// Twelve more single-ingot crafters join; the board caps at ten.
	for i := 0; i < 12; i++ {
		craftAs(cross(cur), t, "forger-lb-fill"+strconv.Itoa(i), 1)
	}
	uassert.Equal(t, leaderboardSize, len(topTen))

	// Every adjacent pair honours score-desc, address-asc ordering.
	for i := 1; i < len(topTen); i++ {
		ordered := topTenBetter(topTen[i-1], topTen[i]) ||
			(topTen[i-1].score == topTen[i].score &&
				topTen[i-1].addr.String() < topTen[i].addr.String())
		uassert.True(t, ordered)
	}
	// The three-ingot leader is still on top.
	uassert.Equal(t, int64(3), topTen[0].score)

	// The lowest board entry crafts two more ingots and climbs to renown 3.
	last := topTen[len(topTen)-1].addr
	urequire.NoError(t, ledger.Mint(last, "ore", 4))
	testing.SetRealm(testing.NewUserRealm(last))
	Craft(cross(cur), "ingot")
	Craft(cross(cur), "ingot")

	found := -1
	for i, e := range topTen {
		if e.addr == last {
			found = i
		}
	}
	uassert.True(t, found >= 0)
	uassert.True(t, topTen[found].score >= int64(3))
}

func TestRenderPages(t *testing.T) {
	player := testutils.TestAddress("forger-render")
	urequire.NoError(t, ledger.MintBatch(player,
		[]grc1155.TokenID{"wood", "ore"}, []int64{4, 2}))

	// Home: header, play links, catalog, recipes, leaderboard, inv hint.
	out := Render("")
	uassert.True(t, strings.Contains(out, "# The Tavern Forge"))
	uassert.True(t, strings.Contains(out, "$help&func=Gather"))
	uassert.True(t, strings.Contains(out, "$help&func=Craft&recipe=sword"))
	uassert.True(t, strings.Contains(out, "$help&func=Craft&recipe=ingot"))
	uassert.True(t, strings.Contains(out, "$help&func=Craft&recipe=shield"))
	uassert.True(t, strings.Contains(out, "Oak Wood"))
	uassert.True(t, strings.Contains(out, "Iron Ore"))
	uassert.True(t, strings.Contains(out, "Iron Ingot"))
	uassert.True(t, strings.Contains(out, "Iron Sword"))
	uassert.True(t, strings.Contains(out, "Oak Shield"))
	uassert.True(t, strings.Contains(out, "Hall of renown"))
	uassert.True(t, strings.Contains(out, ":inv/"))

	// Item page: display name, supply, how it is made and used.
	out = Render("item/sword")
	uassert.True(t, strings.Contains(out, "# Iron Sword"))
	uassert.True(t, strings.Contains(out, "Supply:"))
	uassert.True(t, strings.Contains(out, "Obtained by:"))
	uassert.True(t, strings.Contains(out, "1 x Iron Ingot + 2 x Oak Wood"))
	uassert.True(t, strings.Contains(out, "$help&func=Craft&recipe=sword"))

	// A gathered material points back at Gather.
	out = Render("item/wood")
	uassert.True(t, strings.Contains(out, "# Oak Wood"))
	uassert.True(t, strings.Contains(out, "$help&func=Gather"))

	// Unknown and empty ids get the same fixed message, never echoed.
	out = Render("item/dragonfire")
	uassert.True(t, strings.Contains(out, "no such item"))
	uassert.False(t, strings.Contains(out, "dragonfire"))
	out = Render("item/")
	uassert.True(t, strings.Contains(out, "no such item"))

	// Inventory lists display names and quantities, plus renown.
	out = Render("inv/" + player.String())
	uassert.True(t, strings.Contains(out, "Oak Wood"))
	uassert.True(t, strings.Contains(out, "Iron Ore"))
	uassert.True(t, strings.Contains(out, "| 4 |"))
	uassert.True(t, strings.Contains(out, "| 2 |"))
	uassert.True(t, strings.Contains(out, "Renown:"))

	// An empty satchel gets a friendly message and a Gather link.
	empty := testutils.TestAddress("forger-nobody")
	out = Render("inv/" + empty.String())
	uassert.True(t, strings.Contains(out, "satchel is empty"))
	uassert.True(t, strings.Contains(out, "$help&func=Gather"))

	// Invalid segments are refused with fixed messages, never echoed.
	out = Render("inv/not-an-address!!")
	uassert.True(t, strings.Contains(out, "Not an address"))
	uassert.False(t, strings.Contains(out, "not-an-address"))
	out = Render("inv/" + strings.ToUpper(player.String()))
	uassert.True(t, strings.Contains(out, "Not an address"))

	// An unknown page shape gets the fixed fallback.
	out = Render("a/b/c")
	uassert.True(t, strings.Contains(out, "nothing on that shelf"))
}
