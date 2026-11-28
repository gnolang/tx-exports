package verdict2

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"math/overflow"
)

func Bet(cur realm, marketID uint64, yes bool) {
	assertDirectUserCall(cur)
	runtime.AssertOriginCall()
	placeBet(cur, marketID, yes)
}

// Keep validation separate: the pinned test runtime counts helper frames around AssertOriginCall.
func placeBet(cur realm, marketID uint64, yes bool) {
	market, ok := marketByID(marketID)
	if !ok {
		panic("market not found")
	}
	assertOpenBeforeClose(market)

	// The VM credits OriginSend before execution; Bet must not collect it again.
	amount := requireSinglePositiveUgnot()
	bettor := cur.Previous().Address()
	position, _ := positionByIDAndAddress(marketID, bettor)
	assertPoolAdditionSafe(market, yes, amount)
	assertPositionAdditionSafe(position, yes, amount)
	assertActivityIDSafe(market)

	market.NextActivityID++
	applyBetToPositionAndPool(market, bettor, yes, amount)
	appendActivity(market, bettor, yes, amount)
}

func assertDirectUserCall(cur realm) {
	requireDirectUserCall(0, cur)
}

func assertOpenBeforeClose(market Market) {
	switch market.Status {
	case MarketOpen:
	case MarketResolved:
		panic("market closed")
	default:
		panic("unknown market status")
	}
	if runtime.ChainHeight() >= market.CloseHeight {
		panic("market closed")
	}
}

func requireSinglePositiveUgnot() int64 {
	coins := unsafe.OriginSend()
	if len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount <= 0 {
		panic("invalid attached stake")
	}
	return coins[0].Amount
}

func assertPoolAdditionSafe(market Market, yes bool, amount int64) {
	combinedPool, ok := overflow.Add64(market.YesPool, market.NoPool)
	if !ok {
		panic("pool overflow")
	}
	if _, ok := overflow.Add64(combinedPool, amount); !ok {
		panic("pool overflow")
	}
	selectedPool := market.NoPool
	if yes {
		selectedPool = market.YesPool
	}
	if _, ok := overflow.Add64(selectedPool, amount); !ok {
		panic("pool overflow")
	}
}

func assertPositionAdditionSafe(position Position, yes bool, amount int64) {
	selectedStake := position.NoStake
	if yes {
		selectedStake = position.YesStake
	}
	if _, ok := overflow.Add64(selectedStake, amount); !ok {
		panic("position overflow")
	}
}

func assertActivityIDSafe(market Market) {
	if market.NextActivityID == ^uint64(0) {
		panic("activity ID overflow")
	}
}

func applyBetToPositionAndPool(market Market, bettor address, yes bool, amount int64) {
	position, _ := positionByIDAndAddress(market.ID, bettor)
	if yes {
		market.YesPool += amount
		position.YesStake += amount
	} else {
		market.NoPool += amount
		position.NoStake += amount
	}
	markets.Set(marketKey(market.ID), market)
	positions.Set(positionKey(market.ID, bettor), position)
}

func appendActivity(market Market, bettor address, yes bool, amount int64) {
	activity := Activity{
		ID:       market.NextActivityID,
		MarketID: market.ID,
		Bettor:   bettor,
		Side:     yes,
		Stake:    amount,
		Height:   runtime.ChainHeight(),
	}
	activities.Set(activityKey(market.ID, activity.ID), activity)
}
