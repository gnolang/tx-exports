package guardians_pilot_v1

import (
	"chain"
	"chain/runtime/unsafe"
	"gno.land/p/nt/ufmt/v0"
)

// Mint applies an explicit free/paid split in one atomic direct-user call.
// The caller reviews the split and payment in Adena before signing.
func Mint(cur realm, freeQuantity, paidQuantity, allowance int, unitPrice int64, proof string) {
	if !cur.Previous().IsUserCall() {
		panic("guardians: only direct user calls can mint")
	}
	if SalePhase() != salePhaseOpen {
		panic("guardians: sale is not active")
	}
	if freeQuantity < 0 || freeQuantity > 1 || paidQuantity < 0 || paidQuantity > 3 {
		panic("guardians: invalid free/paid quantity")
	}
	quantity := freeQuantity + paidQuantity
	assertMintQuantity(quantity)
	caller := cur.Previous().Address()
	if freeQuantity > 0 {
		if allowance != 1 || unitPrice != 0 || !VerifyAllowlist(caller, allowance, unitPrice, proof) {
			panic("guardians: invalid free-mint proof")
		}
		assertSaleMint(freeQuantity, AllowlistMinted(caller), saleConfig.allowlistLimit)
	} else if allowance != 0 || unitPrice != 0 || proof != "" {
		panic("guardians: unexpected free-mint arguments")
	}
	if paidQuantity > 0 {
		assertSaleMint(paidQuantity, PublicMinted(caller), saleConfig.publicLimit)
	}
	required := int64(0)
	if paidQuantity > 0 {
		required = requiredPayment(saleConfig.publicPrice, paidQuantity)
	}
	sent := unsafe.OriginSend()
	assertExactPayment(sent, required)
	mintTokens(caller, quantity)
	if freeQuantity > 0 {
		allowlistMintedByWallet.Set(caller.String(), AllowlistMinted(caller)+freeQuantity)
	}
	if paidQuantity > 0 {
		publicMintedByWallet.Set(caller.String(), PublicMinted(caller)+paidQuantity)
	}
	forwardPayment(cur, sent)
	chain.Emit("PilotMint", "minter", caller.String(), "free", ufmt.Sprintf("%d", freeQuantity), "paid", ufmt.Sprintf("%d", paidQuantity), "payment", ufmt.Sprintf("%d", required))
}
