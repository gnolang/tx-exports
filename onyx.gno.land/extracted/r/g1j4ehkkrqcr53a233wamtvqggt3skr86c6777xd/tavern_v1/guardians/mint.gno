package guardians

import (
	"chain"
	"chain/runtime/unsafe"
	"time"
	"gno.land/p/nt/ufmt/v0"
)

// Mint preserves the pilot's one-button, free-first split. Each allowance is
// checked independently and exact payment/forwarding is atomic with minting.
func Mint(cur realm, freeQuantity, paidQuantity, allowance int, unitPrice int64, proof string) {
	if !cur.Previous().IsUserCall() {
		panic("guardians: only direct user calls can mint")
	}
	if freeQuantity < 0 || freeQuantity > 1 || paidQuantity < 0 || paidQuantity > maxPublicMintBatch {
		panic("guardians: invalid free/paid quantity")
	}
	assertMintQuantity(freeQuantity + paidQuantity)
	caller := cur.Previous().Address()
	now := time.Now().Unix()
	if freeQuantity > 0 {
		if !allowlistSaleOpenAt(now) {
			panic("guardians: allowlist sale is not active")
		}
		if allowance != 1 || unitPrice != 0 || saleConfig.allowlistPrice != 0 || !VerifyAllowlist(caller, allowance, unitPrice, proof) {
			panic("guardians: invalid free-mint proof")
		}
		assertSaleMint(freeQuantity, AllowlistMinted(caller), saleConfig.allowlistLimit)
	} else if allowance != 0 || unitPrice != 0 || proof != "" {
		panic("guardians: unexpected free-mint arguments")
	}
	if paidQuantity > 0 {
		if !publicSaleOpenAt(now) {
			panic("guardians: public sale is not active")
		}
		assertSaleMint(paidQuantity, PublicMinted(caller), saleConfig.publicLimit)
	}
	required := int64(0)
	if paidQuantity > 0 {
		required = requiredPayment(saleConfig.publicPrice, paidQuantity)
	}
	sent := unsafe.OriginSend()
	assertExactPayment(sent, required)
	mintAllocatedTokens(caller, freeQuantity, paidQuantity)
	if freeQuantity > 0 {
		allowlistMintedByWallet.Set(caller.String(), AllowlistMinted(caller)+freeQuantity)
	}
	if paidQuantity > 0 {
		publicMintedByWallet.Set(caller.String(), PublicMinted(caller)+paidQuantity)
	}
	forwardPayment(cur, sent)
	chain.Emit("Mint", "minter", caller.String(), "free", ufmt.Sprintf("%d", freeQuantity), "paid", ufmt.Sprintf("%d", paidQuantity), "payment", ufmt.Sprintf("%d", required))
}
