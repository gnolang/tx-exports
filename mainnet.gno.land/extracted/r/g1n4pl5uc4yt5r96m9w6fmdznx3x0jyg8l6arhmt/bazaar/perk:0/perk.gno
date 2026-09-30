package perk

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	col "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/c/bazaargens"
	factory "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/bazaarv5"
)

// Perk counts revealed, unlisted Bazaar Gens held in a wallet.
// Fee discount is the highest tier. Share weight is the sum.
// Mainnet staging retargets colPkg to c/bazaargens. Admin then SetGenesis
// on bazaarv5 so Buy sends the 11% protocol share here and NoteHolderDiscount
// accepts this realm. Sync must be called after mint, transfer, list, or reveal.
// Rarity stays unread until the collection reveals it.

const (
	pkgPath   = "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/perk"
	colPkg    = "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/c/bazaargens"
	native    = "ugnot"
	scale     = int64(1_000_000)
	maxSpan   = 20
	maxDelta  = int64(9_000_000_000_000) // delta * scale stays inside int64
)

type wallet struct {
	n25     int
	n50     int
	n75     int
	n100    int
	n125    int
	n150    int
	debt    int64
	accrued int64
}

var (
	wallets     avl.Tree
	tokenWho    avl.Tree
	tokenBps    avl.Tree
	totalWeight int64
	acc         int64
	accounted   int64
	self        address
)

func Sync(cur realm, id int) {
	requireUser(cur)
	if id < 1 {
		panic("perk: id")
	}
	syncID(cur, id)
}

func SyncSpan(cur realm, start, end int) {
	requireUser(cur)
	if start < 1 || end < start || end-start >= maxSpan {
		panic("perk: span")
	}
	for id := start; id <= end; id++ {
		syncID(cur, id)
	}
}

func Claim(cur realm) {
	caller := requireUser(cur)
	syncPot(cur)
	w := mustWallet(caller)
	settle(w)
	amt := w.accrued
	if amt <= 0 {
		panic("perk: nothing")
	}
	if amt > accounted {
		panic("perk: accounted")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if bk.GetCoins(self).AmountOf(native) < amt {
		panic("perk: funds")
	}
	w.accrued = 0
	accounted -= amt
	wallets.Set(caller.String(), w)
	bk.SendCoins(self, caller, chain.Coins{{Denom: native, Amount: amt}})
	chain.Emit("Claim", "owner", caller.String(), "amount", strconv.FormatInt(amt, 10))
}

func ShareWeight(owner string) int64 {
	w := load(owner)
	if w == nil {
		return 0
	}
	return shareOf(w)
}

func FeeDiscount(owner string) int64 {
	w := load(owner)
	if w == nil {
		return 0
	}
	return bestOf(w)
}

func TotalWeight() int64 {
	return totalWeight
}

func Render(_ string) string {
	return "# Bazaar perk\n\n- total weight: " + strconv.FormatInt(totalWeight, 10) + "\n- accounted: " + strconv.FormatInt(accounted, 10) + " ugnot\n"
}

func syncID(cur realm, id int) {
	who, bps := live(id)
	key := strconv.Itoa(id)
	oldWho := address("")
	oldBps := int64(0)
	if v := tokenWho.Get(key); v != nil {
		oldWho = v.(address)
	}
	if v := tokenBps.Get(key); v != nil {
		oldBps = v.(int64)
	}
	if oldWho == who && oldBps == bps {
		return
	}
	if oldBps > 0 && oldWho.IsValid() {
		addTier(cur, oldWho, oldBps, -1)
	}
	if bps > 0 && who.IsValid() {
		addTier(cur, who, bps, 1)
	}
	if bps == 0 || !who.IsValid() {
		tokenWho.Remove(key)
		tokenBps.Remove(key)
		chain.Emit("Sync", "id", key, "bps", "0")
		return
	}
	tokenWho.Set(key, who)
	tokenBps.Set(key, bps)
	chain.Emit("Sync", "id", key, "owner", who.String(), "bps", strconv.FormatInt(bps, 10))
}

func live(id int) (address, int64) {
	owner, err := col.OwnerOf(strconv.Itoa(id))
	if err != nil || !owner.IsValid() {
		panic("perk: unknown")
	}
	if owner == chain.PackageAddress(colPkg) {
		return address(""), 0
	}
	return owner, bpsOf(col.RarityOf(id))
}

func bpsOf(rarity string) int64 {
	switch strings.ToLower(strings.TrimSpace(rarity)) {
	case "mythic":
		return 150
	case "legendary":
		return 125
	case "epic":
		return 100
	case "rare":
		return 75
	case "uncommon":
		return 50
	case "common":
		return 25
	default:
		return 0
	}
}

func addTier(cur realm, who address, bps int64, dir int) {
	if dir != 1 && dir != -1 {
		panic("perk: dir")
	}
	syncPot(cur)
	w := mustWallet(who)
	settle(w)
	switch bps {
	case 25:
		w.n25 += dir
	case 50:
		w.n50 += dir
	case 75:
		w.n75 += dir
	case 100:
		w.n100 += dir
	case 125:
		w.n125 += dir
	case 150:
		w.n150 += dir
	default:
		panic("perk: tier")
	}
	if w.n25 < 0 || w.n50 < 0 || w.n75 < 0 || w.n100 < 0 || w.n125 < 0 || w.n150 < 0 {
		panic("perk: count")
	}
	totalWeight += bps * int64(dir)
	if totalWeight < 0 {
		panic("perk: weight")
	}
	w.debt = shareOf(w) * acc / scale
	wallets.Set(who.String(), w)
	factory.NoteHolderDiscount(cross(cur), who.String(), bestOf(w))
}

func settle(w *wallet) {
	sw := shareOf(w)
	got := sw * acc / scale
	if got < w.debt {
		panic("perk: debt")
	}
	w.accrued += got - w.debt
	w.debt = got
}

func syncPot(cur realm) {
	if !self.IsValid() {
		self = cur.Address()
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bal := bk.GetCoins(self).AmountOf(native)
	if bal < accounted {
		panic("perk: balance")
	}
	delta := bal - accounted
	if delta == 0 || totalWeight <= 0 {
		return
	}
	if delta > maxDelta {
		panic("perk: amount")
	}
	bump := delta * scale / totalWeight
	if bump <= 0 {
		return
	}
	allocated := bump * totalWeight / scale
	if allocated <= 0 {
		return
	}
	if acc > maxDelta*scale-bump {
		panic("perk: acc")
	}
	acc += bump
	accounted += allocated
}

func shareOf(w *wallet) int64 {
	return int64(w.n25)*25 + int64(w.n50)*50 + int64(w.n75)*75 + int64(w.n100)*100 + int64(w.n125)*125 + int64(w.n150)*150
}

func bestOf(w *wallet) int64 {
	if w.n150 > 0 {
		return 150
	}
	if w.n125 > 0 {
		return 125
	}
	if w.n100 > 0 {
		return 100
	}
	if w.n75 > 0 {
		return 75
	}
	if w.n50 > 0 {
		return 50
	}
	if w.n25 > 0 {
		return 25
	}
	return 0
}

func load(owner string) *wallet {
	v := wallets.Get(strings.ToLower(strings.TrimSpace(owner)))
	if v == nil {
		return nil
	}
	return v.(*wallet)
}

func mustWallet(who address) *wallet {
	w := load(who.String())
	if w == nil {
		w = &wallet{}
		wallets.Set(who.String(), w)
	}
	return w
}

func requireUser(cur realm) address {
	if !cur.IsCurrent() {
		panic("perk: spoofed realm")
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("perk: EOA only")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("perk: extra denoms")
	}
	return prev.Address()
}
