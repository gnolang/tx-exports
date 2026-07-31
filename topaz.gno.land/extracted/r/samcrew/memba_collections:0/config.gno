package memba_collections

import (
	"chain"
)

// phase constants
const (
	PhaseDraft     = 0
	PhaseAllowlist = 1
	PhasePublic    = 2
	PhaseClosed    = 3
)

// SetMintPhase sets the sale phase and (for the allowlist phase) the Merkle
// root. Admin only. Emits MintPhaseSet with the root for off-chain indexers.
func SetMintPhase(cur realm, id string, phase int, allowlistRoot string) {
	c := mustGet(id)
	assertCollectionAdmin(c)
	if phase < PhaseDraft || phase > PhaseClosed {
		panic("invalid phase")
	}
	c.phase = phase
	c.allowlistRoot = allowlistRoot
	chain.Emit("MintPhaseSet",
		"collectionID", id,
		"phase", itoa(int64(phase)),
		"allowlistRoot", allowlistRoot,
		"block", itoa(chainHeight()),
	)
}

// SetMintConfig sets the full mint configuration. Admin only. payDenom must be
// native ("" / "ugnot") or a currently-allowed denom. mintPrice (when > 0)
// must be in [MinMintPrice, MaxPriceUgnot]. maxSupply cannot be set below the
// number already minted. Emits MintConfigChanged carrying every cap (E-2).
func SetMintConfig(cur realm, id string, mintPrice int64, payDenom string, maxSupply, maxPerWallet, mintStartBlock, mintCooldownBlocks int64) {
	c := mustGet(id)
	assertCollectionAdmin(c)

	if !isNativeDenom(payDenom) {
		if _, ok := allowedDenoms.Get(payDenom); !ok {
			panic("denom not allowed: " + payDenom)
		}
	}
	if mintPrice != 0 && (mintPrice < MinMintPrice || mintPrice > MaxPriceUgnot) {
		panic("mint price out of range")
	}
	if maxSupply != 0 && maxSupply < c.nextAutoTokenID {
		panic("maxSupply below minted count")
	}
	if maxPerWallet < 0 || mintStartBlock < 0 || mintCooldownBlocks < 0 {
		panic("negative config value")
	}

	c.mintPrice = mintPrice
	c.payDenom = payDenom
	c.maxSupply = maxSupply
	c.maxPerWallet = maxPerWallet
	c.mintStartBlock = mintStartBlock
	c.mintCooldownBlocks = mintCooldownBlocks

	chain.Emit("MintConfigChanged",
		"collectionID", id,
		"mintPrice", itoa(mintPrice),
		"payDenom", payDenom,
		"maxSupply", itoa(maxSupply),
		"maxPerWallet", itoa(maxPerWallet),
		"mintStartBlock", itoa(mintStartBlock),
		"mintCooldownBlocks", itoa(mintCooldownBlocks),
		"block", itoa(chainHeight()),
	)
}
