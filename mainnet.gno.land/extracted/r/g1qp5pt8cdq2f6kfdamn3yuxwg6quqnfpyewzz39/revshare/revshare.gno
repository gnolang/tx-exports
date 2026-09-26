// Package revshare is a team revenue realm that IS a subscription
// provider. The live subscriptions realm supports realm providers but
// warns, in its own frozen header, that a realm provider "must expose
// its own crossing path to Claim, or what it earns is stranded."
// revshare is that crossing path, plus the one thing a team needs on
// top of it: pulled revenue is split among weighted members into
// pull-claimable balances.
//
// THE ECONOMIC COMPOSITION, PRECISELY:
//
//	components            : subscriptions (live realm — the revenue
//	                        machine and the upstream custodian),
//	                        feeledger (member balance accounting,
//	                        fee cap 0), coinio (payouts, held-balance
//	                        reads, reserve-protected sweep).
//	value boundaries      : B1 subscriber EOA -> subscriptions (plan
//	                        price, origin envelope; governed by
//	                        subscriptions' own H == U + F). B2
//	                        subscriptions -> revshare (banker send:
//	                        ClaimAll pays the caller, and the caller
//	                        is this realm). B3 revshare -> member EOA
//	                        (coinio.Payout on Claim/ClaimAll).
//	who owns which state  : subscriptions owns plans, subs and the
//	                        provider's claimable balance (revshare's
//	                        RECEIVABLE); revshare owns the member
//	                        table, weights, and the member balances in
//	                        its own ledger. No state is shared; the
//	                        only coupling is the crossing calls and
//	                        the coins that move over B2.
//	who controls funds    : upstream, only a claim by this realm can
//	                        move its receivable (provider-keyed
//	                        ledger). Here, member balances move only
//	                        to their owner (pull claims); the admin
//	                        can NEVER touch earned balances — sweep
//	                        reserves them, weight changes affect only
//	                        FUTURE distributions.
//	identity propagation  : downstream sees cur.Previous() = THIS
//	                        realm on every crossing call, so the plan
//	                        provider and the claim beneficiary are the
//	                        realm address by construction — no admin
//	                        or member identity ever reaches the
//	                        downstream realm.
//	conservation          : Held == UsersTotal + S (surplus above the
//	                        Liabilities() reserve, recoverable only by
//	                        SweepDenom). Distribution is exact: shares
//	                        are floor(amount*w/W) via the
//	                        overflow-free split (A/W)*w + ((A%W)*w)/W,
//	                        and the remainder goes to the
//	                        highest-weight member (ties: lowest
//	                        address) — fee_split's deterministic dust
//	                        policy, so no residual pool exists.
//	                        Cross-boundary: lifetime Pulled equals the
//	                        sum of all distributions, and the
//	                        downstream receivable is NOT part of Held.
//	ordering              : Pull refuses BEFORE the downstream call
//	                        (no members configured = refuse), claims
//	                        downstream, MEASURES the arrival as a
//	                        held-balance delta, then distributes
//	                        exactly what arrived. State-after-call:
//	                        the only local mutations happen after the
//	                        boundary, on measured coins.
//	downstream abort      : "nothing to claim" (or any downstream
//	                        panic) aborts the whole Pull — no local
//	                        state exists yet to corrupt, by ordering
//	                        AND by VM atomicity. There is no recover
//	                        anywhere in this realm, and none may be
//	                        added.
//	replay                : a second Pull finds a zero downstream
//	                        balance and aborts there. Distribution
//	                        credits are driven by the measured delta,
//	                        so a replayed Pull cannot double-count
//	                        even in principle.
//	trust                 : revshare does not trust the downstream
//	                        reply beyond "it did not abort" — it
//	                        distributes the measured balance delta,
//	                        not a reported amount. Downstream
//	                        validates nothing about this caller; the
//	                        provider ledger is keyed by address.
//	terminal states       : plans retire downstream (provider-only,
//	                        exposed here admin-gated); members can be
//	                        removed (earned balances survive removal
//	                        and stay claimable); the realm itself has
//	                        no terminal state — a team that walks away
//	                        leaves only pull-claimable balances.
//	adversarial callers   : Pull is permissionless — it can only move
//	                        the receivable into member balances at the
//	                        fixed weights, so a stranger's Pull is a
//	                        free favor. Plan creation/retirement is
//	                        admin-gated (the downstream per-provider
//	                        plan quota is a griefable resource).
//	                        Members trust the admin for FUTURE weights
//	                        only, never for earned balances. All
//	                        entrypoints refuse coin-carrying
//	                        transactions (the downstream assertNoSend
//	                        reads the origin envelope; ours matches).
//
// One team per deploy: subscriptions keeps ONE claimable balance per
// provider address, so a multi-team router behind one realm address
// could not attribute revenue at the boundary. This is a measured
// constraint of the downstream API, not a choice.
package revshare

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/coinio"
	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/feeledger"

	subs "gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/subscriptions"
)

// Denom is the only asset this realm accounts.
const Denom = "ugnot"

// MaxMembers bounds the distribution loop; MaxWeight bounds a single
// weight. Together they cap totalWeight at 200,000, which makes the
// remainder step of the split ((A%W)*w) provably overflow-free for
// any int64 coin amount — the conservation math cannot trap.
const (
	MaxMembers = 20
	MaxWeight  = int64(10000)
)

type member struct {
	addr   address
	weight int64
}

var (
	admin        address // manages members, plans; stages a successor
	pendingAdmin address // staged by TransferAdmin, completes via AcceptAdmin
	sweeper      address // may sweep out-of-band surplus

	self address // this realm's address, captured at deploy

	members     []member // insertion-ordered; bounded by MaxMembers
	totalWeight int64

	ledger = feeledger.MustNew(0)

	planIDs []int64 // plans created through this realm (ops/Render)
	pulled  int64   // lifetime revenue pulled over boundary B2
)

func init() {
	admin = unsafe.OriginCaller()
	sweeper = admin
	self = unsafe.CurrentRealm().Address()
}

// --- membership (admin-gated; future distributions only) ---

// AddMember adds a weighted member. Weight changes never touch earned
// balances; they shape future pulls only.
func AddMember(cur realm, a address, weight int64) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	var zero address
	if a == zero {
		panic("member must not be the zero address")
	}
	if weight < 1 || weight > MaxWeight {
		panic("weight must be in [1, " + itoa(MaxWeight) + "]")
	}
	if len(members) >= MaxMembers {
		panic("member table is full (" + itoa(int64(MaxMembers)) + ")")
	}
	if indexOf(a) >= 0 {
		panic("already a member")
	}
	members = append(members, member{addr: a, weight: weight})
	totalWeight += weight
	chain.Emit("MemberAdded", "addr", a.String(), "weight", itoa(weight))
}

// SetWeight changes a member's weight for future distributions.
func SetWeight(cur realm, a address, weight int64) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	if weight < 1 || weight > MaxWeight {
		panic("weight must be in [1, " + itoa(MaxWeight) + "]")
	}
	i := indexOf(a)
	if i < 0 {
		panic("not a member")
	}
	old := members[i].weight
	totalWeight += weight - old
	members[i].weight = weight
	chain.Emit("WeightSet", "addr", a.String(), "old", itoa(old), "new", itoa(weight))
}

// RemoveMember removes a member from future distributions. The
// member's earned balance is untouched and stays claimable forever.
func RemoveMember(cur realm, a address) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	i := indexOf(a)
	if i < 0 {
		panic("not a member")
	}
	totalWeight -= members[i].weight
	members = append(members[:i], members[i+1:]...)
	chain.Emit("MemberRemoved", "addr", a.String())
}

// --- the provider surface: crossing paths into subscriptions ---

// CreatePlan creates a subscription plan THROUGH this realm, making
// the realm the plan's provider downstream. Admin only: the
// per-provider plan quota downstream is a griefable resource.
func CreatePlan(cur realm, title, description string, price, periodBlocks, maxFeeBps int64) int64 {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	id := subs.CreatePlan(cross(cur), title, description, price, periodBlocks, maxFeeBps)
	planIDs = append(planIDs, id)
	chain.Emit("PlanCreated", "planId", itoa(id), "price", itoa(price),
		"periodBlocks", itoa(periodBlocks))
	return id
}

// RetirePlan retires one of this realm's plans downstream. Admin only.
func RetirePlan(cur realm, planID int64) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	subs.RetirePlan(cross(cur), planID)
	chain.Emit("PlanRetired", "planId", itoa(planID))
}

// Pull claims this realm's entire accrued provider balance from the
// subscriptions realm and distributes it to the members by weight.
// Permissionless: pulling can only move the receivable into member
// balances at the fixed weights, so anyone may crank it. Refuses
// BEFORE the downstream call when no member could receive the funds.
func Pull(cur realm) int64 {
	assertNoSend()
	if totalWeight == 0 {
		panic("no members configured to receive revenue")
	}

	before := coinio.HeldAt(self, Denom)
	subs.ClaimAll(cross(cur))
	amount := coinio.HeldAt(self, Denom) - before
	if amount <= 0 {
		panic("downstream claim delivered nothing")
	}

	distribute(amount)
	pulled += amount
	chain.Emit("Pulled", "amount", itoa(amount), "pulledTotal", itoa(pulled))
	return amount
}

// distribute splits amount by member weight. Shares are computed as
// (A/W)*w + ((A%W)*w)/W — floor(A*w/W) without any multiplication
// that can overflow. The remainder (< number of members) goes to the
// highest-weight member, lowest address on ties: deterministic, and
// it leaves the realm with no undistributed pool at rest.
func distribute(amount int64) {
	q := amount / totalWeight
	r := amount % totalWeight

	distributed := int64(0)
	for _, m := range members {
		share := q*m.weight + (r*m.weight)/totalWeight
		if share > 0 {
			ledger.MustDeposit(m.addr.String(), share, 0)
			distributed += share
		}
	}
	if dust := amount - distributed; dust > 0 {
		ledger.MustDeposit(dustRecipient().String(), dust, 0)
	}
}

func dustRecipient() address {
	best := members[0]
	for _, m := range members[1:] {
		if m.weight > best.weight ||
			(m.weight == best.weight && m.addr.String() < best.addr.String()) {
			best = m
		}
	}
	return best.addr
}

// --- member claims ---

// Claim sends amount ugnot of the caller's earned balance to the
// caller.
func Claim(cur realm, amount int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire earned balance to the caller.
func ClaimAll(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// --- administration ---

// SweepDenom recovers out-of-band coins to the sweeper. For the
// accounting denom the reserve is the full ledger liability — member
// balances are structurally unsweepable. Sweeper only.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	if cur.Previous().Address() != sweeper {
		panic("sweeper only")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = ledger.Liabilities()
	}
	swept := coinio.Sweep(0, cur, sweeper, denom, reserve)
	chain.Emit("SurplusSwept", "to", sweeper.String(), "coins", itoa(swept)+denom)
}

// TransferAdmin stages a two-step admin handover.
func TransferAdmin(cur realm, successor address) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	var zero address
	if successor == zero {
		panic("successor must not be the zero address")
	}
	pendingAdmin = successor
	chain.Emit("AdminTransferStaged", "from", admin.String(), "to", successor.String())
}

// AcceptAdmin completes the handover; only the staged successor may.
// The sweeper role moves with the admin.
func AcceptAdmin(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	if caller != pendingAdmin {
		panic("only the staged successor may accept")
	}
	old := admin
	admin = caller
	sweeper = caller
	var zero address
	pendingAdmin = zero
	chain.Emit("AdminTransferred", "from", old.String(), "to", admin.String())
}

// --- views ---

func Admin() address        { return admin }
func PendingAdmin() address { return pendingAdmin }
func MemberCount() int64    { return int64(len(members)) }
func TotalWeight() int64    { return totalWeight }
func MemberWeight(a address) int64 {
	i := indexOf(a)
	if i < 0 {
		panic("not a member")
	}
	return members[i].weight
}
func BalanceOf(a address) int64 { return ledger.BalanceOf(a.String()) }
func UsersTotal() int64         { return ledger.UsersTotal() }
func Pulled() int64             { return pulled }
func NumPlans() int64           { return int64(len(planIDs)) }
func PlanID(i int64) int64 {
	if i < 0 || i >= int64(len(planIDs)) {
		panic("plan index out of range")
	}
	return planIDs[i]
}
func Address() address { return self }
func Held() int64      { return coinio.HeldAt(self, Denom) }

// Receivable reads this realm's accrued, not-yet-pulled provider
// balance inside the subscriptions realm — the other side of value
// boundary B2. It is deliberately NOT part of Held or of the local
// conservation equation.
func Receivable() int64 { return subs.BalanceOf(self) }

// --- render ---

func Render(path string) string {
	if path != "" {
		return "unknown page; try the realm root"
	}
	out := "# revshare\n\n"
	out += "A team revenue realm: it is the PROVIDER of its " +
		"subscription plans, pulls accrued revenue across the realm " +
		"boundary, and splits it among weighted members into " +
		"pull-claimable balances.\n\n"
	out += "- receivable (in subscriptions): " + itoa(Receivable()) + Denom + "\n"
	out += "- held here: " + itoa(Held()) + Denom + "\n"
	out += "- earned, unclaimed: " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- lifetime pulled: " + itoa(pulled) + Denom + "\n"
	out += "- plans created here: " + itoa(int64(len(planIDs))) + "\n\n"
	out += "## members\n\n"
	if len(members) == 0 {
		out += "(none configured)\n"
		return out
	}
	out += "| member | weight | unclaimed |\n|---|---|---|\n"
	for _, m := range members {
		out += "| " + m.addr.String() + " | " + itoa(m.weight) + " | " +
			itoa(ledger.BalanceOf(m.addr.String())) + Denom + " |\n"
	}
	out += "\n(total weight " + itoa(totalWeight) + "; rounding dust " +
		"goes to the highest-weight member)\n"
	return out
}

// --- internals ---

func indexOf(a address) int {
	for i, m := range members {
		if m.addr == a {
			return i
		}
	}
	return -1
}

func assertNoSend() {
	if len(unsafe.OriginSend()) != 0 {
		panic("this function does not accept coins")
	}
}

func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
