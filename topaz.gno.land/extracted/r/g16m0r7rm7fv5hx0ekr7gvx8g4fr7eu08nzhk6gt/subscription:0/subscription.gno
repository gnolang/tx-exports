package subscription

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type Subscription struct {
	ID              int64
	Payer           address
	Payee           address
	AmountPerPeriod int64
	PeriodBlocks    int64
	Balance         int64
	NextDueHeight   int64
	Active          bool
}

var (
	subscriptions = avl.NewTree()
	nextSubID     int64
)

func CreateSubscription(cur realm, payee address, amountPerPeriod int64, periodBlocks int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("subscription: only direct user calls can create a subscription")
	}
	if amountPerPeriod <= 0 {
		panic("subscription: amountPerPeriod must be positive")
	}
	if periodBlocks <= 0 {
		panic("subscription: periodBlocks must be positive")
	}

	payer := cur.Previous().Address()
	if payee == payer {
		panic("subscription: payee cannot be the same as payer")
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount < amountPerPeriod {
		panic("subscription: initial funding must cover at least one period")
	}

	nowHeight := runtime.ChainHeight()

	nextSubID++
	id := nextSubID

	s := &Subscription{
		ID:              id,
		Payer:           payer,
		Payee:           payee,
		AmountPerPeriod: amountPerPeriod,
		PeriodBlocks:    periodBlocks,
		Balance:         amount,
		NextDueHeight:   nowHeight + periodBlocks,
		Active:          true,
	}

	subscriptions.Set(itoa(id), s)
	return id
}

func TopUp(cur realm, subID int64) {
	if !cur.Previous().IsUserCall() {
		panic("subscription: only direct user calls can top up")
	}

	s := mustGetSub(subID)
	caller := cur.Previous().Address()

	if caller != s.Payer {
		panic("subscription: only the payer can top up")
	}
	if !s.Active {
		panic("subscription: subscription is not active")
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("subscription: top-up amount must be positive")
	}

	s.Balance += amount
}

func Withdraw(cur realm, subID int64) {
	if !cur.Previous().IsUserCall() {
		panic("subscription: only direct user calls can withdraw")
	}

	s := mustGetSub(subID)
	caller := cur.Previous().Address()

	if caller != s.Payee {
		panic("subscription: only the payee can withdraw")
	}
	if !s.Active {
		panic("subscription: subscription is not active")
	}

	nowHeight := runtime.ChainHeight()
	if nowHeight < s.NextDueHeight {
		panic("subscription: no period is due yet")
	}

	elapsedPeriods := (nowHeight-s.NextDueHeight)/s.PeriodBlocks + 1
	affordablePeriods := s.Balance / s.AmountPerPeriod
	if affordablePeriods == 0 {
		panic("subscription: insufficient balance, subscription needs a top-up")
	}

	periodsToPay := elapsedPeriods
	if affordablePeriods < periodsToPay {
		periodsToPay = affordablePeriods
	}

	owed := periodsToPay * s.AmountPerPeriod

	s.Balance -= owed
	s.NextDueHeight += periodsToPay * s.PeriodBlocks

	payout(cur, s.Payee, owed)
}

func CancelSubscription(cur realm, subID int64) {
	if !cur.Previous().IsUserCall() {
		panic("subscription: only direct user calls can cancel")
	}

	s := mustGetSub(subID)
	caller := cur.Previous().Address()

	if caller != s.Payer {
		panic("subscription: only the payer can cancel")
	}
	if !s.Active {
		panic("subscription: subscription is already inactive")
	}

	refund := s.Balance

	s.Active = false
	s.Balance = 0

	if refund > 0 {
		payout(cur, s.Payer, refund)
	}
}

func mustGetSub(subID int64) *Subscription {
	raw := subscriptions.Get(itoa(subID))
	if raw == nil {
		panic("subscription: subscription not found")
	}
	s, ok := raw.(*Subscription)
	if !ok {
		panic("subscription: internal error, corrupted subscription entry")
	}
	return s
}

func payout(cur realm, to address, amount int64) {
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	have := b.GetCoins(realmAddr).AmountOf("ugnot")
	if have < amount {
		panic("subscription: internal invariant violation, insufficient realm balance for payout")
	}

	b.SendCoins(realmAddr, to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func itoa(i int64) string {
	return ufmt.Sprintf("%d", i)
}

func GetSubPayer(subID int64) address {
	return mustGetSub(subID).Payer
}

func GetSubPayee(subID int64) address {
	return mustGetSub(subID).Payee
}

func GetSubBalance(subID int64) int64 {
	return mustGetSub(subID).Balance
}

func GetSubNextDueHeight(subID int64) int64 {
	return mustGetSub(subID).NextDueHeight
}

func GetSubAmountPerPeriod(subID int64) int64 {
	return mustGetSub(subID).AmountPerPeriod
}

func IsSubActive(subID int64) bool {
	return mustGetSub(subID).Active
}
