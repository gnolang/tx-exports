// Package forge is the Tavern Forge demo realm for grc1155: a tavern with a
// forge out back where players gather wood and ore, smelt and shape them at
// the anvil, and trade the results. Player identity always comes from
// cur.Previous() — never unsafe — and every refused action panics so the
// transaction reverts cleanly.
package forge

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
	"gno.land/p/nt/avl/v0"
)

const (
	// gatherCooldown is the number of blocks between Gather calls per player.
	gatherCooldown = 10
	// leaderboardSize bounds the rendered renown board.
	leaderboardSize = 10
)

var (
	token      *grc1155.Token
	ledger     *grc1155.PrivateLedger
	userTeller grc1155.Teller

	// lastGather maps a player address to the chain height of their last
	// Gather; renown maps a player address to their all-time craft score.
	lastGather avl.Tree
	renown     avl.Tree
	// topTen is the bounded, score-sorted leaderboard — at most
	// leaderboardSize entries, maintained on every craft so Render never
	// has to sort the full player set.
	topTen []topEntry
)

type topEntry struct {
	addr  address
	score int64
}

// itemDef is one forge ware: a TokenID plus the static display copy shown on
// catalog and item pages. Nothing here is user-supplied.
type itemDef struct {
	id    string
	name  string
	desc  string
	useIn string
}

var items = []itemDef{
	{
		id:    "wood",
		name:  "Oak Wood",
		desc:  "Sturdy oak, split and stacked behind the tavern.",
		useIn: "Crafting Iron Sword and Oak Shield.",
	},
	{
		id:    "ore",
		name:  "Iron Ore",
		desc:  "Heavy iron ore, still wearing its crust.",
		useIn: "Smelted into Iron Ingots at the forge.",
	},
	{
		id:    "ingot",
		name:  "Iron Ingot",
		desc:  "A bar of smelted iron, hot off the anvil.",
		useIn: "Crafting Iron Sword and Oak Shield.",
	},
	{
		id:    "sword",
		name:  "Iron Sword",
		desc:  "A balanced blade, hung above every hearth in the tavern.",
		useIn: "A mark of renown — worth 3 on the leaderboard.",
	},
	{
		id:    "shield",
		name:  "Oak Shield",
		desc:  "A round shield of oak bound with iron.",
		useIn: "A mark of renown — worth 3 on the leaderboard.",
	},
}

// craftNeed is one recipe input: item id plus amount.
type craftNeed struct {
	id     string
	amount int64
}

// recipeDef is a static forge recipe: inputs burned, one output minted, and
// the renown awarded for finishing it.
type recipeDef struct {
	id     string
	out    string
	needs  []craftNeed
	renown int64
}

var recipes = []recipeDef{
	{"ingot", "ingot", []craftNeed{{"ore", 2}}, 1},
	{"sword", "sword", []craftNeed{{"ingot", 1}, {"wood", 2}}, 3},
	{"shield", "shield", []craftNeed{{"ingot", 1}, {"wood", 3}}, 3},
}

func init(cur realm) {
	token, ledger = grc1155.NewToken("Tavern Forge", "FORGE",
		"/r/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/forge/v0:item/{id}", 0, cur)
	userTeller = ledger.CallerTeller()
}

// callerOrPanic resolves the acting player and refuses anything that is not
// a direct user call — Gather and Craft are player actions, so an intermediate
// realm must not reach them on a user's behalf.
func callerOrPanic(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("forge: this action is for direct player calls only")
	}
	return prev.Address()
}

// playerOrSelf resolves the acting account for token movements: any caller is
// welcome, and the CallerTeller spends only what that account owns or was
// approved for.
func playerOrSelf(cur realm) address {
	return cur.Previous().Address()
}

// Gather lets a player pick up 2 Oak Wood and 1 Iron Ore behind the tavern.
// Direct user calls only, once every gatherCooldown blocks per player.
func Gather(cur realm) {
	caller := callerOrPanic(cur)
	now := runtime.ChainHeight()

	if last := lastGather.Get(caller.String()); last != nil {
		remaining := gatherCooldown - (now - last.(int64))
		if remaining > 0 {
			panic("forge: the embers are still settling — gather again in " +
				strconv.FormatInt(remaining, 10) + " block(s)")
		}
	}

	if err := ledger.MintBatch(caller,
		[]grc1155.TokenID{"wood", "ore"},
		[]int64{2, 1}); err != nil {
		panic(err)
	}

	lastGather.Set(caller.String(), now)
}

// Craft burns a recipe's inputs and mints its output. All affordability is
// checked before any write, so a refused craft leaves nothing behind; a panic
// anywhere reverts the whole transaction regardless.
func Craft(cur realm, recipeID string) {
	caller := callerOrPanic(cur)
	r := findRecipe(recipeID)
	if r == nil {
		panic("forge: unknown recipe '" + recipeID + "'")
	}

	tids := make([]grc1155.TokenID, len(r.needs))
	amts := make([]int64, len(r.needs))
	for i, n := range r.needs {
		bal, err := token.BalanceOf(caller, grc1155.TokenID(n.id))
		if err != nil {
			panic(err)
		}
		if bal < n.amount {
			panic("forge: not enough " + itemName(n.id) + " — need " +
				strconv.FormatInt(n.amount, 10) + ", have " +
				strconv.FormatInt(bal, 10))
		}
		tids[i] = grc1155.TokenID(n.id)
		amts[i] = n.amount
	}

	if err := ledger.BurnBatch(caller, tids, amts); err != nil {
		panic(err)
	}
	if err := ledger.Mint(caller, grc1155.TokenID(r.out), 1); err != nil {
		panic(err)
	}

	addRenown(caller, r.renown)
}

// Transfer moves amount of one item from the caller to to.
func Transfer(cur realm, to address, id string, amount int64) {
	caller := playerOrSelf(cur)
	if err := userTeller.TransferFrom(0, cur, caller, to,
		grc1155.TokenID(id), amount); err != nil {
		panic("forge: " + err.Error())
	}
}

// BatchTransfer moves several stacks at once. ids and amounts are
// comma-separated strings (gnokey call args are strings); both lists must
// have the same length and every amount must be a positive integer.
func BatchTransfer(cur realm, to address, ids string, amounts string) {
	caller := playerOrSelf(cur)

	idParts := strings.Split(ids, ",")
	amtParts := strings.Split(amounts, ",")
	if len(idParts) != len(amtParts) {
		panic("forge: ids and amounts must list the same number of entries")
	}

	tids := make([]grc1155.TokenID, len(idParts))
	amts := make([]int64, len(amtParts))
	for i := range idParts {
		tid := strings.TrimSpace(idParts[i])
		if tid == "" {
			panic("forge: empty item id in batch")
		}
		tids[i] = grc1155.TokenID(tid)

		raw := strings.TrimSpace(amtParts[i])
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || n <= 0 {
			panic("forge: invalid amount '" + amtParts[i] + "'")
		}
		amts[i] = n
	}

	if err := userTeller.BatchTransferFrom(0, cur, caller, to, tids, amts); err != nil {
		panic("forge: " + err.Error())
	}
}

// SetApprovalForAll grants or revokes operator control over all of the
// caller's forge items.
func SetApprovalForAll(cur realm, operator address, approved bool) {
	if err := userTeller.SetApprovalForAll(0, cur, operator, approved); err != nil {
		panic("forge: " + err.Error())
	}
}

// addRenown credits points to addr's score and refreshes the bounded
// leaderboard. Scores only ever grow and only the crafter's entry changes,
// so re-sorting the <= leaderboardSize slice keeps it exactly the true top-N.
func addRenown(addr address, points int64) {
	if points <= 0 {
		return
	}

	key := addr.String()
	score := points
	if v := renown.Get(key); v != nil {
		score = v.(int64) + points
	}
	renown.Set(key, score)

	found := false
	for i := range topTen {
		if topTen[i].addr == addr {
			topTen[i].score = score
			found = true
			break
		}
	}
	if !found && (len(topTen) < leaderboardSize ||
		score > topTen[len(topTen)-1].score) {
		topTen = append(topTen, topEntry{addr: addr, score: score})
	}

	for i := 1; i < len(topTen); i++ {
		for j := i; j > 0 && topTenBetter(topTen[j], topTen[j-1]); j-- {
			topTen[j], topTen[j-1] = topTen[j-1], topTen[j]
		}
	}
	if len(topTen) > leaderboardSize {
		topTen = topTen[:leaderboardSize]
	}
}

// topTenBetter orders the board by score descending, address ascending as the
// deterministic tie-break.
func topTenBetter(a, b topEntry) bool {
	if a.score != b.score {
		return a.score > b.score
	}
	return a.addr.String() < b.addr.String()
}

func renownScore(addr address) int64 {
	if v := renown.Get(addr.String()); v != nil {
		return v.(int64)
	}
	return 0
}

func findItem(id string) *itemDef {
	for i := range items {
		if items[i].id == id {
			return &items[i]
		}
	}
	return nil
}

func findRecipe(id string) *recipeDef {
	for i := range recipes {
		if recipes[i].id == id {
			return &recipes[i]
		}
	}
	return nil
}

// recipeFor returns the recipe that produces item id, or nil for gathered
// materials.
func recipeFor(id string) *recipeDef {
	for i := range recipes {
		if recipes[i].out == id {
			return &recipes[i]
		}
	}
	return nil
}

// itemName maps an item id to its display name; unknown ids render as the
// raw id in backticks (the id charset is markdown-safe by construction).
func itemName(id string) string {
	if it := findItem(id); it != nil {
		return it.name
	}
	return "`" + id + "`"
}

// recipeText renders "2 x Iron Ore + 1 x Oak Wood -> 1 x Iron Ingot" style
// lines for tables and item pages.
func recipeText(r recipeDef) string {
	parts := make([]string, len(r.needs))
	for i, n := range r.needs {
		parts[i] = strconv.FormatInt(n.amount, 10) + " x " + itemName(n.id)
	}
	return strings.Join(parts, " + ") + " -> 1 x " + itemName(r.out)
}
