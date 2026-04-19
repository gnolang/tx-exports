package poker

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"

	"gno.land/p/demo/poker"
)

// ----- State -----
var (
	tables      map[string]*poker.Table
	tableList   []string
	admin       address
	rakePercent int64
	rakePool    int64
	tableCount  int
)

func init() {
	tables = make(map[string]*poker.Table)
	admin = runtime.PreviousRealm().Address()
	rakePercent = 300 // 3% default
}

// ----- Lobby Functions -----

func CreateTable(cur realm, name string, smallBlind int64, bigBlind int64, minBet int64, maxBet int64, maxPlayers int, minBuyIn int64) string {
	caller := runtime.PreviousRealm().Address()

	if maxPlayers != 4 && maxPlayers != 6 {
		panic("maxPlayers must be 4 or 6")
	}
	if smallBlind <= 0 || bigBlind <= 0 || smallBlind > bigBlind {
		panic("invalid blind structure")
	}
	if minBet <= 0 || maxBet <= 0 || minBet > maxBet {
		panic("invalid bet limits")
	}
	if minBuyIn < bigBlind*10 {
		panic("minBuyIn must be at least 10x big blind")
	}

	tableCount++
	id := "table-" + poker.IntToStr(tableCount)

	table := &poker.Table{
		ID:         id,
		Name:       name,
		Creator:    caller.String(),
		Players:    make([]*poker.Player, 0),
		MaxPlayers: maxPlayers,
		SmallBlind: smallBlind,
		BigBlind:   bigBlind,
		MinBet:     minBet,
		MaxBet:     maxBet,
		MinBuyIn:   minBuyIn,
		MaxBuyIn:   minBuyIn * 10,
		State:      poker.StateWaiting,
	}

	tables[id] = table
	tableList = append(tableList, id)

	return id
}

// JoinTable joins an existing table. buyInAmount is in ugnot.
// The caller must send at least buyInAmount ugnot via --send flag.
func JoinTable(cur realm, tableID string, buyInAmount int64) {
	caller := runtime.PreviousRealm().Address()
	table := getTable(tableID)

	if len(table.Players) >= table.MaxPlayers {
		panic("table is full")
	}

	for _, p := range table.Players {
		if p.Address == caller.String() {
			panic("already at this table")
		}
	}

	if buyInAmount < table.MinBuyIn {
		panic("insufficient buy-in amount")
	}
	if buyInAmount > table.MaxBuyIn {
		panic("exceeds max buy-in")
	}

	player := &poker.Player{
		Address:   caller.String(),
		Chips:     buyInAmount,
		IsActive:  true,
		SeatIndex: len(table.Players),
	}

	table.Players = append(table.Players, player)
}

// LeaveTable sends remaining chips back to player wallet
func LeaveTable(cur realm, tableID string) {
	caller := runtime.PreviousRealm().Address()
	table := getTable(tableID)

	for i, p := range table.Players {
		if p.Address == caller.String() {
			if table.State != poker.StateWaiting && !p.HasFolded {
				p.HasFolded = true
			}

			// Send remaining chips back to player
			if p.Chips > 0 {
				b := banker.NewBanker(banker.BankerTypeRealmSend)
				sendCoins := chain.Coins{chain.NewCoin("ugnot", p.Chips)}
				pkgaddr := runtime.CurrentRealm().Address()
				b.SendCoins(pkgaddr, caller, sendCoins)
			}

			table.Players = append(table.Players[:i], table.Players[i+1:]...)

			for j := i; j < len(table.Players); j++ {
				table.Players[j].SeatIndex = j
			}

			if len(table.Players) < 2 && table.State != poker.StateWaiting {
				if len(table.Players) == 1 {
					remaining := table.Players[0]
					remaining.Chips += table.Pot
					table.Pot = 0
				}
				table.State = poker.StateWaiting
				table.Community = nil
			}

			return
		}
	}

	panic("player not found at this table")
}

// ----- Game Flow -----

func StartHand(cur realm, tableID string) {
	table := getTable(tableID)

	if len(table.Players) < 2 {
		panic("need at least 2 players to start")
	}
	if table.State != poker.StateWaiting {
		panic("hand already in progress")
	}

	deck := poker.NewDeck()
	seed := int64(table.HandCount)*31337 + 12345
	deck.Shuffle(seed)

	for _, p := range table.Players {
		p.HasFolded = false
		p.IsAllIn = false
		p.CurrentBet = 0
		cards := deck.Deal(2)
		p.Hand = [2]poker.Card{cards[0], cards[1]}
	}

	table.DeckSeed = seed
	table.Community = make([]poker.Card, 0)
	table.Pot = 0
	table.State = poker.StatePreFlop
	table.HandCount++

	numPlayers := len(table.Players)
	sbIdx := (table.DealerIdx + 1) % numPlayers
	bbIdx := (table.DealerIdx + 2) % numPlayers

	sb := table.SmallBlind
	bb := table.BigBlind

	table.Players[sbIdx].Chips -= sb
	table.Players[sbIdx].CurrentBet = sb
	table.Players[bbIdx].Chips -= bb
	table.Players[bbIdx].CurrentBet = bb
	table.Pot = sb + bb

	table.CurrentTurn = (bbIdx + 1) % numPlayers
}

func PlaceBet(cur realm, tableID string, amount int64) {
	caller := runtime.PreviousRealm().Address()
	table := getTable(tableID)
	player := getPlayerAt(table, caller.String())

	assertPlayerTurn(table, player)

	if amount <= 0 || amount > player.Chips {
		panic("invalid bet amount")
	}
	if amount > table.MaxBet {
		panic("exceeds max bet")
	}

	player.Chips -= amount
	player.CurrentBet += amount
	table.Pot += amount

	advanceTurn(table)
}

func Call(cur realm, tableID string) {
	caller := runtime.PreviousRealm().Address()
	table := getTable(tableID)
	player := getPlayerAt(table, caller.String())

	assertPlayerTurn(table, player)

	maxBet := getMaxCurrentBet(table)
	toCall := maxBet - player.CurrentBet

	if toCall <= 0 {
		panic("nothing to call, use Check instead")
	}

	if toCall > player.Chips {
		table.Pot += player.Chips
		player.CurrentBet += player.Chips
		player.Chips = 0
		player.IsAllIn = true
	} else {
		player.Chips -= toCall
		player.CurrentBet += toCall
		table.Pot += toCall
	}

	advanceTurn(table)
}

func Check(cur realm, tableID string) {
	caller := runtime.PreviousRealm().Address()
	table := getTable(tableID)
	player := getPlayerAt(table, caller.String())

	assertPlayerTurn(table, player)

	maxBet := getMaxCurrentBet(table)
	if player.CurrentBet < maxBet {
		panic("cannot check, there is an outstanding bet")
	}

	advanceTurn(table)
}

func Fold(cur realm, tableID string) {
	caller := runtime.PreviousRealm().Address()
	table := getTable(tableID)
	player := getPlayerAt(table, caller.String())

	assertPlayerTurn(table, player)

	player.HasFolded = true

	activePlayers := countActivePlayers(table)
	if activePlayers == 1 {
		for _, p := range table.Players {
			if !p.HasFolded {
				awardPot(table, p)
				return
			}
		}
	}

	advanceTurn(table)
}

func AllIn(cur realm, tableID string) {
	caller := runtime.PreviousRealm().Address()
	table := getTable(tableID)
	player := getPlayerAt(table, caller.String())

	assertPlayerTurn(table, player)

	amount := player.Chips
	player.CurrentBet += amount
	player.Chips = 0
	player.IsAllIn = true
	table.Pot += amount

	advanceTurn(table)
}

// ----- Admin Functions -----

func SetRakePercent(cur realm, percent int64) {
	caller := runtime.PreviousRealm().Address()
	if caller != admin {
		panic("only admin can set rake")
	}
	if percent < 0 || percent > 500 {
		panic("rake must be 0-500 (0-5%)")
	}
	rakePercent = percent
}

func WithdrawRake(cur realm) int64 {
	caller := runtime.PreviousRealm().Address()
	if caller != admin {
		panic("only admin can withdraw rake")
	}
	amount := rakePool
	rakePool = 0
	return amount
}

// ----- Query Functions -----

func GetTables() string {
	var sb strings.Builder
	sb.WriteString("[")
	for i, id := range tableList {
		t := tables[id]
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString("{")
		sb.WriteString(`"id":"` + t.ID + `"`)
		sb.WriteString(`,"name":"` + t.Name + `"`)
		sb.WriteString(`,"maxPlayers":` + poker.IntToStr(t.MaxPlayers))
		sb.WriteString(`,"currentPlayers":` + poker.IntToStr(len(t.Players)))
		sb.WriteString(`,"smallBlind":` + int64ToStr(t.SmallBlind))
		sb.WriteString(`,"bigBlind":` + int64ToStr(t.BigBlind))
		sb.WriteString(`,"minBet":` + int64ToStr(t.MinBet))
		sb.WriteString(`,"maxBet":` + int64ToStr(t.MaxBet))
		sb.WriteString(`,"minBuyIn":` + int64ToStr(t.MinBuyIn))
		sb.WriteString(`,"maxBuyIn":` + int64ToStr(t.MaxBuyIn))
		sb.WriteString(`,"pot":` + int64ToStr(t.Pot))
		sb.WriteString(`,"state":"` + t.State.String() + `"`)
		sb.WriteString("}")
	}
	sb.WriteString("]")
	return sb.String()
}

func GetTableState(tableID string) string {
	table := getTable(tableID)
	var sb strings.Builder
	sb.WriteString("{")
	sb.WriteString(`"id":"` + table.ID + `"`)
	sb.WriteString(`,"state":"` + table.State.String() + `"`)
	sb.WriteString(`,"pot":` + int64ToStr(table.Pot))
	sb.WriteString(`,"currentTurn":` + poker.IntToStr(table.CurrentTurn))
	sb.WriteString(`,"dealerIdx":` + poker.IntToStr(table.DealerIdx))
	sb.WriteString(`,"players":` + poker.IntToStr(len(table.Players)))
	sb.WriteString("}")
	return sb.String()
}

// ----- Internal Helpers -----

func getTable(id string) *poker.Table {
	table, ok := tables[id]
	if !ok {
		panic("table not found: " + id)
	}
	return table
}

func getPlayerAt(table *poker.Table, addr string) *poker.Player {
	for _, p := range table.Players {
		if p.Address == addr {
			return p
		}
	}
	panic("player not at this table")
}

func assertPlayerTurn(table *poker.Table, player *poker.Player) {
	if table.State == poker.StateWaiting || table.State == poker.StateShowdown {
		panic("not a betting round")
	}
	if player.HasFolded {
		panic("you have folded")
	}
	if player.SeatIndex != table.CurrentTurn {
		panic("not your turn")
	}
}

func getMaxCurrentBet(table *poker.Table) int64 {
	maxBet := int64(0)
	for _, p := range table.Players {
		if p.CurrentBet > maxBet {
			maxBet = p.CurrentBet
		}
	}
	return maxBet
}

func countActivePlayers(table *poker.Table) int {
	count := 0
	for _, p := range table.Players {
		if !p.HasFolded {
			count++
		}
	}
	return count
}

func advanceTurn(table *poker.Table) {
	numPlayers := len(table.Players)
	next := table.CurrentTurn
	for i := 0; i < numPlayers; i++ {
		next = (next + 1) % numPlayers
		p := table.Players[next]
		if !p.HasFolded && !p.IsAllIn {
			table.CurrentTurn = next
			return
		}
	}
	advanceRound(table)
}

func advanceRound(table *poker.Table) {
	for _, p := range table.Players {
		p.CurrentBet = 0
	}

	deck := poker.NewDeck()
	deck.Shuffle(table.DeckSeed + int64(table.State)*7919)
	deck.Deal(len(table.Players) * 2)

	switch table.State {
	case poker.StatePreFlop:
		cards := deck.Deal(3 + len(table.Community))
		table.Community = cards[len(cards)-3:]
		table.State = poker.StateFlop
	case poker.StateFlop:
		deck.Deal(len(table.Community))
		card := deck.DealOne()
		table.Community = append(table.Community, card)
		table.State = poker.StateTurn
	case poker.StateTurn:
		deck.Deal(len(table.Community))
		card := deck.DealOne()
		table.Community = append(table.Community, card)
		table.State = poker.StateRiver
	case poker.StateRiver:
		table.State = poker.StateShowdown
		resolveShowdown(table)
		return
	}

	table.CurrentTurn = (table.DealerIdx + 1) % len(table.Players)
	for i := 0; i < len(table.Players); i++ {
		idx := (table.CurrentTurn + i) % len(table.Players)
		if !table.Players[idx].HasFolded && !table.Players[idx].IsAllIn {
			table.CurrentTurn = idx
			return
		}
	}
}

func resolveShowdown(table *poker.Table) {
	var bestResult poker.HandResult
	var winner *poker.Player

	for _, p := range table.Players {
		if p.HasFolded {
			continue
		}
		result := poker.EvaluateHand(p.Hand, table.Community)
		if winner == nil || poker.CompareHandResults(result, bestResult) > 0 {
			bestResult = result
			winner = p
		}
	}

	if winner != nil {
		awardPot(table, winner)
	}
}

func awardPot(table *poker.Table, winner *poker.Player) {
	rake := (table.Pot * rakePercent) / 10000
	rakePool += rake

	winnings := table.Pot - rake
	winner.Chips += winnings
	table.Pot = 0
	table.RakeCollected += rake

	table.State = poker.StateWaiting
	table.DealerIdx = (table.DealerIdx + 1) % len(table.Players)
	table.Community = nil
}

func int64ToStr(n int64) string {
	return poker.IntToStr(int(n))
}
