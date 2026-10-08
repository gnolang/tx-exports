// Package sales owns launch token custody, direct-creation allocations, fair
// sales and airdrops. Quote that reaches it through its entry points is owed
// to someone on record: buyers (escrow and refunds), creators (settled
// proceeds) or the protocol (fees). Coins sent to it any other way are owed
// to no one and never leave. It has no admin and no emergency withdrawal path.
package sales

import (
	"strconv"
	"strings"
	"time"

	"chain"
	"chain/banker"
	"gno.land/p/samcrew/launchpad/currency/v1"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/p/samcrew/launchpad/vesting/v1"
	"gno.land/r/nt/grc20reg/v0"
	"gno.land/r/samcrew/launchpad/config/v1"
	"gno.land/r/samcrew/launchpad/tokens/v1"
)

const salesPath = "gno.land/r/samcrew/launchpad/sales/v1"
const launchpadTokenRegistryPrefix = "gno.land/r/samcrew/launchpad/tokens/v1.T"

type VestingRecord struct {
	Beneficiary        address
	PendingBeneficiary address
	Total              int64
	Claimed            int64
	Start              int64
	Cliff              int64
	Duration           int64
	Revocable          bool
	Revoked            bool
	RevokedVested      int64
}

var feeLiability = map[string]int64{}

func directCaller(cur realm) address {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("launchpad/sales: direct user call required")
	}
	return cur.Previous().Address()
}

func directFee(version int64, key string) int64 {
	p := config.GetVersion(version)
	for _, c := range p.Currencies {
		if c.Key == key {
			if c.DirectCreationFee < 0 {
				panic("launchpad/sales: direct fee disabled")
			}
			return c.DirectCreationFee
		}
	}
	panic("launchpad/sales: currency has no direct terms")
}

func collectCreationFee(cur realm, key string, amount int64) {
	// A Launchpad token held here for vesting, airdrops or sales cannot also
	// back a fee or quote liability without a combined same-asset ledger.
	if strings.HasPrefix(key, launchpadTokenRegistryPrefix) {
		panic("launchpad/sales: launchpad token cannot be quote currency")
	}
	if amount == 0 {
		currency.AssertNoCoins(0, cur)
		return
	}
	collectQuote(cur, key, amount)
	feeLiability[key] = sm.Add(feeLiability[key], amount)
	assertQuoteCovered(cur, key)
}

// collectQuote takes amount from the immediate caller, as attached coins or
// from a token allowance. Both routes pay from that caller and no one else.
func collectQuote(cur realm, key string, amount int64) {
	if key == config.NativeCurrency {
		currency.CollectNative(0, cur, amount)
	} else {
		currency.CollectToken(0, cur, grc20reg.MustGet(key), amount)
	}
}

func quoteBalance(self address, key string) int64 {
	if key == config.NativeCurrency {
		return banker.NewReadonlyBanker().GetCoin(self, key)
	}
	return grc20reg.MustGet(key).BalanceOf(self)
}

// owedIn is everything the realm owes in one currency: fees, escrow, refunds
// and proceeds.
func owedIn(key string) int64 {
	owed := sm.Add(feeLiability[key], fairEscrowLiability[key])
	owed = sm.Add(owed, fairRefundLiability[key])
	return sm.Add(owed, fairProceedsLiability[key])
}

// assertQuoteCovered follows every movement of quote: the realm must still
// hold everything it owes in that currency. An exit ends with it; a creation
// runs it right after collecting its fee.
func assertQuoteCovered(cur realm, key string) {
	if quoteBalance(cur.Address(), key) < owedIn(key) {
		panic("launchpad/sales: quote custody shortfall")
	}
}

func payQuote(cur realm, key string, to address, amount int64) {
	if key == config.NativeCurrency {
		currency.PayNative(0, cur, to, amount)
	} else {
		currency.PayToken(0, cur, grc20reg.MustGet(key), to, amount)
	}
}

// SweepFees pays every fee recorded in one currency, creation fees and
// fair-sale primary fees alike, to the treasury of the current config, and
// returns the amount. Anyone can call it; the caller chooses neither the
// receiver nor the amount. A fee is only ever recorded once a treasury is
// named, and config never lets the treasury be removed.
func SweepFees(cur realm, currencyKey string) int64 {
	if !cur.IsCurrent() {
		panic("launchpad/sales: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	amount := feeLiability[currencyKey]
	if amount <= 0 {
		panic("launchpad/sales: no fees to sweep")
	}
	treasury := config.GetVersion(config.GetCurrentVersion()).Treasury
	// Config refuses to name this realm as treasury. If it ever did, a native
	// sweep would pay the realm itself: the fees would stop being owed and
	// stay here for good, and anyone could trigger it. So it is refused here
	// as well.
	if treasury == cur.Address() {
		panic("launchpad/sales: treasury is this realm")
	}
	feeLiability[currencyKey] = 0
	payQuote(cur, currencyKey, treasury, amount)
	assertQuoteCovered(cur, currencyKey)
	chain.Emit("LaunchpadFeesSwept", "currency", currencyKey,
		"treasury", treasury.String(), "amount", strconv.FormatInt(amount, 10),
		"actor", cur.Previous().Address().String())
	return amount
}

// CreateDirect creates a direct token without an initial airdrop. The
// allocation string is parsed and the whole amount partitioned before any
// payment. The caller, payer and initial mint's creator are the same live
// direct user.
func CreateDirect(cur realm, mode, name, ticker string, decimals int,
	initialSupply, maxSupply int64, currencyKey string, expectedVersion int64,
	description, image, website, xHandle, telegram, allocations string) string {
	return createDirect(cur, mode, name, ticker, decimals, initialSupply,
		maxSupply, currencyKey, expectedVersion, description, image, website,
		xHandle, telegram, allocations, "", "", 0)
}

// CreateDirectWithAirdrop reserves part of the initial mint for one Merkle
// campaign. The caller commits to the next token ID used in every leaf. If
// another launch takes that ID first, this transaction rejects before payment.
func CreateDirectWithAirdrop(cur realm, mode, name, ticker string, decimals int,
	initialSupply, maxSupply int64, currencyKey string, expectedVersion int64,
	description, image, website, xHandle, telegram, allocations,
	expectedID, airdropRoot string, airdropTotal int64) string {
	return createDirect(cur, mode, name, ticker, decimals, initialSupply,
		maxSupply, currencyKey, expectedVersion, description, image, website,
		xHandle, telegram, allocations, expectedID, airdropRoot, airdropTotal)
}

func createDirect(cur realm, mode, name, ticker string, decimals int,
	initialSupply, maxSupply int64, currencyKey string, expectedVersion int64,
	description, image, website, xHandle, telegram, allocations,
	expectedID, airdropRoot string, airdropTotal int64) string {
	creator := directCaller(cur)
	if mode != tokens.ModeDirectFixed && mode != tokens.ModeDirectCap {
		panic("launchpad/sales: direct mode required")
	}
	if airdropTotal > 0 {
		requireAirdropRoot(airdropRoot)
		nextID := "T" + strconv.FormatInt(sm.Add(tokens.Count(), 1), 10)
		if expectedID != nextID {
			panic("launchpad/sales: airdrop token ID changed")
		}
	} else if airdropTotal != 0 || expectedID != "" || airdropRoot != "" {
		panic("launchpad/sales: invalid airdrop allocation")
	}
	parsed, allocated := parseAllocations(allocations)
	committed := sm.Add(allocated, airdropTotal)
	if initialSupply <= 0 || committed > initialSupply {
		panic("launchpad/sales: allocations exceed supply")
	}
	config.AssertNewAction(config.LaneDirect, currencyKey, expectedVersion)
	if airdropTotal > 0 {
		config.AssertNewAction(config.LaneAirdrop, currencyKey, expectedVersion)
	}
	fee := directFee(expectedVersion, currencyKey)
	collectCreationFee(cur, currencyKey, fee)
	id := tokens.Create(cross(cur), creator, mode, name, ticker,
		decimals, initialSupply, maxSupply, currencyKey, expectedVersion,
		description, image, website, xHandle, telegram)
	if airdropTotal > 0 && id != expectedID {
		panic("launchpad/sales: airdrop token ID changed")
	}
	retained := airdropTotal
	for _, a := range parsed {
		if a.duration == 0 {
			tokens.Transfer(cross(cur), id, a.beneficiary, a.amount)
			continue
		}
		appendVesting(id, VestingRecord{
			Beneficiary: a.beneficiary, Total: a.amount,
			Start: a.start, Cliff: a.cliff, Duration: a.duration,
			Revocable: a.revocable,
		})
		retained = sm.Add(retained, a.amount)
	}
	if airdropTotal > 0 {
		airdrops.Set(id, AirdropRecord{Root: airdropRoot, Total: airdropTotal})
		chain.Emit("LaunchpadAirdropCreated", "id", id, "creator", creator.String(),
			"root", airdropRoot, "total", strconv.FormatInt(airdropTotal, 10))
	}
	remainder := sm.Sub(initialSupply, committed)
	if remainder > 0 {
		tokens.Transfer(cross(cur), id, creator, remainder)
	}
	setTokenOwed(id, retained)
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) != retained {
		panic("launchpad/sales: token custody mismatch")
	}
	chain.Emit("LaunchpadDirectCreated", "id", id, "creator", creator.String(),
		"currency", currencyKey, "fee", strconv.FormatInt(fee, 10),
		"retained", strconv.FormatInt(retained, 10))
	return id
}

// MintCappedAllocated requires the token's current mint authority to be the
// immediate user or realm caller. Every new unit is assigned to an immediate or vested
// allocation; there is no implicit receiver or unrecorded sales balance.
// No additional creation fee is charged, and attached native coins are
// rejected. Pausing the direct lane stops new mints without blocking claims.
func MintCappedAllocated(cur realm, id string, amount int64, allocations string) {
	if !cur.IsCurrent() {
		panic("launchpad/sales: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	previous := cur.Previous()
	authority := previous.Address()
	if !authority.IsValid() || (!previous.IsUserCall() &&
		(previous.PkgPath() == "" || authority != chain.PackageAddress(previous.PkgPath()))) {
		panic("launchpad/sales: immediate authority call required")
	}
	parsed, allocated := parseAllocations(allocations)
	if amount <= 0 || allocated != amount {
		panic("launchpad/sales: capped mint must be fully allocated")
	}
	// The original creator owns existing revocation rights. A successor mint
	// authority must not create a schedule the former authority can claw back.
	for _, a := range parsed {
		if a.revocable {
			panic("launchpad/sales: later mint vesting cannot be revocable")
		}
	}
	info := tokens.GetInfo(id)
	if info.Mode != tokens.ModeDirectCap || info.MintRenounced || info.MintAuthority != authority {
		panic("launchpad/sales: current mint authority only")
	}
	config.AssertLaneOpen(config.LaneDirect, info.CurrencyKey)
	tokens.MintCapped(cross(cur), id, authority, amount)
	retained := int64(0)
	for _, a := range parsed {
		if a.duration == 0 {
			tokens.Transfer(cross(cur), id, a.beneficiary, a.amount)
			continue
		}
		appendVesting(id, VestingRecord{
			Beneficiary: a.beneficiary, Total: a.amount,
			Start: a.start, Cliff: a.cliff, Duration: a.duration,
			Revocable: a.revocable,
		})
		retained = sm.Add(retained, a.amount)
	}
	setTokenOwed(id, sm.Add(tokenOwed(id), retained))
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	chain.Emit("LaunchpadCappedMintAllocated", "id", id,
		"authority", authority.String(), "amount", strconv.FormatInt(amount, 10),
		"retained", strconv.FormatInt(retained, 10))
}

func VestingCount(id string) int { return vestingCount(id) }

func GetVesting(id string, index int) VestingRecord {
	if index < 0 || index >= vestingCount(id) {
		panic("launchpad/sales: vesting record not found")
	}
	return vestingAt(id, index)
}

func TokenLiability(id string) int64 { return tokenOwed(id) }

// ClaimVested remains open even when the direct-launch lane is paused. Anyone
// may trigger release, but the destination is always the recorded beneficiary.
// This also permits a realm beneficiary to receive its vested tokens.
func ClaimVested(cur realm, id string, index int) int64 {
	if !cur.IsCurrent() {
		panic("launchpad/sales: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	if index < 0 || index >= vestingCount(id) {
		panic("launchpad/sales: vesting record not found")
	}
	r := vestingAt(id, index)
	if r.PendingBeneficiary != "" {
		panic("launchpad/sales: beneficiary move pending")
	}
	s := vesting.Schedule{Total: r.Total, Start: r.Start, Cliff: r.Cliff, Duration: r.Duration}
	amount := int64(0)
	if r.Revoked {
		amount = sm.Sub(r.RevokedVested, r.Claimed)
	} else {
		amount = s.Releasable(time.Now().Unix(), r.Claimed)
	}
	if amount <= 0 {
		panic("launchpad/sales: nothing vested to claim")
	}
	r.Claimed = sm.Add(r.Claimed, amount)
	setVesting(id, index, r)
	setTokenOwed(id, sm.Sub(tokenOwed(id), amount))
	tokens.Transfer(cross(cur), id, r.Beneficiary, amount)
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	chain.Emit("LaunchpadVestingClaimed", "id", id,
		"index", strconv.Itoa(index), "beneficiary", r.Beneficiary.String(),
		"actor", cur.Previous().Address().String(),
		"amount", strconv.FormatInt(amount, 10))
	return amount
}

// RevokeVesting returns only unvested tokens to the original creator. The
// beneficiary retains its accrued vested entitlement and claim right.
func RevokeVesting(cur realm, id string, index int) int64 {
	creator := directCaller(cur)
	currency.AssertNoCoins(0, cur)
	if tokens.GetInfo(id).Creator != creator || index < 0 || index >= vestingCount(id) {
		panic("launchpad/sales: creator vesting only")
	}
	r := vestingAt(id, index)
	if !r.Revocable || r.Revoked {
		panic("launchpad/sales: vesting is not revocable")
	}
	s := vesting.Schedule{Total: r.Total, Start: r.Start, Cliff: r.Cliff, Duration: r.Duration}
	vested := s.VestedAt(time.Now().Unix())
	unvested := sm.Sub(r.Total, vested)
	r.Revoked = true
	r.RevokedVested = vested
	setVesting(id, index, r)
	setTokenOwed(id, sm.Sub(tokenOwed(id), unvested))
	if unvested > 0 {
		tokens.Transfer(cross(cur), id, creator, unvested)
	}
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	chain.Emit("LaunchpadVestingRevoked", "id", id,
		"index", strconv.Itoa(index), "creator", creator.String(),
		"unvested", strconv.FormatInt(unvested, 10),
		"vested", strconv.FormatInt(vested, 10))
	return unvested
}

func vestingCaller(cur realm) address {
	if !cur.IsCurrent() {
		panic("launchpad/sales: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	return cur.Previous().Address()
}

// ProposeVestingBeneficiary is callable by the current beneficiary, including
// a beneficiary realm. A pending move freezes claims until acceptance or
// cancellation, so the old beneficiary cannot drain accrued entitlement.
func ProposeVestingBeneficiary(cur realm, id string, index int, next address) {
	who := vestingCaller(cur)
	r := GetVesting(id, index)
	if who != r.Beneficiary || !meta.ValidAddress(next) || next == who ||
		next == chain.PackageAddress(salesPath) {
		panic("launchpad/sales: beneficiary proposal denied")
	}
	r.PendingBeneficiary = next
	setVesting(id, index, r)
	chain.Emit("LaunchpadVestingBeneficiaryProposed", "id", id,
		"index", strconv.Itoa(index), "from", who.String(), "to", next.String())
}

func CancelVestingBeneficiary(cur realm, id string, index int) {
	who := vestingCaller(cur)
	r := GetVesting(id, index)
	if who != r.Beneficiary || r.PendingBeneficiary == "" {
		panic("launchpad/sales: beneficiary cancellation denied")
	}
	r.PendingBeneficiary = ""
	setVesting(id, index, r)
	chain.Emit("LaunchpadVestingBeneficiaryCancelled", "id", id,
		"index", strconv.Itoa(index), "beneficiary", who.String())
}

func AcceptVestingBeneficiary(cur realm, id string, index int) {
	who := vestingCaller(cur)
	r := GetVesting(id, index)
	if r.PendingBeneficiary == "" || who != r.PendingBeneficiary {
		panic("launchpad/sales: pending beneficiary only")
	}
	old := r.Beneficiary
	r.Beneficiary = who
	r.PendingBeneficiary = ""
	setVesting(id, index, r)
	chain.Emit("LaunchpadVestingBeneficiaryAccepted", "id", id,
		"index", strconv.Itoa(index), "from", old.String(), "to", who.String())
}
