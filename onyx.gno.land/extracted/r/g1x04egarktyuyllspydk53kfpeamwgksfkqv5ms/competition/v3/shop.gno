package competition

import (
	"chain/runtime"
	"time"
)

type Loadout struct {
	Paint, Wings, Engines, Tail int64
}

var equipped = make(map[address]Loadout)

func cosmeticSlot(style string) string {
	switch style {
	case "azure", "ember", "frost", "signal-red", "solar-gold", "glacier-blue", "arctic-white", "carbon-black":
		return "paint"
	case "broad-sweep", "short-sweep":
		return "wings"
	case "halo-exhaust", "ember-exhaust":
		return "engines"
	case "twin-scythe":
		return "tail"
	}
	return ""
}

func (loadout Loadout) item(slot string) int64 {
	switch slot {
	case "paint":
		return loadout.Paint
	case "wings":
		return loadout.Wings
	case "engines":
		return loadout.Engines
	case "tail":
		return loadout.Tail
	}
	return 0
}

func (loadout *Loadout) set(slot string, id int64) {
	switch slot {
	case "paint":
		loadout.Paint = id
	case "wings":
		loadout.Wings = id
	case "engines":
		loadout.Engines = id
	case "tail":
		loadout.Tail = id
	default:
		panic("unknown aircraft slot")
	}
}

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
	require(cosmeticSlot(style) != "", "unknown aircraft cosmetic")
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
	slot := "paint"
	if id != 0 {
		require(purchases[purchaseKey(pilot, id)] != nil, "cosmetic is not owned")
		slot = cosmeticSlot(catalog[id].Style)
	}
	equipSlot(pilot, slot, id)
}

func ResetCosmetic(cur realm, slot string) {
	runtime.AssertOriginCall()
	equipSlot(paidCaller(cur, 0), slot, 0)
}

func equipSlot(pilot address, slot string, id int64) {
	loadout := equipped[pilot]
	loadout.set(slot, id)
	equipped[pilot] = loadout
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
