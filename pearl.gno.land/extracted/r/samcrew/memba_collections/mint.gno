package memba_collections

import (
	"chain"
	"chain/runtime/unsafe"
	"math/overflow"
	"strings"

	"gno.land/p/samcrew/grc721"
)

// ── proceeds ledger + small helpers ─────────────────────────────────────────

func walletCount(c *collection, who address) int64 {
	if v, ok := c.mintedByWallet.Get(who.String()); ok {
		return v.(int64)
	}
	return 0
}

func proceedsOf(c *collection, key string) int64 {
	if v, ok := c.proceeds.Get(key); ok {
		return v.(int64)
	}
	return 0
}

func creditProceeds(c *collection, denom string, amt int64) {
	key := denomKey(denom)
	c.proceeds.Set(key, proceedsOf(c, key)+amt)
}

func assertDenomAllowed(denom string) {
	if isNativeDenom(denom) {
		return
	}
	if _, ok := allowedDenoms.Get(denom); !ok {
		panic("denom not allowed: " + denom)
	}
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// mintChecks enforces the non-supply gating: maxPerWallet, mintStartBlock,
// per-wallet cooldown. Supply is gated inside mintToken (on nextAutoTokenID).
func mintChecks(c *collection, minter address) {
	if c.maxPerWallet > 0 && walletCount(c, minter)+1 > c.maxPerWallet {
		panic("per-wallet mint limit reached")
	}
	h := chainHeight()
	if c.mintStartBlock > 0 && h < c.mintStartBlock {
		panic("mint not started")
	}
	if c.mintCooldownBlocks > 0 {
		if v, ok := c.lastMintBlock.Get(minter.String()); ok {
			if h-v.(int64) < c.mintCooldownBlocks {
				panic("mint cooldown active")
			}
		}
	}
}

// mintToken performs the raw mint: supply gate on the mint-count (nextAutoTokenID,
// NOT TokenCount — Burn never reopens a slot, S-2), auto-assigns the sequential
// tid, sets the URI, and bumps the counter. Returns the tid string.
func mintToken(cur realm, c *collection, to address, tokenURI string) string {
	if c.maxSupply > 0 && c.nextAutoTokenID >= c.maxSupply {
		panic("max supply reached")
	}
	tidStr := itoa(c.nextAutoTokenID)
	tid := grc721.TokenID(tidStr)
	if err := c.nft.Mint(to, tid); err != nil {
		panic(err.Error())
	}
	if tokenURI != "" {
		if _, err := c.nft.SetTokenURI(to, tid, grc721.TokenURI(tokenURI)); err != nil {
			panic(err.Error())
		}
	}
	c.nextAutoTokenID++
	return tidStr
}

// ── Admin mint (no payment) ─────────────────────────────────────────────────

// Mint is the admin no-pay mint. Auto-assigns the next sequential tid.
func Mint(cur realm, id string, to address, tokenURI string) string {
	c := mustGet(id)
	assertCollectionAdmin(c)
	assertNotPaused(c)
	tid := mintToken(cur, c, to, tokenURI)
	chain.Emit("Mint",
		"collectionID", id,
		"tokenId", tid,
		"minter", caller().String(),
		"to", to.String(),
		"block", itoa(chainHeight()),
	)
	return tid
}

// ── Public + allowlist paid mints ───────────────────────────────────────────

// MintPublic mints in the public phase, paying mintPrice in payDenom.
func MintPublic(cur realm, id, tokenURI string) string {
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("must be a direct user call")
	}
	return mintPublicInternal(cur, id, caller(), unsafe.OriginSend(), tokenURI)
}

func mintPublicInternal(cur realm, id string, minter address, sent chain.Coins, tokenURI string) string {
	c := mustGet(id)
	if c.phase != PhasePublic {
		panic("not in public phase")
	}
	return paidMint(cur, c, id, minter, sent, tokenURI, PhasePublic, false)
}

// MintAllowlist mints in the allowlist phase. The caller proves membership via
// a Merkle proof of (caller, maxQty); per-wallet quantity is enforced.
//
// `proof` is the comma-separated list of hex-encoded sibling hashes. It MUST
// cross the ABI as a single string: a vm/MsgCall arg cannot encode a []string
// (the VM only converts scalars and base64 []byte — gno convert.go), so a
// []string proof param would make this entrypoint uncallable from a wallet.
func MintAllowlist(cur realm, id string, proof string, maxQty int64, tokenURI string) string {
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("must be a direct user call")
	}
	return mintAllowlistInternal(cur, id, caller(), unsafe.OriginSend(), splitProof(proof), maxQty, tokenURI)
}

// splitProof parses the comma-joined hex sibling list into the []string the
// in-realm verifier expects. An empty string yields no siblings (a single-leaf
// allowlist, where leaf must equal root).
func splitProof(proof string) []string {
	if proof == "" {
		return nil
	}
	return strings.Split(proof, ",")
}

func mintAllowlistInternal(cur realm, id string, minter address, sent chain.Coins, proof []string, maxQty int64, tokenURI string) string {
	c := mustGet(id)
	if c.phase != PhaseAllowlist {
		panic("not in allowlist phase")
	}
	if !verifyAllowlist(c.allowlistRoot, minter, maxQty, proof) {
		panic("invalid allowlist proof")
	}
	if walletCount(c, minter)+1 > maxQty {
		panic("allowlist quantity exceeded")
	}
	return paidMint(cur, c, id, minter, sent, tokenURI, PhaseAllowlist, true)
}

// paidMint is the shared CEI-ordered paid-mint path (B-1):
//   Checks → guard, !paused, gating, denom re-check (E-5), native amount.
//   Effects → mint token, bump counters, credit proceeds (BEFORE any teller).
//   Interactions → native fee/refund, or grc20 pull + fee (RealmTeller).
func paidMint(cur realm, c *collection, id string, minter address, sent chain.Coins, tokenURI string, phase int, isAllowlist bool) string {
	if c.mintGuard {
		panic("reentrancy")
	}
	c.mintGuard = true
	defer func() { c.mintGuard = false }()

	// ── Checks ──
	assertNotPaused(c)
	mintChecks(c, minter)
	denom := c.payDenom
	assertDenomAllowed(denom) // E-5: re-check at mint time
	price := c.mintPrice

	platformCut := overflow.Mul64p(price, primaryFeeBPS) / 10000
	creatorAmt := price - platformCut

	var paid int64
	native := isNativeDenom(denom)
	if native {
		paid = sumDenom(sent, "ugnot")
		if paid < price {
			panic("insufficient payment")
		}
	} else if sumDenom(sent, "ugnot") > 0 {
		// Reject ugnot attached to a grc20-priced mint: it would otherwise
		// enter the realm untracked and un-withdrawable (LOW stuck-funds trap).
		panic("no native payment on a grc20 mint")
	}

	// ── Effects (before any value movement) ──
	tid := mintToken(cur, c, minter, tokenURI)
	c.mintedByWallet.Set(minter.String(), walletCount(c, minter)+1)
	c.lastMintBlock.Set(minter.String(), chainHeight())
	creditProceeds(c, denom, creatorAmt)

	// ── Interactions ──
	if native {
		if platformCut > 0 {
			sendNative(cur, feeRecipient, platformCut)
		}
		if over := paid - price; over > 0 {
			sendNative(cur, minter, over)
		}
	} else {
		teller := grc20Teller(cur, denom)
		if err := teller.TransferFrom(0, cur, minter, selfAddr(), price); err != nil {
			panic(err.Error())
		}
		if platformCut > 0 {
			if err := teller.Transfer(0, cur, feeRecipient, platformCut); err != nil {
				panic(err.Error())
			}
		}
	}

	isSelf := minter == c.admin || minter == c.royaltyRecip
	evName := "MintPublic"
	if isAllowlist {
		evName = "MintAllowlist"
	}
	chain.Emit(evName,
		"collectionID", id,
		"tokenId", tid,
		"minter", minter.String(),
		"payer", minter.String(),
		"price", itoa(price),
		"denom", denomKey(denom),
		"primaryFee", itoa(platformCut),
		"creatorAmt", itoa(creatorAmt),
		"phase", itoa(int64(phase)),
		"isSelfMint", boolStr(isSelf),
		"mintedAfter", itoa(walletCount(c, minter)),
		"block", itoa(chainHeight()),
	)
	return tid
}

// ── Proceeds withdrawal ─────────────────────────────────────────────────────

// WithdrawProceeds sends a collection's accrued proceeds in `denom` to its
// fixed mintCustody. CEI: zero the ledger entry BEFORE sending.
func WithdrawProceeds(cur realm, id, denom string) {
	c := mustGet(id)
	assertCollectionAdmin(c)
	if c.mintGuard {
		panic("reentrancy")
	}
	c.mintGuard = true
	defer func() { c.mintGuard = false }()

	key := denomKey(denom)
	amt := proceedsOf(c, key)
	if amt <= 0 {
		panic("no proceeds")
	}
	c.proceeds.Set(key, int64(0)) // CEI: zero first

	if isNativeDenom(denom) {
		sendNative(cur, c.mintCustody, amt)
	} else {
		teller := grc20Teller(cur, denom)
		if err := teller.Transfer(0, cur, c.mintCustody, amt); err != nil {
			panic(err.Error())
		}
	}
	chain.Emit("ProceedsWithdrawn",
		"collectionID", id,
		"denom", key,
		"amount", itoa(amt),
		"to", c.mintCustody.String(),
	)
}
