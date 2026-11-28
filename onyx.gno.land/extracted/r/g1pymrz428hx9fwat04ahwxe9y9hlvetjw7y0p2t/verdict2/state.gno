package verdict2

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

var (
	markets      avl.Tree
	positions    avl.Tree
	activities   avl.Tree
	participants avl.Tree
	nextMarketID uint64
)

func orderedIDKey(id uint64) string {
	decimal := strconv.FormatUint(id, 10)
	return strings.Repeat("0", 20-len(decimal)) + decimal
}

func marketKey(id uint64) string {
	return orderedIDKey(id)
}

func positionKey(marketID uint64, bettor address) string {
	return marketKey(marketID) + ":" + bettor.String()
}

func activityKey(marketID, id uint64) string {
	return orderedIDKey(marketID) + ":" + orderedIDKey(id)
}

func participantKey(bettor address) string {
	return bettor.String()
}

func marketByID(id uint64) (Market, bool) {
	market, ok := markets.Get(marketKey(id)).(Market)
	return market, ok
}

func positionByIDAndAddress(marketID uint64, bettor address) (Position, bool) {
	position, ok := positions.Get(positionKey(marketID, bettor)).(Position)
	return position, ok
}

func activityByID(marketID, id uint64) (Activity, bool) {
	activity, ok := activities.Get(activityKey(marketID, id)).(Activity)
	return activity, ok
}

func participantByAddress(bettor address) (Participant, bool) {
	participant, ok := participants.Get(participantKey(bettor)).(Participant)
	return participant, ok
}
