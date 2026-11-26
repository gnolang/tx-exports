// Package heirrealm is a dead-man's-switch inheritance realm for Gno.land.
//
// The problem: a Gno holder dies, loses their keys, or simply disappears,
// and their GNOT is locked forever. No will, no custodian, no recovery.
//
// HeirRealm lets the holder name a beneficiary and a check-in window.
// As long as the holder checks in before the window expires, nothing
// happens. Miss the window and anyone — an incentivised keeper, not a
// trusted custodian — can trigger the release. The keeper earns a small
// fee for doing the work; the rest goes to the beneficiary. The keeper
// can never release early, never change the beneficiary, and never
// touch the funds before the deadline.
//
// Design choices (all documented in README.md):
//   - Denomination is ugnot only (GNOT). One coin type keeps the
//     accounting auditable.
//   - Keeper fee is 2% (200 basis points) of the vault balance at
//     release time. Integer math: fee = balance * 200 / 10000.
//     For balances under 50 ugnot the fee rounds to 0.
//   - Check-in interval must be between 60 seconds (1 minute, so the
//     60-second demo can fast-forward) and 365 days.
//   - CheckIn only works BEFORE the deadline. Once the deadline has
//     passed, the vault is claimable and the owner can no longer
//     rescue it by checking in — that is the whole point of a
//     dead-man's switch.
//   - Cancel (owner refund) only works BEFORE the deadline and only
//     while the vault is still active. After expiry the funds belong
//     to the beneficiary.
//   - The keeper may not be the owner or the beneficiary.
//   - Time is block time: time.Now(), the same timelock primitive
//     used by examples/gno.land/r/demo/defi/atomicswap in gnolang/gno.
//
// Caller authentication follows the atomicswap pattern: payment
// functions require cur.Previous().IsUserCall() and read the attached
// coins from unsafe.OriginSend(). A realm in the middle of a call
// chain cannot fake a payment, because OriginSend describes the
// transaction envelope and IsUserCall rejects non-wallet callers.
//
// Social/voice recovery is intentionally NOT in this MVP. It is listed
// as a future extension in README.md.
package heirrealm

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
)

// Denom is the only coin this realm accepts: ugnot (GNOT).
const Denom = "ugnot"

// KeeperFeeBPS is the keeper's cut of a released vault, in basis
// points. 200 bps = 2%.
const KeeperFeeBPS = 200

// MinCheckInIntervalSeconds is the shortest check-in window: 60s.
// It exists so the demo can fast-forward through a full lifecycle
// in about a minute.
const MinCheckInIntervalSeconds = 60

// MaxCheckInIntervalSeconds is the longest check-in window: 365 days.
const MaxCheckInIntervalSeconds = 365 * 24 * 60 * 60

// ProductionGracePeriodSeconds is the production default grace period
// (7 days = 604,800s) before an expired vault becomes claimable.
const ProductionGracePeriodSeconds = 7 * 24 * 60 * 60

// GracePeriodSeconds is the grace window after Deadline during which
// TriggerRelease is still blocked and only the owner's Heartbeat can
// revive the vault: 60s for demo, 7 days in production.
const GracePeriodSeconds = 60 // 60s for demo, 7 days in production

var (
	vaults    avl.Tree // vault ID (string) -> *Vault
	nextVault int
)

// Vault is one inheritance vault.
type Vault struct {
	ID          int
	Owner       address
	Beneficiary address
	Balance     int64 // ugnot held by this vault
	Interval    int64 // check-in window, in seconds
	GracePeriod int64 // post-deadline grace window, in seconds
	Deadline    time.Time
	CreatedAt   time.Time
	Released    bool
	Cancelled   bool
	Keeper      address   // set on release; zero address until then
	ReleasedAt  time.Time // zero until released
}

// GraceEnd returns the end of the vault's grace period (Deadline + GracePeriod).
// Keepers can only call TriggerRelease strictly after GraceEnd.
func (v Vault) GraceEnd() time.Time {
	gp := v.GracePeriod
	if gp <= 0 {
		gp = GracePeriodSeconds
	}
	return v.Deadline.Add(time.Duration(gp) * time.Second)
}

// Status returns a human-readable state for the vault.
func (v Vault) Status() string {
	if v.Released {
		return "released"
	}
	if v.Cancelled {
		return "cancelled"
	}
	now := time.Now()
	if now.After(v.GraceEnd()) {
		return "expired — awaiting keeper"
	}
	if now.After(v.Deadline) {
		return "in grace period — awaiting heartbeat"
	}
	return "active"
}

// KeeperFee returns the keeper's cut of the vault balance at release.
func (v Vault) KeeperFee() int64 {
	return v.Balance * KeeperFeeBPS / 10000
}

// BeneficiaryShare returns what the beneficiary receives at release.
func (v Vault) BeneficiaryShare() int64 {
	return v.Balance - v.KeeperFee()
}

// CreateVault opens a vault for beneficiary with a check-in window of
// intervalSeconds. Attach the initial deposit with -send ugnot.
//
// The caller becomes the owner. The beneficiary must not be the owner.
// The deposit must be more than 0 ugnot.
func CreateVault(cur realm, beneficiary address, intervalSeconds int64) int {
	if !cur.Previous().IsUserCall() {
		panic("heirrealm: only direct wallet calls may create a vault")
	}
	owner := cur.Previous().Address()
	if beneficiary == "" {
		panic("heirrealm: beneficiary must not be empty")
	}
	if beneficiary == owner {
		panic("heirrealm: beneficiary must not be the owner")
	}
	if intervalSeconds < MinCheckInIntervalSeconds {
		panic("heirrealm: check-in interval too short (minimum 60 seconds)")
	}
	if intervalSeconds > MaxCheckInIntervalSeconds {
		panic("heirrealm: check-in interval too long (maximum 365 days)")
	}
	sent := unsafe.OriginSend()
	if len(sent) == 0 || sent.AmountOf(Denom) <= 0 {
		panic("heirrealm: attach an initial deposit in ugnot with -send")
	}
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("heirrealm: only ugnot is accepted")
	}
	amount := sent.AmountOf(Denom)
	now := time.Now()
	nextVault++
	v := &Vault{
		ID:          nextVault,
		Owner:       owner,
		Beneficiary: beneficiary,
		Balance:     amount,
		Interval:    intervalSeconds,
		GracePeriod: GracePeriodSeconds,
		Deadline:    now.Add(time.Duration(intervalSeconds) * time.Second),
		CreatedAt:   now,
	}
	vaults.Set(strconv.Itoa(v.ID), v)
	return v.ID
}

// Deposit tops up an active vault. Only the owner may deposit, and
// only ugnot is accepted. The check-in timer is NOT reset by a
// deposit — only CheckIn resets it.
func Deposit(cur realm, id int) int64 {
	if !cur.Previous().IsUserCall() {
		panic("heirrealm: only direct wallet calls may deposit")
	}
	v := mustGetVault(id)
	caller := cur.Previous().Address()
	if caller != v.Owner {
		panic("heirrealm: only the vault owner may deposit")
	}
	requireActive(v)
	sent := unsafe.OriginSend()
	if len(sent) == 0 || sent.AmountOf(Denom) <= 0 {
		panic("heirrealm: attach ugnot with -send")
	}
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("heirrealm: only ugnot is accepted")
	}
	v.Balance += sent.AmountOf(Denom)
	vaults.Set(strconv.Itoa(v.ID), v)
	return v.Balance
}

// CheckIn resets the vault's deadline to now + the check-in interval.
// Only the owner may check in, only while the vault is active, and
// only BEFORE the deadline has passed. After the deadline the vault
// is claimable and checking in can no longer save it.
func CheckIn(cur realm, id int) time.Time {
	v := mustGetVault(id)
	caller := cur.Previous().Address()
	if caller != v.Owner {
		panic("heirrealm: only the vault owner may check in")
	}
	requireActive(v)
	if !time.Now().Before(v.Deadline) {
		panic("heirrealm: deadline has passed, check-in is too late")
	}
	v.Deadline = time.Now().Add(time.Duration(v.Interval) * time.Second)
	vaults.Set(strconv.Itoa(v.ID), v)
	return v.Deadline
}

// Heartbeat revives a vault during its post-deadline grace period and
// resets its deadline to now + the check-in interval, identically to
// CheckIn. Only the vault owner may call Heartbeat, and only strictly
// during the grace window (after Deadline, before Deadline + GracePeriod).
func Heartbeat(cur realm, id int) time.Time {
	v := mustGetVault(id)
	caller := cur.Previous().Address()
	if caller != v.Owner {
		panic("heirrealm: only the vault owner may send a heartbeat")
	}
	requireActive(v)
	now := time.Now()
	if !now.After(v.Deadline) {
		panic("heirrealm: deadline has not passed yet, use CheckIn before the deadline")
	}
	if !now.Before(v.GraceEnd()) {
		panic("heirrealm: grace period has ended, heartbeat is too late")
	}
	v.Deadline = now.Add(time.Duration(v.Interval) * time.Second)
	vaults.Set(strconv.Itoa(v.ID), v)
	return v.Deadline
}

// TriggerRelease releases an expired vault once both its check-in
// deadline AND its post-deadline grace period have passed. Anyone may
// call it — that is the keeper's job — but the keeper may not be the
// owner or the beneficiary. The keeper earns 2% of the balance; the
// beneficiary receives the remaining 98%.
func TriggerRelease(cur realm, id int) (beneficiaryShare int64, keeperFee int64) {
	v := mustGetVault(id)
	keeper := cur.Previous().Address()
	if keeper == "" {
		panic("heirrealm: keeper must not be empty")
	}
	if keeper == v.Owner {
		panic("heirrealm: the owner cannot be the keeper")
	}
	if keeper == v.Beneficiary {
		panic("heirrealm: the beneficiary cannot be the keeper")
	}
	requireActive(v)
	now := time.Now()
	if !now.After(v.Deadline) {
		panic("heirrealm: vault has not expired yet")
	}
	if !now.After(v.GraceEnd()) {
		panic("heirrealm: vault is in grace period, cannot release before deadline + grace")
	}
	keeperFee = v.KeeperFee()
	beneficiaryShare = v.BeneficiaryShare()
	realmAddr := cur.Address()
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if keeperFee > 0 {
		banker_.SendCoins(realmAddr, keeper, chain.Coins{chain.NewCoin(Denom, keeperFee)})
	}
	if beneficiaryShare > 0 {
		banker_.SendCoins(realmAddr, v.Beneficiary, chain.Coins{chain.NewCoin(Denom, beneficiaryShare)})
	}
	v.Released = true
	v.Keeper = keeper
	v.ReleasedAt = time.Now()
	vaults.Set(strconv.Itoa(v.ID), v)
	return beneficiaryShare, keeperFee
}

// Cancel closes an active vault and refunds the full balance to the
// owner. Only the owner may cancel, and only BEFORE the deadline.
// After expiry the funds belong to the beneficiary and the owner
// can no longer claw them back.
func Cancel(cur realm, id int) int64 {
	v := mustGetVault(id)
	caller := cur.Previous().Address()
	if caller != v.Owner {
		panic("heirrealm: only the vault owner may cancel")
	}
	requireActive(v)
	if !time.Now().Before(v.Deadline) {
		panic("heirrealm: deadline has passed, vault can no longer be cancelled")
	}
	refund := v.Balance
	realmAddr := cur.Address()
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if refund > 0 {
		banker_.SendCoins(realmAddr, v.Owner, chain.Coins{chain.NewCoin(Denom, refund)})
	}
	v.Balance = 0
	v.Cancelled = true
	vaults.Set(strconv.Itoa(v.ID), v)
	return refund
}

// GetVault returns a copy of the vault with the given ID.
// Read-only: callable as a query, no transaction needed.
func GetVault(id int) Vault {
	return *mustGetVault(id)
}

// VaultCount returns the number of vaults ever created.
func VaultCount() int {
	return nextVault
}

// requireActive panics unless the vault is still live.
func requireActive(v *Vault) {
	if v.Released {
		panic("heirrealm: vault already released")
	}
	if v.Cancelled {
		panic("heirrealm: vault already cancelled")
	}
}

// mustGetVault loads a vault by ID or panics.
func mustGetVault(id int) *Vault {
	v := vaults.Get(strconv.Itoa(id))
	if v == nil {
		panic("heirrealm: unknown vault ID")
	}
	return v.(*Vault)
}
