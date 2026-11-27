package jointv1

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
	villagers "gno.land/r/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/villagersv1"
)

// GNOT shop. Gold is not involved: a sale splits ugnot between the live
// season pot and the treasury. The pack seed mixes the block height, a
// counter and the buyer. It is weak and the buyer can steer it by choosing
// the block, the same class of randomness as the daily event seed. Traits
// from a pack are cosmetic.

const (
	ItemNeon = "neon"
	ItemFloor = "floor"
	ItemPack = "pack"

	PriceNeonUgnot  int64 = 2_000_000
	PriceFloorUgnot int64 = 5_000_000
	PricePackUgnot  int64 = 3_000_000

	// FloorSeatsBonus is the seats a floor adds, once per pub.
	FloorSeatsBonus int64 = 3
)

// ShopPrice returns the ugnot price of a shop item, or 0 when item is unknown.
func ShopPrice(item string) int64 {
	switch item {
	case ItemNeon:
		return PriceNeonUgnot
	case ItemFloor:
		return PriceFloorUgnot
	case ItemPack:
		return PricePackUgnot
	}
	return 0
}

// PotNow is the live season pot in ugnot (not the frozen snapshot).
func PotNow() int64 { return potUgnot }

// TreasuryNow is the ugnot the treasury address may withdraw.
func TreasuryNow() int64 { return treasuryUgnot }

// Treasury is the address allowed to withdraw, or empty when unset.
func Treasury() address { return treasuryAddr }

// BuyItem sells item to the caller for exactly its ugnot price. Neon and a
// floor require a pub that does not already have them. A pack mints one
// villager to the buyer; any user may buy one. The price then splits into
// the live pot and the treasury. Every check runs before a write or a mint:
// a panic in the test VM does not roll attached coins back.
func BuyItem(cur realm, item string) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("town: must be a direct user call")
	}
	assertNotPaused()
	sent := unsafe.OriginSend()
	if len(sent) != 1 {
		panic("town: send exactly one coin")
	}
	if sent[0].Denom != "ugnot" {
		panic("town: only ugnot")
	}
	price := ShopPrice(item)
	if price == 0 {
		panic("town: unknown item")
	}
	if sent[0].Amount != price {
		panic("town: wrong amount")
	}
	buyer := prev.Address()
	switch item {
	case ItemNeon, ItemFloor:
		t := mustTavern(buyer.String())
		assertPub(t)
		if item == ItemNeon {
			if t.HasNeon {
				panic("town: already has neon")
			}
			t.HasNeon = true
		} else {
			if t.HasFloor {
				panic("town: already has floor")
			}
			t.Seats += FloorSeatsBonus
			t.HasFloor = true
			reweigh(t, t.PriceCg) // seats change the pub's weight
		}
	case ItemPack:
		// Height, the per-sale counter and the buyer. Weak: a buyer who
		// waits for a block they like can steer the seed.
		seed := townmath.Mix(uint64(runtime.ChainHeight()) ^ packCounter ^ foldAddr(buyer))
		packCounter++
		villagers.MintFor(cross(cur), buyer, seed, CurrentGameHour())
	default:
		panic("town: unknown item")
	}
	pot, tre := townmath.SplitPayment(sent[0].Amount, params.PotBps)
	potUgnot += pot
	treasuryUgnot += tre
}

// WithdrawTreasury sends the whole treasury balance to the treasury address
// and only to them. The balance is checked before the accounting is cleared,
// then the accounting is cleared before the send, so a second withdraw in
// the same call cannot pay twice and a short realm does not wipe the books
// (a panic in the test VM would not roll that write back).
func WithdrawTreasury(cur realm) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("town: must be a direct user call")
	}
	assertNoSend()
	if treasuryAddr == "" || prev.Address() != treasuryAddr {
		panic("town: treasury only")
	}
	amt := treasuryUgnot
	if amt == 0 {
		panic("town: nothing to withdraw")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if bk.GetCoin(cur.Address(), "ugnot") < amt {
		panic("town: insufficient realm balance")
	}
	treasuryUgnot = 0
	bk.SendCoins(cur.Address(), prev.Address(), chain.NewCoins(chain.NewCoin("ugnot", amt)))
}

// foldAddr XORs an address string as little-endian 8-byte chunks. An empty
// address folds to 0. At most 16 chunks are read (128 bytes).
func foldAddr(a address) uint64 {
	s := a.String()
	n := len(s)
	if n > 128 {
		n = 128
	}
	var x uint64
	for i := 0; i < n; i += 8 { // at most 16 chunks
		var chunk uint64
		for j := 0; j < 8 && i+j < n; j++ {
			chunk |= uint64(s[i+j]) << (uint(j) * 8)
		}
		x ^= chunk
	}
	return x
}
