package perk2

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

// Perk2 records share weight of minted, revealed, unlisted Bazaar Gens.
// Sync does not assign coins. Settle (admin) splits unsettled ugnot across
// the weights recorded at that call. Claim pays only settled accrued.
// Mainnet staging retargets colPkg and factory. Buy fees reach this sink
// only after factory.SetGenesis points here.

const (
	pkgPath  = "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/perk2"
	colPkg   = "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/c/bazaargens"
	native   = "ugnot"
	maxSpan  = 20
	maxDelta = int64(9_000_000_000_000) // one Settle refuses a larger gap
	maxInt64 = int64(9223372036854775807)
)

type wallet struct {
	n25     int
	n50     int
	n75     int
	n100    int
	n125    int
	n150    int
	accrued int64
}

var (
	wallets     avl.Tree
	tokenWho    avl.Tree
	tokenBps    avl.Tree
	totalWeight int64
	accounted   int64
	epochs      int64
	self        address
	admin       address
)

func Init(cur realm) {
	caller := requireUser(cur)
	if admin.IsValid() {
		panic("perk2: init")
	}
	self = chain.PackageAddress(pkgPath)
	if !self.IsValid() || self != cur.Address() {
		panic("perk2: self")
	}
	admin = caller
	chain.Emit("Init", "admin", caller.String())
}

func Sync(cur realm, id int) {
	requireUser(cur)
	requireInit()
	if id < 1 {
		panic("perk2: id")
	}
	syncID(cur, id)
}

func SyncSpan(cur realm, start, end int) {
	requireUser(cur)
	requireInit()
	if start < 1 || end < start || end-start >= maxSpan {
		panic("perk2: span")
	}
	for id := start; id <= end; id++ {
		syncID(cur, id)
	}
}

func Settle(cur realm) {
	caller := requireUser(cur)
	requireInit()
	if caller != admin {
		panic("perk2: admin")
	}
	delta := unsettledAmount()
	if delta == 0 || totalWeight <= 0 {
		return
	}
	if delta > maxDelta {
		panic("perk2: amount")
	}
	keys := walletKeys()
	parts := make([]int64, len(keys))
	sum := int64(0)
	allocated := int64(0)
	for i, key := range keys {
		share := shareOf(mustGet(key))
		if share < 0 {
			panic("perk2: weight")
		}
		if sum > maxInt64-share {
			panic("perk2: weight")
		}
		sum += share
		if share == 0 {
			continue
		}
		if share > totalWeight || delta > maxInt64/share {
			panic("perk2: amount")
		}
		part := share * delta / totalWeight
		if part < 0 || allocated > maxInt64-part {
			panic("perk2: amount")
		}
		parts[i] = part
		allocated += part
	}
	if sum != totalWeight {
		panic("perk2: weight")
	}
	if allocated == 0 || allocated > delta {
		if allocated > delta {
			panic("perk2: amount")
		}
		return
	}
	if accounted > maxInt64-allocated {
		panic("perk2: amount")
	}
	for i, key := range keys {
		if parts[i] == 0 {
			continue
		}
		w := mustGet(key)
		if w.accrued > maxInt64-parts[i] {
			panic("perk2: amount")
		}
		w.accrued += parts[i]
		wallets.Set(key, w)
	}
	accounted += allocated
	if sumAccrued(keys) != accounted {
		panic("perk2: accounted")
	}
	epochs++
	chain.Emit("Settle", "allocated", strconv.FormatInt(allocated, 10), "epoch", strconv.FormatInt(epochs, 10))
}

func Claim(cur realm) {
	caller := requireUser(cur)
	requireInit()
	w := load(caller.String())
	if w == nil || w.accrued <= 0 {
		panic("perk2: nothing")
	}
	amt := w.accrued
	if amt > accounted {
		panic("perk2: accounted")
	}
	if bankBalance() < amt {
		panic("perk2: funds")
	}
	w.accrued = 0
	accounted -= amt
	key := addrKey(caller)
	if shareOf(w) == 0 {
		wallets.Remove(key)
	} else {
		wallets.Set(key, w)
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
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

func Claimable(owner string) int64 {
	w := load(owner)
	if w == nil {
		return 0
	}
	if w.accrued < 0 {
		panic("perk2: accounted")
	}
	return w.accrued
}

func Unsettled() int64 {
	if !self.IsValid() {
		return 0
	}
	return unsettledAmount()
}

func Epochs() int64 {
	return epochs
}

func Accounted() int64 {
	return accounted
}

func Admin() string {
	if !admin.IsValid() {
		return ""
	}
	return admin.String()
}

func Address() address {
	return chain.PackageAddress(pkgPath)
}

func Render(_ string) string {
	u := int64(0)
	if self.IsValid() {
		u = Unsettled()
	}
	return "# Bazaar perk2\n\n- total weight: " + strconv.FormatInt(totalWeight, 10) +
		"\n- accounted: " + strconv.FormatInt(accounted, 10) +
		" ugnot\n- unsettled: " + strconv.FormatInt(u, 10) +
		" ugnot\n- epochs: " + strconv.FormatInt(epochs, 10) + "\n"
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
	if id > col.Minted() {
		panic("perk2: not minted")
	}
	owner, err := col.OwnerOf(strconv.Itoa(id))
	if err != nil || !owner.IsValid() {
		panic("perk2: unknown")
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
		panic("perk2: dir")
	}
	if !who.IsValid() {
		panic("perk2: owner")
	}
	w := mustWallet(who)
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
		panic("perk2: tier")
	}
	if w.n25 < 0 || w.n50 < 0 || w.n75 < 0 || w.n100 < 0 || w.n125 < 0 || w.n150 < 0 {
		panic("perk2: count")
	}
	totalWeight += bps * int64(dir)
	if totalWeight < 0 {
		panic("perk2: weight")
	}
	key := addrKey(who)
	if shareOf(w) == 0 && w.accrued == 0 {
		wallets.Remove(key)
	} else {
		wallets.Set(key, w)
	}
	factory.NoteHolderDiscount(cross(cur), who.String(), bestOf(w))
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
	w, ok := v.(*wallet)
	if !ok || w == nil {
		panic("perk2: wallet")
	}
	return w
}

func mustWallet(who address) *wallet {
	w := load(who.String())
	if w == nil {
		w = &wallet{}
		wallets.Set(addrKey(who), w)
	}
	return w
}

func mustGet(key string) *wallet {
	v := wallets.Get(key)
	if v == nil {
		panic("perk2: wallet")
	}
	w, ok := v.(*wallet)
	if !ok || w == nil {
		panic("perk2: wallet")
	}
	return w
}

func walletKeys() []string {
	keys := make([]string, 0)
	wallets.Iterate("", "", func(key string, _ any) bool {
		keys = append(keys, key)
		return false
	})
	return keys
}

func sumAccrued(keys []string) int64 {
	s := int64(0)
	for _, key := range keys {
		w := mustGet(key)
		if w.accrued < 0 || s > maxInt64-w.accrued {
			panic("perk2: accounted")
		}
		s += w.accrued
	}
	return s
}

func bankBalance() int64 {
	if !self.IsValid() {
		panic("perk2: init")
	}
	bal := banker.NewReadonlyBanker().GetCoins(self).AmountOf(native)
	if bal < 0 || bal < accounted {
		panic("perk2: balance")
	}
	return bal
}

func unsettledAmount() int64 {
	return bankBalance() - accounted
}

func addrKey(who address) string {
	return strings.ToLower(who.String())
}

func requireInit() {
	if !admin.IsValid() || !self.IsValid() {
		panic("perk2: init")
	}
}

func requireUser(cur realm) address {
	if !cur.IsCurrent() {
		panic("perk2: spoofed realm")
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("perk2: EOA only")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("perk2: extra denoms")
	}
	return prev.Address()
}
