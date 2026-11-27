package competition

import (
	"chain/runtime"
	"time"
)

var equipped = make(map[address]int64)

type Cosmetic struct {
	ID int64
	Style string
	Price int64
	StartsAt int64
	EndsAt int64
	Enabled bool
}

type Purchase struct {
	Buyer address
	Item int64
	Amount int64
	Denom string
	PurchasedAt int64
}

type RevenueLedger struct {
	Shop int64
	DuelFees int64
	Deductions int64
	Realized int64
	Allocation int64
	Retained int64
}

func ListCosmetic(cur realm, style string, price, startsAt, endsAt int64) int64 {
	runtime.AssertOriginCall()
	requireAdmin(cur)
	now := time.Now().Unix()
	if startsAt == 0 {
		startsAt = now
	} else {
		require(startsAt > now, "invalid cosmetic schedule or price")
	}
	require(firstSeason > 0 && startsAt >= firstSeasonOpenedAt &&
		endsAt > startsAt && price > 0, "invalid cosmetic schedule or price")
	require(style == "azure" || style == "ember" || style == "frost", "unknown presentation-only livery")
	id := nextCosmeticID
	nextCosmeticID = checkedAdd(id, 1)
	catalog[id] = &Cosmetic{ID: id, Style: style, Price: price, StartsAt: startsAt, EndsAt: endsAt, Enabled: true}
	return id
}

func DisableCosmetic(cur realm, id int64) {
	runtime.AssertOriginCall()
	requireAdmin(cur)
	item := catalog[id]
	require(item != nil, "cosmetic not found")
	item.Enabled = false
}

func BuyCosmetic(cur realm, id int64) {
	runtime.AssertOriginCall()
	item := catalog[id]
	require(item != nil, "cosmetic not found")
	buyer := paidCaller(cur, item.Price)
	now := time.Now().Unix()
	require(!paused && item.available(now), "cosmetic unavailable")
	key := purchaseKey(buyer, id)
	// Rejection rolls back the incoming coin transfer, even after a lost client response.
	require(purchases[key] == nil, "cosmetic already owned")
	purchases[key] = &Purchase{Buyer: buyer, Item: id, Amount: item.Price, Denom: denom, PurchasedAt: now}
	recordRevenue(now, item.Price, 0)
}

func EquipCosmetic(cur realm, id int64) {
	runtime.AssertOriginCall()
	pilot := paidCaller(cur, 0)
	require(id == 0 || purchases[purchaseKey(pilot, id)] != nil, "cosmetic is not owned")
	equipped[pilot] = id
}

func (item *Cosmetic) available(now int64) bool {
	return item.Enabled && now >= item.StartsAt && now < item.EndsAt
}

func purchaseKey(pilot address, id int64) string {
	return string(pilot)+":"+decimal(id)
}

func recordRevenue(now, sale, fee int64) {
	id := weekID(now)
	require(firstSeason > 0 && id >= firstSeason && id >= nextSnapshot, "revenue week unavailable")
	ledger := &getSeason(id).Revenue
	previous := ledger.Retained
	ledger.record(sale, fee)
	retainedClaimable = checkedAdd(retainedClaimable, ledger.Retained-previous)
}

func (ledger *RevenueLedger) record(sale, fee int64) {
	ledger.Shop = checkedAdd(ledger.Shop, sale)
	ledger.DuelFees = checkedAdd(ledger.DuelFees, fee)
	ledger.Realized = checkedAdd(ledger.Shop, ledger.DuelFees)-ledger.Deductions
	ledger.Allocation = ledger.Realized/2
	ledger.Retained = ledger.Realized-ledger.Allocation
}
