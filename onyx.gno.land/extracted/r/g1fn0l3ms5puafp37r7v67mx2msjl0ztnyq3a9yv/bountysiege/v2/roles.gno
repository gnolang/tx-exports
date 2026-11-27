// Package bountysiege is the core escrow, mission lifecycle (Quest, Contest,
// Raid), Q&A, and Treasury realm for BountySiege on Gno.land.
package bountysiege

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"
)

var (
	// Strictly separated 3-role governance (owner != arbiter != treasury).
	owner              address
	realmAddr          address
	arbiter            address
	pendingArbiter     address
	arbiterEffectiveAt int64
	treasury           address
	pendingTreasury    address
	rolesInitialized   bool

	// Opsi A circuit breaker: owner may ONLY toggle cross-realm reputation
	// recording in an emergency. Owner has ZERO access to escrow or treasury.
	repRecordingEnabled bool = true

	// Explicit accounting ledgers for global fund invariant:
	// banker.NewReadonlyBanker().GetCoin(realmAddr, "ugnot") >= totalActiveEscrow + treasuryBalance
	totalActiveEscrow int64
	treasuryBalance   int64
	totalPaidOut      int64
)

func init(cur realm) {
	owner = cur.Previous().Address()
	if owner == "" {
		// Fallback only hit when imported lazily by gno filetest (Context == nil);
		// on-chain AddPackage always sets OriginCaller = creator.Bech32().
		owner = address("g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv")
	}
	realmAddr = cur.Address()
	repRecordingEnabled = true
}

// InitRoles sets the distinct arbiter and treasury addresses once after deploy.
func InitRoles(cur realm, arbiterAddr, treasuryAddr address) {
	requireNonPayableEOA(0, cur)
	if cur.Previous().Address() != owner {
		panic("unauthorized: only owner can initialize roles")
	}
	if rolesInitialized {
		panic("protocol roles already initialized")
	}
	if arbiterAddr == "" || treasuryAddr == "" {
		panic("arbiter and treasury addresses are required")
	}
	if owner == arbiterAddr || owner == treasuryAddr || arbiterAddr == treasuryAddr {
		panic("owner, arbiter, and treasury must be 3 distinct addresses")
	}
	arbiter = arbiterAddr
	treasury = treasuryAddr
	rolesInitialized = true
}

// ProposeArbiter starts a 48-hour timelock to rotate the arbiter address.
// Existing disputes keep their lockedArbiter permanently.
func ProposeArbiter(cur realm, next address) {
	requireNonPayableEOA(0, cur)
	requireRolesInitialized()
	if cur.Previous().Address() != owner {
		panic("unauthorized: only owner can propose arbiter rotation")
	}
	if next == "" {
		panic("new arbiter address is required")
	}
	if next == owner || next == treasury || next == pendingTreasury || next == arbiter {
		panic("new arbiter must be distinct from owner, treasury, and current arbiter")
	}
	pendingArbiter = next
	arbiterEffectiveAt = time.Now().Unix() + bs_core.ArbiterTimelockSec
}

// ExecuteArbiterRotation activates pendingArbiter after the 48-hour timelock.
func ExecuteArbiterRotation(cur realm) {
	requireNonPayableEOA(0, cur)
	requireRolesInitialized()
	if cur.Previous().Address() != owner {
		panic("unauthorized: only owner can execute arbiter rotation")
	}
	if pendingArbiter == "" {
		panic("no pending arbiter rotation")
	}
	if time.Now().Unix() < arbiterEffectiveAt {
		panic("arbiter rotation timelock (48h) has not elapsed")
	}
	arbiter = pendingArbiter
	pendingArbiter = ""
	arbiterEffectiveAt = 0
}

// ProposeTreasury starts a 2-step treasury address rotation (callable ONLY by treasury).
func ProposeTreasury(cur realm, next address) {
	requireNonPayableEOA(0, cur)
	requireRolesInitialized()
	if cur.Previous().Address() != treasury {
		panic("unauthorized: only current treasury can propose treasury rotation")
	}
	if next == "" {
		panic("new treasury address is required")
	}
	if next == owner || next == arbiter || next == pendingArbiter || next == treasury {
		panic("new treasury must be distinct from owner, arbiter, and current treasury")
	}
	pendingTreasury = next
}

// AcceptTreasury completes the 2-step treasury rotation (callable ONLY by pendingTreasury).
func AcceptTreasury(cur realm) {
	requireNonPayableEOA(0, cur)
	requireRolesInitialized()
	if pendingTreasury == "" || cur.Previous().Address() != pendingTreasury {
		panic("unauthorized: only pending treasury can accept rotation")
	}
	treasury = pendingTreasury
	pendingTreasury = ""
}

// WithdrawTreasury transfers up to treasuryBalance exclusively to the treasury address.
// Never touches totalActiveEscrow.
func WithdrawTreasury(cur realm, amount int64) {
	requireNonPayableEOA(0, cur)
	requireRolesInitialized()
	if cur.Previous().Address() != treasury {
		panic("unauthorized: only treasury can withdraw")
	}
	if amount <= 0 {
		panic("withdraw amount must be > 0")
	}
	if amount > treasuryBalance {
		panic("withdraw amount exceeds treasuryBalance")
	}
	// Checks-Effects-Interactions: debit ledger before sending coins.
	treasuryBalance -= amount
	sendUgnot(treasury, amount, cur)
}

// SetRepRecordingEnabled is the Opsi A emergency circuit breaker.
// Owner can ONLY toggle cross-realm siege_rep recording and has zero fund access.
func SetRepRecordingEnabled(cur realm, enabled bool) {
	requireNonPayableEOA(0, cur)
	if cur.Previous().Address() != owner {
		panic("unauthorized: only owner can toggle reputation circuit breaker")
	}
	repRecordingEnabled = enabled
}

//----------------------------------------
// Shared Coin, Role & Accounting Guards
// (NOTE: non-crossing helpers NEVER take `realm` as parameter #1!)
//----------------------------------------

func requireRolesInitialized() {
	if !rolesInitialized {
		panic("protocol roles not initialized")
	}
}

// requireNonPayableEOA enforces direct EOA call and empty OriginSend.
func requireNonPayableEOA(_ int, rlm realm) {
	if !rlm.Previous().IsUserCall() {
		panic("must be called directly by an EOA")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("non-payable function: do not send coins")
	}
}

// requireExactUgnot enforces direct EOA call and a single ugnot coin of exact amount.
func requireExactUgnot(expected int64, rlm realm) {
	if !rlm.Previous().IsUserCall() {
		panic("must be called directly by an EOA")
	}
	if expected <= 0 {
		panic("expected payment must be > 0")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 {
		panic("must send exactly one ugnot coin")
	}
	if sent[0].Denom != bs_core.DenomUgnot {
		panic("invalid coin denom: only ugnot is accepted")
	}
	if sent[0].Amount != expected {
		panic("exact amount mismatch: expected " + strconv.FormatInt(expected, 10) +
			"ugnot, got " + strconv.FormatInt(sent[0].Amount, 10) + "ugnot")
	}
}

func isExcludedWorkerRole(addr address) bool {
	if addr == "" {
		return true
	}
	return addr == arbiter || addr == pendingArbiter || addr == treasury || addr == pendingTreasury
}

func sendUgnot(to address, amount int64, rlm realm) {
	if amount <= 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	b.SendCoins(rlm.Address(), to, chain.NewCoins(chain.NewCoin(bs_core.DenomUgnot, amount)))
}

//----------------------------------------
// Public Read-Only Accounting & Role Getters
//----------------------------------------

func GetOwner() address           { return owner }
func GetArbiter() address         { return arbiter }
func GetPendingArbiter() address  { return pendingArbiter }
func GetTreasury() address        { return treasury }
func GetTreasuryBalance() int64   { return treasuryBalance }
func GetActiveEscrow() int64      { return totalActiveEscrow }
func GetTotalPaidOut() int64      { return totalPaidOut }
func IsRepRecordingEnabled() bool { return repRecordingEnabled }

// RealmUgnotBalance returns the live ugnot balance of this realm using GetCoin
// (never GetCoins, avoiding denom-spam DoS).
func RealmUgnotBalance() int64 {
	return banker.NewReadonlyBanker().GetCoin(realmAddr, bs_core.DenomUgnot)
}
