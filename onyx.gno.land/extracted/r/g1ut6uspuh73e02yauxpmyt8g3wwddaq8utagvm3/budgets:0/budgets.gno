// Realm budgets is a delegated-budget treasury in GNOT: an owner funds a
// pool, grants named delegates a standing, rate-limited, revocable
// authority to spend from it, and each delegate then draws within that
// authority with no further approval from anyone.
//
// WHY THIS EXISTS (see DISCOVERY.md): every disbursement path on either
// live chain is one of three shapes — a fresh group decision per spend
// (this portfolio's treasury_board, gno.land's r/gov/dao/treasury, the
// mainnet bubbletreasury), a fixed schedule (vesting), or a pull against
// an already-settled entitlement (fee_split, revshare, crowdfund,
// subscriptions). None of them lets one party spend another's money at
// its own discretion within a bound. That is the gap, and
// bubbletreasury — a real mainnet treasury that hand-rolled a sliding
// spend window inside the realm, with every spend still a token-holder
// proposal — is the evidence someone wanted it.
//
// It is also, deliberately, the FIRST CONSUMER of spendbook on any
// chain. A primitive with no consumer has two properties unproven no
// matter how many unit tests pass: that its API is usable from a realm,
// and that its state survives across transactions. Only a realm can
// answer either, and this one is the answer.
//
// COMPOSITION: spending authority is delegated entirely to spendbook
// (anchored windows, lifetime caps, expiry, one-sided amendments,
// revocation), coin movement to coinio, per-delegate credit and the fee
// pot to feeledger, ordered storage to p/nt/avl/v0, and free-text render
// output to p/nt/markdown/sanitize/v0. This realm owns only the pool
// accounting, the grant records, and the solvency rule.
//
// # What a budget is, and what it is not
//
// A budget is AUTHORITY, not a reservation. Three grants of 100 against
// a pool of 100 are all three valid, and the first delegate to draw gets
// the money. This is not a defect to be fixed by reserving funds: a
// reservation would make an owner unable to grant a standing allowance
// without pre-committing the capital, which is the whole convenience
// being bought. What the realm guarantees instead is that it never
// PROMISES what it does not HOLD:
//
//	Draw refuses unless amount <= the owner's own unspent pool.
//
// So a delegate is told "no" at draw time rather than credited with
// something unclaimable. The pool is the solvency bound and it is
// per-owner, which is strictly stronger than a realm-wide check: one
// owner's grants can never reach another owner's funds.
//
// # Credit, then pull
//
// Draw moves nothing. It consumes the allowance, debits the owner's
// pool, and credits the delegate in the ledger; the delegate then signs
// a separate Claim to receive the coins. This is not ritual. If Draw
// paid out directly, a failing payout inside the same transaction would
// leave a consumed allowance with no money delivered, or force the
// allowance consumption to happen after an effect — and spendbook's own
// consumer contract item 3 says state first, effect second, for exactly
// that reason. Splitting it also means a delegate can draw repeatedly
// and claim once, which is cheaper than claiming per draw.
//
// # LIFECYCLE
//
//	Fund (owner, +send)       : adds real coins to the caller's own pool.
//	                            Anyone may fund; funding makes you an
//	                            owner. Minimum MinFunding.
//	WithdrawPool (owner)      : pulls unspent pool back out, any amount,
//	                            any time. See "the owner can always
//	                            leave" below.
//	WithdrawPoolAll (owner)   : the whole pool.
//	Grant (owner)             : opens one spendbook allowance for one
//	                            delegate and returns the grant id. The
//	                            draw fee is snapshotted here.
//	Amend (owner)             : changes the grant's terms. Tighter-or-
//	                            equal applies now; looser waits for the
//	                            next window boundary. PeriodLength is
//	                            NOT a parameter — spendbook makes it
//	                            immutable and this realm makes that
//	                            structural.
//	Revoke (owner)            : immediate, and the id is never reused.
//	Draw (DELEGATE)           : consumes authority, debits the pool,
//	                            credits the delegate net of the fee.
//	Claim (DELEGATE)          : pays the delegate's whole credit out.
//	Reap (ANYONE)             : removes an EXPIRED grant, freeing its
//	                            slot. Permissionless because an expired
//	                            allowance can authorize nothing, so
//	                            removing it takes nothing from anyone.
//	WithdrawFees (ANYONE)     : pays the fee pot to the compile-time
//	                            FeeCollector. Fixed destination, so
//	                            there is nothing to steer.
//	SweepSurplus (ANYONE)     : out-of-band coins to the FeeCollector,
//	                            never touching tracked liabilities.
//
// # The owner can always leave, and that is the design
//
// WithdrawPool has no lock, no notice period, and no check against
// outstanding grants. An owner can empty the pool under a live grant and
// the delegate's next Draw will fail on solvency. This is stated plainly
// rather than buried: the money is the owner's, Revoke is the clean way
// to end a relationship, and a realm that could trap an owner's capital
// behind a grant they regret would be a worse realm. A delegate who
// needs a guarantee of funds does not want a budget — they want escrow,
// which is a different artifact.
//
// What the owner CANNOT do is undo work already authorized: credit
// already drawn into the ledger is the delegate's, and Revoke does not
// claw it back. Revoking a grant ends future authority only.
//
// # THE FEE, precisely
//
// feeBps is snapshotted into the grant at Grant time from the
// compile-time DrawFeeBps, so a delegate's terms are fixed when the
// grant is created and visible in GrantInfo from that moment. The fee is
// charged ONCE per draw, on the gross amount, with feeledger's floor
// rounding (rounding favors the delegate). The owner's pool is debited
// the GROSS amount and the delegate is credited the net — the fee is
// paid by the owner out of the budget, not taken out of the delegate's
// authority, so a grant of PerPeriod means PerPeriod of the owner's
// money leaves the pool per window, which is the figure an owner
// actually cares about bounding. The ledger is constructed with the
// compile-time MaxFeeBps cap, so a fee above the cap is refused by the
// primitive, not by a check in this file. There is no fee on funding, on
// withdrawing an unspent pool, or on claiming.
//
// # THERE IS NO ADMIN
//
// The fee rate, the fee collector, every bound and every cap are
// compile-time constants. No address can change terms, pause the realm,
// touch a pool it did not fund, or move a grant it did not create. The
// deployer has no privilege of any kind after deployment.
//
// # MONETARY INVARIANT (conservation)
//
// Let H be the ugnot held at this realm's address, P the sum of all
// owner pools (tracked O(1) as totalPooled), L the ledger's liabilities
// (unclaimed delegate credit plus the fee pot), and S >= 0 the
// out-of-band surplus:
//
//	H == P + L + S
//
// Every transition moves value between exactly two terms inside one
// transaction. Fund raises H and P together (coinio.Receive is the
// receipt-guaranteed shape). WithdrawPool debits P before the identical
// amount leaves H. Draw moves gross out of P and into L, split into the
// delegate's credit and the fee — H does not move at all, which is why
// Draw has no payout to fail. Claim and WithdrawFees debit L before
// their payout. Any panic aborts the whole transaction; this realm never
// issues or removes coins.
//
// # ONLY GNOT IS ACCEPTED
//
// Fund rejects any envelope that is not exactly one positive ugnot coin
// (coinio.Receive). Every other entrypoint rejects attached coins
// outright rather than converting them into sweepable surplus.
//
// # AUTHORIZATION
//
// Every identity is derived from the crossing entrypoint's
// cur.Previous().Address(). No function takes a caller identity as a
// parameter, so funding another owner's pool, drawing another delegate's
// budget, claiming another delegate's credit, or amending a grant you do
// not own is impossible by construction. This is spendbook consumer
// contract item 2, closed structurally.
//
// The clock is runtime.ChainHeight(), never an argument. That is
// spendbook consumer contract item 1: a realm that let a caller choose
// `now` would have handed the delegate the power to roll the window at
// will, defeating every cap in the primitive.
//
// # STORAGE
//
// A pool entry is paid for by the owner's own funding transaction; a
// grant record and its allowance by the owner's Grant. Revoke and Reap
// both remove the grant record and the allowance in the same call, and
// the chain refunds the freed storage deposit to the transaction that
// frees it — which is the standing incentive to call Reap on someone
// else's expired grant.
package budgets

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/spendbook"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/budgets"

// Denom is the only asset this realm holds.
const Denom = "ugnot"

// MaxFeeBps is the hard ceiling on any draw fee this realm could ever
// charge, enforced by the feeledger the realm is constructed with — a
// feeBps above it is refused by the primitive's own validation, not by a
// check in this file. 500 bps = 5%.
const MaxFeeBps = int64(500)

// DrawFeeBps is the fee actually snapshotted into every grant: 100 bps =
// 1%, charged once per draw on the gross amount, floor-rounded in the
// delegate's favor. The most conservative live fee in this portfolio
// (fee_split, crowdfund) is also 1%.
const DrawFeeBps = int64(100)

// FeeCollector receives withdrawn fees and swept surplus. Compile-time
// constant: there is no setter and no transfer path. It is the deploying
// namespace's address — stated plainly: the operator of this realm.
const FeeCollector = address("g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3")

// MinFunding keeps dust pools out: 1 GNOT per Fund call.
const MinFunding = int64(1_000_000)

// MinPerPeriod is the smallest per-window cap a grant may carry. It
// exists so a grant cannot be created that no draw could ever satisfy,
// and it is the ONLY lower bound in the draw path — there is
// deliberately no minimum Draw amount, because a minimum draw above a
// grant's PerPeriod would make the grant silently undrawable.
const MinPerPeriod = int64(1_000)

// MinPeriodBlocks is the shortest rolling window a grant may use. A
// window of a handful of blocks is a rate, not a budget, and it makes
// PerPeriod meaningless as a bound on worst-case loss. A periodLength of
// 0 is still accepted and means ONE LIFETIME WINDOW that never refills
// (spendbook's own semantics).
const MinPeriodBlocks = int64(100)

// MaxLiveGrants caps simultaneously live grants, via spendbook's own
// construction bound. Grant is permissionless to anyone with a funded
// pool, so the cap is exhaustible in principle, and that AVAILABILITY
// BOUND is documented rather than hidden.
//
// It is documented here in its CORRECTED form. An earlier version of
// this comment claimed the mitigation was "MaxGrantsPerOwner plus the
// cost of becoming an owner at all (MinFunding per pool), and Reap is
// permissionless so expired grants cannot accumulate". An adversarial
// audit (finding Y1, DISCOVERY.md § 9) showed BOTH HALVES were false. A
// wrong mitigation is worse than an acknowledged bound, because a reader
// sizes the risk from it and stops looking:
//
//   - MinFunding is NOT a capital bound. The funded-pool requirement is
//     checked at Grant time only, and WithdrawPool has no lock, so one
//     address funds a pool, opens MaxGrantsPerOwner grants, withdraws
//     the pool in full, and the grants survive holding their slots.
//     TestOwnerCanAlwaysLeave pins exactly that sequence, as intended
//     behavior — the attack is built out of a documented feature.
//   - Reap is inert against it. Reap requires spendbook's IsExpired,
//     which is never true for expiresAt == 0, so an attacker omits the
//     expiry and no third party can remove the grant.
//
// What the cost ACTUALLY is: gas for one Fund, MaxGrantsPerOwner Grants
// and one WithdrawPoolAll per address — about MaxLiveGrants*17/16
// transactions to fill the cap — plus the storage deposit on every grant
// record, which the chain holds for as long as the grant does and
// refunds only when it is removed. That is real and unrecoverable while
// the grief lasts. It is not the locked pool capital the old comment
// promised, and it is priced in gas and storage rather than in capital.
//
// No capital bound was added, because the obvious one does not work.
// Requiring an owner with live grants to retain MinFunding is defeated
// for the price of the draw fee: nothing forbids granting to YOURSELF,
// so the attacker draws its own pool to zero through its own grant and
// Claims the credit back, recovering all but DrawFeeBps of it while the
// retention rule still reads as satisfied. Closing THAT would mean
// bounding Draw below MinFunding — the realm refusing to let a delegate
// spend the budget, which is the feature. The remaining alternative, a
// non-refundable per-grant fee, taxes every honest owner to price a
// grief, and at a fee high enough to deter one it is a tenth of
// MinFunding per grant.
//
// The blast radius is narrow and that is the reason this is disclosed
// rather than redesigned: a full book blocks NEW grants only. Every
// existing grant, pool, draw, credit and claim keeps working, no value
// is at risk, and any owner can free their own slots with Revoke.
//
// The figure was 1024 until that audit, and 1024 was conservative rather
// than measured: nothing in this realm iterates the book (Render is
// bounded by MaxRenderRows, every write path is a single avl lookup) and
// a grant record's storage is paid for by whoever creates it.
// Quadrupling it quadruples the cost of filling the cap and costs an
// honest owner nothing. spendbook's own MaxLiveLimit is 10000.
const MaxLiveGrants = 4096

// MaxGrantsPerOwner bounds how much of the global cap one owner can
// occupy. spendbook's own package documentation names this as the gap a
// consuming realm must close — "maxLive is a single global figure, so
// any owner permitted to Open can exhaust it and lock out the rest …
// the consuming realm decides who may Open, and a Book shared across
// mutually untrusting owners needs its own per-owner cap on top of this
// one." This is that cap. (permission_registry finding R1 is the same
// lesson from this portfolio's own history.)
const MaxGrantsPerOwner = int64(16)

// MaxLabelLen bounds the grant's free-text label, which is sanitized
// before reaching markdown.
const MaxLabelLen = 64

// MaxRenderRows bounds the grant list on the index page.
const MaxRenderRows = 20

type grant struct {
	id        int64
	owner     address
	spender   address
	allowID   uint64 // the spendbook allowance backing this grant
	feeBps    int64  // snapshotted at Grant
	label     string
	createdAt int64

	drawn int64 // lifetime gross drawn under this grant
	draws int64 // number of successful draws
}

var (
	self address

	// grants holds one record per live grant. Revoke and Reap remove the
	// record; ids are never reused.
	grants = avl.NewTree() // padID(id) -> *grant
	nextID int64

	// pools is each owner's unspent funded balance:
	// address string -> int64 (> 0). This is the P term.
	pools = avl.NewTree()

	// openByOwner tracks each owner's live grant count:
	// address string -> int64 (> 0).
	openByOwner = avl.NewTree()

	// totalPooled is the P term of H == P + L + S, maintained O(1).
	totalPooled int64

	// lifetime counters, rendered for operators.
	lifetimeFunded   int64
	lifetimeDrawn    int64 // gross, before the fee
	lifetimeClaimed  int64 // net, paid to delegates
	lifetimeReturned int64 // unspent pool withdrawn by owners

	// ledger holds each delegate's unclaimed credit and the fee pot. Its
	// Liabilities() is the L term and the reserve SweepSurplus protects.
	ledger = feeledger.MustNew(MaxFeeBps)

	// book holds one live allowance per live grant. Every bound on
	// authority — windows, caps, expiry, amendment direction — is the
	// primitive's, not this file's.
	book = spendbook.MustNew(MaxLiveGrants)
)

func init() {
	self = unsafe.CurrentRealm().Address()
}

// rejectStraySend aborts when coins are attached to a non-payable call.
// This realm holds funds, so a stray send would become sweepable
// surplus, silently converting a user's coins into operator funds.
// Aborting reverts the transfer instead. Guarded on IsUserCall, not
// IsUser, because a MsgRun ephemeral can consume the OriginSend envelope
// before forwarding control; for a realm-routed call the envelope lands
// at the intermediary, so there is nothing here to reject and the guard
// deliberately fails open (crowdfund and treasury_board document the
// same scope).
func rejectStraySend(cur realm) {
	if !cur.IsCurrent() {
		// Every call site forwards a crossing entrypoint's own live cur,
		// so this cannot fire today; it exists so a future refactor that
		// hands this guard a stale realm value fails closed, not open
		// (coinio names IsCurrent as the guard secondary realm
		// parameters require, and this helper follows that discipline).
		panic("budgets: realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// --- the pool ---

// Fund adds the attached coins to the caller's own pool. Direct EOA
// calls with -send only (the receipt-guaranteed shape); exactly one
// positive ugnot coin, at least MinFunding. Anyone may fund; funding is
// what makes an address an owner.
func Fund(cur realm) int64 {
	owner, amount := coinio.Receive(0, cur, Denom)
	if amount < MinFunding {
		panic("fund at least " + itoa(MinFunding) + Denom)
	}
	key := owner.String()

	newPool, ok := checkedAdd(poolOf(key), amount)
	if !ok {
		panic("pool would overflow")
	}
	newTotal, ok := checkedAdd(totalPooled, amount)
	if !ok {
		panic("total pooled would overflow")
	}
	newLifetime, ok := checkedAdd(lifetimeFunded, amount)
	if !ok {
		panic("lifetime funded would overflow")
	}

	setPool(key, newPool)
	totalPooled = newTotal
	lifetimeFunded = newLifetime

	chain.Emit("Funded", "owner", key, "amount", itoa(amount),
		"pool", itoa(newPool))
	return newPool
}

// WithdrawPool returns part of the caller's unspent pool and reports the
// pool REMAINING afterwards. There is no lock and no check against
// outstanding grants: the money is the owner's, and a delegate's
// authority is not a claim on it (see the package doc, "the owner can
// always leave"). Revoke is the clean way to end a grant.
func WithdrawPool(cur realm, amount int64) int64 {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	if amount <= 0 {
		panic("amount must be positive")
	}
	return payOutPool(cur, owner, amount)
}

// WithdrawPoolAll returns the caller's entire unspent pool and reports the
// amount WITHDRAWN.
//
// The return values of the two withdraw entrypoints are deliberately
// asymmetric, which is worth naming rather than letting a caller discover:
// each returns the figure its caller does not already have. WithdrawPool
// was told the amount and wants to know what is left; WithdrawPoolAll
// knows what is left (nothing) and wants to know what it got. Returning
// the remainder here would hand every caller a constant 0.
func WithdrawPoolAll(cur realm) int64 {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	amount := poolOf(owner.String())
	if amount == 0 {
		panic("no pool to withdraw")
	}
	payOutPool(cur, owner, amount)
	return amount
}

// payOutPool is the shared debit-then-send path: the pool and the P term
// are reduced before the identical amount leaves the realm
// (checks-effects-interactions).
func payOutPool(cur realm, owner address, amount int64) int64 {
	key := owner.String()
	pool := poolOf(key)
	if amount > pool {
		panic("amount exceeds pool")
	}
	newReturned, ok := checkedAdd(lifetimeReturned, amount)
	if !ok {
		panic("lifetime returned would overflow")
	}

	setPool(key, pool-amount)
	totalPooled -= amount
	lifetimeReturned = newReturned

	coinio.Payout(0, cur, owner, Denom, amount)

	chain.Emit("PoolWithdrawn", "owner", key, "amount", itoa(amount),
		"pool", itoa(pool-amount))
	return pool - amount
}

// --- grants ---

// Grant opens a standing spending authority for one delegate and returns
// the grant id. The caller becomes the grant's owner and must already
// have a funded pool — not because the grant reserves anything (it does
// not), but because a grant from an address that has never funded
// anything is a promise with nothing behind it, and this realm declines
// to record one.
//
// Terms, all in the chain's own units:
//
//	perPeriod    the cap per window, at least MinPerPeriod. Required.
//	periodLength blocks per window. 0 means ONE LIFETIME WINDOW that
//	             never refills; otherwise at least MinPeriodBlocks.
//	total        lifetime cap across every window. 0 means unlimited.
//	expiresAt    absolute block height at which authority ends. 0 means
//	             no expiry.
//
// Every bound above except the two realm minimums is validated and
// enforced by spendbook, and an invalid combination surfaces as that
// package's own sentinel error.
func Grant(cur realm, spender address, label string,
	perPeriod, periodLength, total, expiresAt int64) int64 {
	rejectStraySend(cur)
	owner := cur.Previous().Address()

	// The lowercase clause is load-bearing, not decoration, and the reason
	// was measured on this toolchain rather than argued: address.IsValid()
	// defers to crypto.AddressFromBech32, whose decoder lowercases the
	// input BEFORE verifying the checksum, so it returns true for the
	// all-uppercase spelling of a valid address. Here the hazard is not a
	// double count (as in fee_split/v2 and treasury_board, where the
	// address was a vote-bearing key) but a BRICKED GRANT: Draw
	// authenticates against cur.Previous().Address(), which is always
	// canonical, so an uppercase-spelled delegate could never draw, while
	// the grant still occupied a MaxGrantsPerOwner slot and a storage
	// deposit. The check is complete as well as necessary — that decoder
	// rejects mixed case outright, so a valid address has exactly two
	// spellings and rejecting every non-lower one leaves precisely the
	// canonical one.
	if !spender.IsValid() || string(spender) != strings.ToLower(string(spender)) {
		panic("spender is not a valid address in canonical (lowercase) form")
	}
	if len(label) > MaxLabelLen {
		panic("label exceeds " + strconv.Itoa(MaxLabelLen) + " bytes")
	}
	if perPeriod < MinPerPeriod {
		panic("perPeriod must be at least " + itoa(MinPerPeriod) + Denom)
	}
	if periodLength != 0 && periodLength < MinPeriodBlocks {
		panic("periodLength must be 0 (lifetime) or at least " +
			itoa(MinPeriodBlocks) + " blocks")
	}

	key := owner.String()
	if poolOf(key) == 0 {
		panic("fund a pool before granting")
	}
	if ownerOpen(key) >= MaxGrantsPerOwner {
		panic("owner already has " + itoa(MaxGrantsPerOwner) + " live grants")
	}

	now := runtime.ChainHeight()
	allowID, err := book.Open(key, spender.String(), now, spendbook.Terms{
		PerPeriod:    perPeriod,
		PeriodLength: periodLength,
		Total:        total,
		ExpiresAt:    expiresAt,
	})
	if err != nil {
		panic(err)
	}

	id := nextID + 1
	nextID = id
	grants.Set(padID(id), &grant{
		id:        id,
		owner:     owner,
		spender:   spender,
		allowID:   allowID,
		feeBps:    DrawFeeBps,
		label:     label,
		createdAt: now,
	})
	setOwnerOpen(key, ownerOpen(key)+1)

	chain.Emit("Granted", "id", itoa(id), "owner", key,
		"spender", spender.String(), "perPeriod", itoa(perPeriod),
		"periodLength", itoa(periodLength), "total", itoa(total),
		"expiresAt", itoa(expiresAt), "feeBps", itoa(DrawFeeBps))
	return id
}

// Amend changes a grant's terms. Owner only. The returned bool reports
// whether the new terms are in force NOW (a tighter-or-equal amendment)
// or queued for the next window boundary (a looser one) — spendbook's
// one-sided rule, and the distinction worth knowing.
//
// periodLength is NOT a parameter. spendbook makes it immutable because
// moving it would move every future boundary, which is an enlargement
// vector wearing a different hat; this realm reads the grant's own
// periodLength and passes it unchanged, so changing it is not merely
// refused, it is unexpressible.
func Amend(cur realm, id int64, perPeriod, total, expiresAt int64) bool {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	g := mustGet(id)
	if owner != g.owner {
		panic("owner only")
	}
	if perPeriod < MinPerPeriod {
		panic("perPeriod must be at least " + itoa(MinPerPeriod) + Denom)
	}

	a, err := book.Get(g.allowID)
	if err != nil {
		panic(err)
	}
	applied, err := book.Amend(g.allowID, owner.String(), runtime.ChainHeight(),
		spendbook.Terms{
			PerPeriod:    perPeriod,
			PeriodLength: a.Terms.PeriodLength, // immutable
			Total:        total,
			ExpiresAt:    expiresAt,
		})
	if err != nil {
		panic(err)
	}

	chain.Emit("Amended", "id", itoa(g.id), "owner", owner.String(),
		"perPeriod", itoa(perPeriod), "total", itoa(total),
		"expiresAt", itoa(expiresAt), "applied", boolstr(applied))
	return applied
}

// Revoke ends a grant immediately. Owner only. The id is never reused,
// so a revoked grant cannot be resurrected and a later Draw against it
// fails as unknown.
//
// Revoking does NOT claw back credit the delegate has already drawn —
// that is theirs and stays claimable. Revoke ends future authority.
func Revoke(cur realm, id int64) {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	g := mustGet(id)
	if owner != g.owner {
		panic("owner only")
	}
	// Owner-gated twice on purpose: the check above is for the error
	// message, the primitive's is the authoritative one.
	if err := book.Revoke(g.allowID, owner.String()); err != nil {
		panic(err)
	}
	drop(g)

	chain.Emit("Revoked", "id", itoa(g.id), "owner", owner.String(),
		"spender", g.spender.String(), "drawn", itoa(g.drawn))
}

// Reap removes a grant whose authority has EXPIRED, freeing its slot and
// its storage. Anyone may call it, and the reasoning is spendbook's own:
// an expired allowance can never authorize another draw, so removing it
// takes nothing from the owner and grants nothing to the caller. The
// chain refunds the freed storage deposit to the reaping transaction,
// which is the standing incentive.
//
// A grant with no expiry can never be reaped; only its owner can end it.
func Reap(cur realm, id int64) {
	rejectStraySend(cur)
	g := mustGet(id)
	if err := book.Reap(g.allowID, runtime.ChainHeight()); err != nil {
		panic(err)
	}
	drop(g)

	chain.Emit("Reaped", "id", itoa(g.id), "owner", g.owner.String(),
		"by", cur.Previous().Address().String())
}

// --- drawing ---

// Draw spends amount from the grant's budget. DELEGATE ONLY: the spender
// is the calling address, never an argument. Nothing is paid out here —
// the delegate is credited net of the fee and claims separately.
//
// Three things must all hold and they fail in this order, which matters:
// the caller must be the grant's delegate and the amount must be within
// every spendbook bound (window cap, lifetime cap, expiry, start); and
// the owner's pool must cover the GROSS amount. The solvency check runs
// BEFORE the allowance is consumed, so a draw refused for insolvency
// leaves the budget untouched rather than burning window capacity on a
// draw that did not happen.
func Draw(cur realm, id int64, amount int64) int64 {
	rejectStraySend(cur)
	spender := cur.Previous().Address()
	g := mustGet(id)
	if spender != g.spender {
		panic("delegate only")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}

	ownerKey := g.owner.String()
	pool := poolOf(ownerKey)
	if amount > pool {
		// A budget is authority, not a reservation (package doc). The
		// honest failure is here, at draw time, rather than a credit the
		// delegate could not claim.
		panic("owner's pool cannot cover this draw")
	}

	// Authority. spendbook checks every bound and CONSUMES the allowance
	// in this one call, before returning; on any error nothing is
	// consumed. Its sentinel errors name the reason.
	if err := book.Spend(g.allowID, spender.String(),
		runtime.ChainHeight(), amount); err != nil {
		panic(err)
	}

	newDrawn, ok := checkedAdd(g.drawn, amount)
	if !ok {
		panic("grant drawn total would overflow")
	}
	newLifetime, ok := checkedAdd(lifetimeDrawn, amount)
	if !ok {
		panic("lifetime drawn would overflow")
	}

	// Move the gross out of P and into L. H does not move, which is why
	// this transition has no payout to fail.
	setPool(ownerKey, pool-amount)
	totalPooled -= amount
	credited, fee := ledger.MustDeposit(spender.String(), amount, g.feeBps)
	g.drawn = newDrawn
	g.draws++
	lifetimeDrawn = newLifetime

	chain.Emit("Drawn", "id", itoa(g.id), "spender", spender.String(),
		"gross", itoa(amount), "credited", itoa(credited), "fee", itoa(fee),
		"pool", itoa(pool-amount))
	return credited
}

// Claim pays the caller's entire accrued credit out. DELEGATE ONLY: the
// account is the calling address. Credit from a grant that has since
// been revoked, expired or reaped is still claimable — it was earned
// under a live authority and this realm does not revisit that.
func Claim(cur realm) int64 {
	rejectStraySend(cur)
	account := cur.Previous().Address()
	key := account.String()

	amount, err := ledger.WithdrawAll(key)
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("no credit to claim")
	}
	newClaimed, ok := checkedAdd(lifetimeClaimed, amount)
	if !ok {
		panic("lifetime claimed would overflow")
	}
	lifetimeClaimed = newClaimed

	coinio.Payout(0, cur, account, Denom, amount)

	chain.Emit("Claimed", "account", key, "amount", itoa(amount))
	return amount
}

// --- fees and surplus ---

// WithdrawFees pays the entire accrued fee pot to the compile-time
// FeeCollector. Anyone may call it: the destination is fixed, so there
// is nothing for a caller to steer.
func WithdrawFees(cur realm) int64 {
	rejectStraySend(cur)
	fees := ledger.WithdrawFees()
	if fees == 0 {
		panic("no fees accrued")
	}
	coinio.Payout(0, cur, FeeCollector, Denom, fees)
	chain.Emit("FeesWithdrawn", "to", FeeCollector.String(), "amount", itoa(fees))
	return fees
}

// SweepSurplus sends out-of-band coins to the FeeCollector: for the pool
// denom, everything above tracked liabilities; for any foreign denom,
// the full balance. Owner pools, delegate credit and the fee pot are
// untouchable by construction (coinio.Sweep refuses to dip below the
// reserve). Anyone may call it.
//
// With nothing out of band this ABORTS ("coinio: no surplus to sweep for
// <denom>") rather than returning 0. That is the primitive's choice and
// the right one: a sweep is a transfer, and a transfer of nothing that
// reports success is how a caller comes to believe a balance was moved.
func SweepSurplus(cur realm, denom string) int64 {
	rejectStraySend(cur)
	reserve := int64(0)
	if denom == Denom {
		reserve = Liabilities()
	}
	swept := coinio.Sweep(0, cur, FeeCollector, denom, reserve)
	chain.Emit("Swept", "denom", denom, "to", FeeCollector.String(),
		"amount", itoa(swept))
	return swept
}

// --- views ---

// GrantInfo returns a grant's parties and the terms currently recorded
// for it. perPeriod reflects a tightening amendment immediately; a
// queued loosening shows in PendingTerms until its boundary arrives.
func GrantInfo(id int64) (owner, spender address, perPeriod, periodLength,
	total, expiresAt, anchor, createdAt, feeBps int64) {
	g := mustGet(id)
	a := mustAllowance(g)
	return g.owner, g.spender, a.Terms.PerPeriod, a.Terms.PeriodLength,
		a.Terms.Total, a.Terms.ExpiresAt, a.Anchor, g.createdAt, g.feeBps
}

// GrantUsage returns a grant's consumption AT THE CURRENT HEIGHT: what the
// window the chain is in right now has spent, the lifetime gross, that
// window's index, and how many draws there have been.
//
// The two window figures are computed rather than read straight off the
// record, and that is the whole point of windowAt below: a window that has
// rolled with no draw since leaves Allowance.WindowIndex naming a window
// the chain has already left, and Allowance.SpentWindow holding the
// previous window's spend. spentTotal and draws are cumulative and never
// go stale.
func GrantUsage(id int64) (spentWindow, spentTotal, windowIndex, draws int64) {
	g := mustGet(id)
	a := mustAllowance(g)
	now := runtime.ChainHeight()
	return spentInWindow(a, now), a.SpentTotal, windowAt(a, now), g.draws
}

// GrantLabel returns a grant's raw label (unsanitized: callers rendering
// it into markdown must sanitize, as this realm's Render does).
func GrantLabel(id int64) string { return mustGet(id).label }

// Remaining is the AUTHORITY figure: what the grant's terms permit right
// now, ignoring whether the owner's pool can cover it.
func Remaining(id int64) int64 {
	g := mustGet(id)
	return book.Remaining(g.allowID, runtime.ChainHeight())
}

// Drawable is the HONEST figure, and the one a delegate should read: the
// lesser of what the grant authorizes and what the owner's pool holds.
// This distinction is the realm's own — spendbook bounds permission and
// says so, never solvency.
func Drawable(id int64) int64 {
	g := mustGet(id)
	authorized := book.Remaining(g.allowID, runtime.ChainHeight())
	pool := poolOf(g.owner.String())
	if pool < authorized {
		return pool
	}
	return authorized
}

// PendingTerms returns a queued loosening amendment and whether there is
// one. An amendment is queued only when it would widen the live window,
// and it takes effect at the next window boundary.
func PendingTerms(id int64) (perPeriod, total, expiresAt int64, pending bool) {
	a := mustAllowance(mustGet(id))
	if !a.HasPending {
		return 0, 0, 0, false
	}
	return a.Pending.PerPeriod, a.Pending.Total, a.Pending.ExpiresAt, true
}

// IsExpired reports whether a grant's authority has lapsed, which is
// also the condition under which anyone may Reap it.
func IsExpired(id int64) bool {
	return mustAllowance(mustGet(id)).IsExpired(runtime.ChainHeight())
}

// PoolOf returns an owner's unspent pool.
func PoolOf(addr address) int64 { return poolOf(addr.String()) }

// CreditOf returns a delegate's drawn-but-unclaimed credit.
func CreditOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// GrantsOf returns how many live grants an owner currently holds.
func GrantsOf(addr address) int64 { return ownerOpen(addr.String()) }

// NumGrants returns how many grants have ever been created. Ids are
// never reused, so this only grows.
func NumGrants() int64 { return nextID }

// LiveGrants returns how many grants are currently live, from the
// primitive's own count.
func LiveGrants() int64 { return int64(book.Count()) }

// TotalPooled returns the P term: unspent owner funds.
func TotalPooled() int64 { return totalPooled }

// UnclaimedCredit returns the delegates' share of the L term.
func UnclaimedCredit() int64 { return ledger.UsersTotal() }

// FeesAccrued returns the fee pot: charged, not yet withdrawn.
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns P + L — everything this realm owes.
func Liabilities() int64 { return totalPooled + ledger.Liabilities() }

// Held returns H: the ugnot actually at this realm's address.
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns H - (P + L) — out-of-band coins, sweepable.
func Surplus() int64 { return Held() - Liabilities() }

// Address returns this realm's own address.
func Address() address { return self }

// Height returns the current chain height: the clock every window and
// expiry is measured against, and the one no caller can choose.
func Height() int64 { return runtime.ChainHeight() }

// --- render ---

// Render shows the realm at "" and a grant page at "<id>". Labels are
// free text and pass through the ecosystem sanitizer before hitting
// markdown.
func Render(path string) string {
	if path != "" {
		return renderGrant(path)
	}
	now := runtime.ChainHeight()
	held := Held()
	liab := Liabilities()
	conservation := "OK"
	if held < liab {
		conservation = "VIOLATED"
	}

	out := "# Budgets\n\n"
	out += "Delegated spending in GNOT. Fund a pool, grant a delegate a " +
		"standing rate-limited authority over it, and they draw within " +
		"that bound without asking anyone. Revocable immediately; the " +
		"windows are anchored, so nobody resets a cap by choosing when " +
		"to call.\n\n"
	out += "## Terms (fixed at deploy; no admin, no setters)\n\n"
	out += "- draw fee: " + bps(DrawFeeBps) + " of the gross draw, paid from the owner's budget (hard cap " + bps(MaxFeeBps) + ")\n"
	out += "- no fee on funding, on withdrawing an unspent pool, or on claiming\n"
	out += "- minimum funding: " + itoa(MinFunding) + Denom + " per call\n"
	out += "- minimum per-window cap: " + itoa(MinPerPeriod) + Denom + "\n"
	out += "- window length: 0 (one lifetime window) or at least " + itoa(MinPeriodBlocks) + " blocks\n"
	out += "- live grants: " + itoa(LiveGrants()) + " of " + strconv.Itoa(MaxLiveGrants) +
		" (per owner: " + itoa(MaxGrantsPerOwner) + ")\n"
	out += "- current height: " + itoa(now) + "\n\n"
	out += "## Accounting (H == P + L + S)\n\n"
	out += "- pooled (P): " + itoa(totalPooled) + Denom + "\n"
	out += "- unclaimed delegate credit: " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fee pot: " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- surplus (S): " + itoa(held-liab) + Denom + "\n"
	out += "- conservation: " + conservation + "\n"
	out += "- lifetime funded / drawn / claimed / returned: " +
		itoa(lifetimeFunded) + " / " + itoa(lifetimeDrawn) + " / " +
		itoa(lifetimeClaimed) + " / " + itoa(lifetimeReturned) + Denom + "\n\n"
	out += "## Live grants\n\n"
	if grants.Size() == 0 {
		out += "None yet. Fund a pool, then Grant a delegate.\n"
	} else {
		shown := 0
		expired := 0
		grants.ReverseIterate("", "", func(_ string, v any) bool {
			g := v.(*grant)
			a, aerr := book.Get(g.allowID)
			state := "live"
			if aerr != nil {
				state = "missing"
			} else if a.IsExpired(now) {
				state = "expired (reapable)"
				expired++
			}
			out += "- [#" + itoa(g.id) + "](" + RealmPath + ":" + itoa(g.id) +
				") [" + state + "] " + sanitize.InlineText(labelOr(g)) +
				" — drawable " + itoa(Drawable(g.id)) + Denom + "\n"
			shown++
			return shown >= MaxRenderRows
		})
		if shown < grants.Size() {
			out += "\n> [!NOTE]\n> Showing the " + strconv.Itoa(shown) +
				" most recent of " + strconv.Itoa(grants.Size()) +
				" live grants (" + itoa(nextID) +
				" ever created; revoked and reaped records are removed). " +
				"Use GrantInfo(id) for any specific grant.\n"
		}
		if expired > 0 {
			out += "\n## Keeper work\n\nAnyone may Reap(id) an expired grant " +
				"to free its slot and reclaim its storage deposit: " +
				strconv.Itoa(expired) + " of the grants above are reapable.\n"
		}
	}
	return out
}

func renderGrant(path string) string {
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid grant id\n"
	}
	v := grants.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown grant id (never created, or revoked/reaped)\n"
	}
	g := v.(*grant)
	a, gerr := book.Get(g.allowID)
	if gerr != nil {
		// Unreachable: drop() removes the record and the allowance
		// together, in one call. Rendered rather than panicked so a
		// corrupted pair is visible instead of breaking the page.
		return "> [!CAUTION]\n> grant #" + itoa(g.id) +
			" has no backing allowance; this is a bug. Reason: " +
			sanitize.InlineText(gerr.Error()) + "\n"
	}
	now := runtime.ChainHeight()

	out := "# Grant #" + itoa(g.id)
	if g.label != "" {
		out += ": " + sanitize.InlineText(g.label)
	}
	out += "\n\n"
	out += "- owner: `" + g.owner.String() + "`\n"
	out += "- delegate: `" + g.spender.String() + "`\n"
	out += "- per-window cap: " + itoa(a.Terms.PerPeriod) + Denom + "\n"
	if a.Terms.PeriodLength == 0 {
		out += "- window: one lifetime window; the cap never refills\n"
	} else {
		out += "- window: " + itoa(a.Terms.PeriodLength) +
			" blocks, anchored at " + itoa(a.Anchor) +
			" (now in window " + itoa(windowAt(a, now)) + ")\n"
	}
	if a.Terms.Total == 0 {
		out += "- lifetime cap: none\n"
	} else {
		out += "- lifetime cap: " + itoa(a.Terms.Total) + Denom +
			" (" + itoa(a.SpentTotal) + " used)\n"
	}
	if a.Terms.ExpiresAt == 0 {
		out += "- expiry: none (only the owner can end it)\n"
	} else {
		out += "- expiry: block " + itoa(a.Terms.ExpiresAt) + "\n"
	}
	out += "- draw fee: " + bps(g.feeBps) + " (snapshotted at grant time)\n"
	out += "- spent this window: " + itoa(spentInWindow(a, now)) + Denom + "\n"
	out += "- drawn in total: " + itoa(g.drawn) + Denom + " over " +
		itoa(g.draws) + " draws\n"
	out += "- created at block: " + itoa(g.createdAt) + "\n"
	out += "- current height: " + itoa(now) + "\n\n"

	authorized := a.Remaining(now)
	pool := poolOf(g.owner.String())
	out += "## What can be drawn right now\n\n"
	out += "- authorized by the terms: " + itoa(authorized) + Denom + "\n"
	out += "- owner's unspent pool: " + itoa(pool) + Denom + "\n"
	drawable := authorized
	if pool < drawable {
		drawable = pool
	}
	out += "- **drawable: " + itoa(drawable) + Denom + "** (the lesser of the two)\n\n"

	switch {
	case a.IsExpired(now):
		out += "This grant has **expired**. Anyone may Reap(" + itoa(g.id) +
			") to free its slot and reclaim its storage deposit.\n"
	case drawable == 0 && authorized == 0:
		out += "Nothing authorized at this height — the window cap is spent, " +
			"the lifetime cap is reached, or the grant has not started.\n"
	case drawable == 0:
		out += "Authorized but **not funded**: the owner's pool cannot cover " +
			"a draw. A budget is authority, not a reservation.\n"
	default:
		out += "The delegate may Draw(" + itoa(g.id) + ", amount) up to the " +
			"drawable figure, then Claim() to receive it.\n"
	}
	if a.HasPending {
		out += "\n> [!NOTE]\n> A **looser** amendment is queued and takes " +
			"effect at the next window boundary: per-window cap " +
			itoa(a.Pending.PerPeriod) + Denom + ", lifetime cap " +
			itoa(a.Pending.Total) + ", expiry " + itoa(a.Pending.ExpiresAt) +
			" (0 means none). Until then the terms above are what govern.\n"
	}
	return out
}

// --- internals ---

func mustGet(id int64) *grant {
	v := grants.Get(padID(id))
	if v == nil {
		panic("unknown grant id")
	}
	return v.(*grant)
}

// mustAllowance fetches the spendbook allowance behind a grant. The pair
// is created and removed together, so a missing allowance is a bug in
// this realm rather than a user error, and it panics rather than
// reporting a zero value that a reader would take for "no authority".
func mustAllowance(g *grant) spendbook.Allowance {
	a, err := book.Get(g.allowID)
	if err != nil {
		panic(err)
	}
	return a
}

// windowAt returns the anchored window index containing now, and
// spentInWindow what that window has spent.
//
// These duplicate a line of spendbook, and the duplication is deliberate,
// bounded, and worth justifying because the primitive's own at() comment
// warns against exactly this. What is NOT reimplemented is the part that
// warning is about: which terms are in force after a boundary, and
// therefore every authority figure this realm reports — Remaining and
// Drawable both call through to the primitive, and nothing here second-
// guesses them.
//
// What is copied is pure index arithmetic over three EXPORTED fields plus
// the already-documented fact that the in-window spend RESETS rather than
// carries. The alternative is worse than the duplication: Allowance's
// WindowIndex and SpentWindow are the last-WRITTEN pair, so between a
// boundary and the next draw they describe a window the chain has left, and
// a Render publishing them would print "spent this window: 100000"
// immediately above "authorized by the terms: 100000".
//
// The two are pinned to the primitive by TestWindowRefillsAtAnchoredBoundary
// rather than by inspection: it draws after crossing a boundary and asserts
// spentWindow equals that draw, which can only hold if windowAt agreed with
// spendbook's own index at the moment of the write.
func windowAt(a spendbook.Allowance, now int64) int64 {
	if a.Terms.PeriodLength == 0 || now < a.Anchor {
		return 0
	}
	return (now - a.Anchor) / a.Terms.PeriodLength
}

func spentInWindow(a spendbook.Allowance, now int64) int64 {
	if windowAt(a, now) != a.WindowIndex {
		return 0
	}
	return a.SpentWindow
}

// drop removes a grant record and decrements its owner's live count. The
// allowance itself is removed by the spendbook call that precedes every
// caller of this helper.
func drop(g *grant) {
	grants.Remove(padID(g.id))
	decOwnerOpen(g.owner.String())
}

func labelOr(g *grant) string {
	if g.label == "" {
		return "(no label)"
	}
	return g.label
}

func poolOf(key string) int64 {
	v := pools.Get(key)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func setPool(key string, n int64) {
	if n <= 0 {
		pools.Remove(key)
		return
	}
	pools.Set(key, n)
}

func ownerOpen(key string) int64 {
	v := openByOwner.Get(key)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func setOwnerOpen(key string, n int64) {
	if n <= 0 {
		openByOwner.Remove(key)
		return
	}
	openByOwner.Set(key, n)
}

func decOwnerOpen(key string) { setOwnerOpen(key, ownerOpen(key)-1) }

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func boolstr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// bps renders a basis-point figure as a human percentage, exactly.
func bps(n int64) string {
	whole := n / 100
	frac := n % 100
	if frac == 0 {
		return itoa(whole) + "%"
	}
	if frac%10 == 0 {
		return itoa(whole) + "." + itoa(frac/10) + "%"
	}
	pad := ""
	if frac < 10 {
		pad = "0"
	}
	return itoa(whole) + "." + pad + itoa(frac) + "%"
}

// padID encodes an id so avl's lexical order matches numeric order.
func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	const width = 20
	if len(s) >= width {
		return s
	}
	return zeros[:width-len(s)] + s
}

const zeros = "00000000000000000000"

// checkedAdd returns a+b and reports whether the addition did not
// overflow int64.
func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
