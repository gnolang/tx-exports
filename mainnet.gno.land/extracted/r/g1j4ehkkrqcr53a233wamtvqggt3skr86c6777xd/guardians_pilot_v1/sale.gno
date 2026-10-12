package guardians_pilot_v1

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	salePhaseClosed    = "CLOSED"
	salePhaseAllowlist = "ALLOWLIST"
	salePhasePublic    = "PUBLIC"
	salePhaseOpen      = "OPEN"
	saleDenom          = "ugnot"
)

type saleConfiguration struct {
	allowlistStart int64
	allowlistEnd   int64
	publicStart    int64
	publicEnd      int64
	allowlistPrice int64
	publicPrice    int64
	allowlistLimit int
	publicLimit    int
	treasury       address
}

var (
	saleConfig              saleConfiguration
	saleConfigured          bool
	salePaused              = true
	allowlistMintedByWallet avl.Tree
	publicMintedByWallet    avl.Tree
)

// ConfigureSale stores timestamps as Unix seconds and prices in ugnot.
// Configuration is only mutable while the sale is paused.
func ConfigureSale(
	cur realm,
	allowlistStart, allowlistEnd int64,
	publicStart, publicEnd int64,
	allowlistPrice, publicPrice int64,
	allowlistLimit, publicLimit int,
	treasury address,
) {
	assertAdmin(cur.Previous().Address())
	if !salePaused {
		panic("guardians: pause sale before configuration")
	}
	if !validSaleSchedule(allowlistStart, allowlistEnd, publicStart, publicEnd) {
		panic("guardians: invalid sale schedule")
	}
	if !validAllowlistPrice(allowlistPrice) || !validSalePrice(publicPrice) {
		panic("guardians: invalid sale price")
	}
	if !validWalletLimit(allowlistLimit) || !validWalletLimit(publicLimit) {
		panic("guardians: invalid wallet limit")
	}
	if allowlistPrice != 0 || publicPrice != 1000000 || allowlistLimit != 1 || publicLimit != 3 {
		panic("guardians: pilot requires free 1 + paid 3 at 1 GNOT")
	}
	if treasury != address("g1ht2848ahr20tqq7086thg5h9vrw4836suzard8") {
		panic("guardians: unexpected pilot treasury")
	}
	if !treasury.IsValid() {
		panic("guardians: invalid sale treasury")
	}

	saleConfig = saleConfiguration{
		allowlistStart: allowlistStart,
		allowlistEnd:   allowlistEnd,
		publicStart:    publicStart,
		publicEnd:      publicEnd,
		allowlistPrice: allowlistPrice,
		publicPrice:    publicPrice,
		allowlistLimit: allowlistLimit,
		publicLimit:    publicLimit,
		treasury:       treasury,
	}
	saleConfigured = true

	chain.Emit(
		"SaleConfigured",
		"allowlistStart", ufmt.Sprintf("%d", allowlistStart),
		"allowlistEnd", ufmt.Sprintf("%d", allowlistEnd),
		"publicStart", ufmt.Sprintf("%d", publicStart),
		"publicEnd", ufmt.Sprintf("%d", publicEnd),
		"treasury", treasury.String(),
	)
}

func SetSalePaused(cur realm, paused bool) {
	assertAdmin(cur.Previous().Address())
	if !paused && !saleConfigured {
		panic("guardians: configure sale before unpausing")
	}
	if !paused && allowlistRoot == "" {
		panic("guardians: configure allowlist root before unpausing")
	}
	if !paused && revealState != revealStateCommitted {
		panic("guardians: commit reveal configuration before unpausing")
	}
	if !paused {
		allowlistRootLocked = true
	}
	salePaused = paused
	chain.Emit("SalePauseChanged", "paused", ufmt.Sprintf("%t", paused))
}

func SalePhase() string { return salePhaseAt(time.Now().Unix()) }

// Activate once, after metadata and proofs are ready. Both purchase modes share
// the same on-chain 24-hour window beginning in this activation transaction.
func ActivatePilotSale(cur realm) {
	assertAdmin(cur.Previous().Address())
	if saleConfigured {
		panic("guardians: pilot sale already configured")
	}
	start := time.Now().Unix()
	end := start + 86400
	ConfigureSale(cur, start, end, start, end, 0, 1000000, 1, 3, address("g1ht2848ahr20tqq7086thg5h9vrw4836suzard8"))
	SetSalePaused(cur, false)
}

func SalePhaseAt(unixTime int64) string { return salePhaseAt(unixTime) }

func salePhaseAt(unixTime int64) string {
	if salePaused || !saleConfigured {
		return salePhaseClosed
	}
	if unixTime >= saleConfig.publicStart && unixTime < saleConfig.publicEnd {
		return salePhaseOpen
	}
	return salePhaseClosed
}

func SalePaused() bool { return salePaused }

func SaleConfigured() bool { return saleConfigured }

func SaleTreasury() address { return saleConfig.treasury }

func AllowlistStart() int64 { return saleConfig.allowlistStart }

func AllowlistEnd() int64 { return saleConfig.allowlistEnd }

func PublicStart() int64 { return saleConfig.publicStart }

func PublicEnd() int64 { return saleConfig.publicEnd }

func AllowlistPrice() int64 { return saleConfig.allowlistPrice }

func PublicPrice() int64 { return saleConfig.publicPrice }

func AllowlistWalletLimit() int { return saleConfig.allowlistLimit }

func PublicWalletLimit() int { return saleConfig.publicLimit }

func AllowlistMinted(owner address) int { return mintedCount(&allowlistMintedByWallet, owner) }

func PublicMinted(owner address) int { return mintedCount(&publicMintedByWallet, owner) }

func NextSaleTimestamp() int64 {
	now := time.Now().Unix()
	if !saleConfigured {
		return 0
	}
	if now < saleConfig.allowlistStart {
		return saleConfig.allowlistStart
	}
	if now < saleConfig.allowlistEnd {
		return saleConfig.allowlistEnd
	}
	if now < saleConfig.publicStart {
		return saleConfig.publicStart
	}
	if now < saleConfig.publicEnd {
		return saleConfig.publicEnd
	}
	return 0
}

// MintPublic accepts only direct Adena/EOA calls. This pairing is critical:
// OriginSend describes actual receipt by this realm only for a direct user call.
func MintPublic(cur realm, quantity int) {
	if !cur.Previous().IsUserCall() {
		panic("guardians: only direct user calls can mint")
	}
	if SalePhase() != salePhaseOpen {
		panic("guardians: public sale is not active")
	}

	caller := cur.Previous().Address()
	assertSaleMint(quantity, PublicMinted(caller), saleConfig.publicLimit)
	required := requiredPayment(saleConfig.publicPrice, quantity)
	sent := unsafe.OriginSend()
	assertExactPayment(sent, required)

	mintTokens(caller, quantity)
	publicMintedByWallet.Set(caller.String(), PublicMinted(caller)+quantity)
	forwardPayment(cur, sent)

	chain.Emit(
		"PublicMint",
		"minter", caller.String(),
		"quantity", ufmt.Sprintf("%d", quantity),
		"paid", ufmt.Sprintf("%d", required),
	)
}

func assertSaleMint(quantity, alreadyMinted, walletLimit int) {
	assertMintQuantity(quantity)
	if alreadyMinted+quantity > walletLimit {
		panic("guardians: wallet mint limit exceeded")
	}
}

func requiredPayment(unitPrice int64, quantity int) int64 {
	if unitPrice < 0 || !validMintQuantity(quantity) {
		panic("guardians: invalid payment calculation")
	}
	return unitPrice * int64(quantity)
}

func assertExactPayment(sent chain.Coins, required int64) {
	if required == 0 {
		if len(sent) != 0 {
			panic("guardians: free mint must not include payment")
		}
		return
	}
	if !isExactPayment(sent, required) {
		panic(ufmt.Sprintf("guardians: exact payment required: %dugnot", required))
	}
}

func isExactPayment(sent chain.Coins, required int64) bool {
	return len(sent) == 1 && sent[0].Denom == saleDenom && sent[0].Amount == required
}

func forwardPayment(cur realm, sent chain.Coins) {
	if len(sent) == 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), saleConfig.treasury, sent)
}

func mintedCount(tree *avl.Tree, owner address) int {
	v := tree.Get(owner.String())
	if v == nil {
		return 0
	}
	return v.(int)
}

func validSaleSchedule(allowlistStart, allowlistEnd, publicStart, publicEnd int64) bool {
	return allowlistStart > 0 && allowlistStart == publicStart &&
		allowlistEnd == publicEnd && publicEnd- publicStart == 86400
}

func validSalePrice(price int64) bool {
	return price > 0 && price <= 9223372036854775807/int64(maxMintBatch)
}

func validAllowlistPrice(price int64) bool {
	return price >= 0 && price <= 9223372036854775807/int64(maxMintBatch)
}

func validWalletLimit(limit int) bool {
	return limit > 0 && int64(limit) <= maxSupply
}
