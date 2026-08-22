package subscription

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Plan defines a recurring billing tier that a provider offers.
type Plan struct {
	ID            int64
	Provider      address
	Name          string
	PricePerCycle int64
	CycleBlocks   int64
	Active        bool
}

// Sub tracks a subscriber's relationship to a plan.
type Sub struct {
	Subscriber   address
	PlanID       int64
	NextDueAt    int64
	Active       bool
}

var (
	plans   *avl.Tree // planID (string) -> *Plan
	subs    *avl.Tree // subscriber|planID (string) -> *Sub
	nextID  int64
)

func init() {
	plans = avl.NewTree()
	subs = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("subscription: must be a direct user call")
	}
	return cur.Previous().Address()
}

func planKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

func subKey(subscriber address, planID int64) string {
	return string(subscriber) + "|" + planKey(planID)
}

func getPlan(id int64) *Plan {
	key := planKey(id)
	if !plans.Has(key) {
		panic("subscription: plan not found")
	}
	raw := plans.Get(key)
	return raw.(*Plan)
}

// CreatePlan lets a provider register a new subscription plan.
func CreatePlan(cur realm, name string, pricePerCycle int64, cycleBlocks int64) int64 {
	caller := assertUserCall(cur)
	if pricePerCycle <= 0 {
		panic("subscription: pricePerCycle must be positive")
	}
	if cycleBlocks <= 0 {
		panic("subscription: cycleBlocks must be positive")
	}
	if name == "" {
		panic("subscription: name required")
	}

	id := nextID
	nextID++

	plans.Set(planKey(id), &Plan{
		ID:            id,
		Provider:      caller,
		Name:          name,
		PricePerCycle: pricePerCycle,
		CycleBlocks:   cycleBlocks,
		Active:        true,
	})
	return id
}

// DeactivatePlan lets the provider stop offering a plan to new subscribers.
// Existing subscribers are unaffected.
func DeactivatePlan(cur realm, planID int64) {
	caller := assertUserCall(cur)
	p := getPlan(planID)
	if caller != p.Provider {
		panic("subscription: only the provider can deactivate")
	}
	p.Active = false
}

// Subscribe starts a subscription and pays the first cycle up front.
func Subscribe(cur realm, planID int64) {
	caller := assertUserCall(cur)
	p := getPlan(planID)
	if !p.Active {
		panic("subscription: plan is not active")
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount != p.PricePerCycle {
		panic("subscription: must send exact price per cycle")
	}

	key := subKey(caller, planID)
	if subs.Has(key) {
		existing := subs.Get(key).(*Sub)
		if existing.Active {
			panic("subscription: already subscribed to this plan")
		}
	}

	now := runtime.ChainHeight()
	subs.Set(key, &Sub{
		Subscriber: caller,
		PlanID:     planID,
		NextDueAt:  now + p.CycleBlocks,
		Active:     true,
	})

	// Forward payment to provider immediately.
	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(realmAddr, p.Provider, chain.Coins{chain.NewCoin("ugnot", amount)})
}

// RenewSubscription lets a subscriber pay for their next cycle once due.
func RenewSubscription(cur realm, planID int64) {
	caller := assertUserCall(cur)
	p := getPlan(planID)

	key := subKey(caller, planID)
	if !subs.Has(key) {
		panic("subscription: no subscription found")
	}
	s := subs.Get(key).(*Sub)
	if !s.Active {
		panic("subscription: subscription is not active")
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount != p.PricePerCycle {
		panic("subscription: must send exact price per cycle")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(realmAddr, p.Provider, chain.Coins{chain.NewCoin("ugnot", amount)})

	s.NextDueAt = s.NextDueAt + p.CycleBlocks
}

// IsCurrent reports whether a subscriber's subscription is active and not overdue.
func IsCurrent(subscriber address, planID int64) bool {
	key := subKey(subscriber, planID)
	if !subs.Has(key) {
		return false
	}
	s := subs.Get(key).(*Sub)
	if !s.Active {
		return false
	}
	return runtime.ChainHeight() <= s.NextDueAt
}

// Cancel lets a subscriber end their subscription (no refund of the current cycle).
func Cancel(cur realm, planID int64) {
	caller := assertUserCall(cur)
	key := subKey(caller, planID)
	if !subs.Has(key) {
		panic("subscription: no subscription found")
	}
	s := subs.Get(key).(*Sub)
	s.Active = false
}

func Render(path string) string {
	out := "# Subscription Service\n\n"
	out += ufmt.Sprintf("Total plans: %d\n\n", plans.Size())
	plans.Iterate("", "", func(key string, value interface{}) bool {
		p := value.(*Plan)
		out += ufmt.Sprintf("## #%d: %s\n", p.ID, p.Name)
		out += ufmt.Sprintf("Price/cycle: %d ugnot | Cycle: %d blocks | Active: %t\n\n",
			p.PricePerCycle, p.CycleBlocks, p.Active)
		return false
	})
	return out
}
