package core

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069/sinopia/safe/v1"
	"gno.land/p/g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069/sinopia/types/v1"
)

// Admin (design §2.5.2, §7.5). The admin can only change the parameters
// listed in validateOp, each inside a hard cap, after a public timelock;
// it can pause new activity for a bounded time. It can never move, approve
// or burn a token, touch a collection's configuration, or receive funds
// (I-1). With no collection yet there is nothing to protect, so ops execute
// without delay — that is how the platform is configured after deploy.
//
// TODO(mainnet): the initial admin and treasury must be the 2/3 multisig.
// SA-I6: CreateFee starts at 0 here so tests and bootstrap stay simple;
// scripts/deploy-onyx.sh sets a non-zero fee.create during bootstrap.
var (
	admin        = address("g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069")
	pendingAdmin address
	fees         = types.Fees{PrimaryBps: 250, SecondaryBps: 250, Treasury: address("g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069")}
	beacon       address
	minters      avl.Tree // minter pkgpath -> *minterRecord
	ops          avl.Tree // safe.PadInt(op id) -> *pendingOp
	opCount      int64
	pauses       avl.Tree // scope -> *pauseRecord
)

// pauseRecord is one scope's pause and its budget (SA-L2): within a window
// of PauseWindowBlocks a scope can be paused for at most MaxPauseBlocks in
// total; a pause cannot be renewed while it runs. Worst case two budgets
// meet at a window boundary (<= 2 x MaxPauseBlocks in a row), never more.
type pauseRecord struct {
	windowStart int64
	used        int64 // blocks of budget charged in this window
	until       int64 // exclusive
}

type minterRecord struct {
	deprecated bool
}

type pendingOp struct {
	id       int64
	op, arg  string
	proposed int64
}

// Ops and their argument formats.
const (
	OpFeeCreate       = "fee.create"       // ugnot, <= CreateFeeCap
	OpFeePrimary      = "fee.primary"      // bps, <= ProtocolFeeCapBps
	OpFeeSecondary    = "fee.secondary"    // bps, <= ProtocolFeeCapBps
	OpTreasury        = "treasury"         // address
	OpBeacon          = "beacon"           // address, or "" to disable new beacon launches
	OpMinterAdd       = "minter.add"       // realm pkgpath
	OpMinterDeprecate = "minter.deprecate" // realm pkgpath: no new collections
	OpEngineReview    = "engine.review"    // engine id: reviewed badge (UI only)
	OpAdminTransfer   = "admin.transfer"   // address; the new admin must AcceptAdmin
)

var pauseScopes = []string{"create", "mint", "trade"}

func ProposeOp(cur realm, op, arg string) string {
	assertNoDeposit(cur)
	assertAdmin(cur)
	validateOp(op, arg)
	opCount++
	p := &pendingOp{id: opCount, op: op, arg: arg, proposed: height()}
	ops.Set(safe.PadInt(p.id, cidWidth), p)
	id := itoa(p.id)
	chain.Emit("OpProposed", "id", id, "op", op, "arg", arg, "earliest", itoa(earliestExecution(p)))
	return id
}

// ExecuteOp applies a proposed op once its timelock has passed. The delay is
// judged at execution, so an op proposed during bootstrap still waits the
// full timelock if a collection appeared in the meantime.
func ExecuteOp(cur realm, opID string) {
	assertNoDeposit(cur)
	assertAdmin(cur)
	p := mustOp(opID)
	if height() < earliestExecution(p) {
		panic("timelocked until height " + itoa(earliestExecution(p)))
	}
	validateOp(p.op, p.arg)
	applyOp(p.op, p.arg)
	ops.Remove(safe.PadInt(p.id, cidWidth))
	chain.Emit("OpExecuted", "id", opID, "op", p.op, "arg", p.arg)
}

func CancelOp(cur realm, opID string) {
	assertNoDeposit(cur)
	assertAdmin(cur)
	p := mustOp(opID)
	ops.Remove(safe.PadInt(p.id, cidWidth))
	chain.Emit("OpCancelled", "id", opID)
}

func AcceptAdmin(cur realm) {
	assertNoDeposit(cur)
	who := caller(cur)
	if pendingAdmin == "" || who != pendingAdmin {
		panic("no pending admin transfer to this address")
	}
	chain.Emit("AdminTransferred", "from", admin.String(), "to", who.String())
	admin = who
	pendingAdmin = ""
}

// Pause stops new activity in one scope for the rest of its budget (at
// most MaxPauseBlocks per PauseWindowBlocks). It never blocks exits (I-2)
// and cannot be renewed while it runs (SA-L2).
func Pause(cur realm, scope string) {
	assertNoDeposit(cur)
	assertAdmin(cur)
	assertScope(scope)
	h := height()
	r := pauseOf(scope)
	if h < r.until {
		panic("already paused until height " + itoa(r.until) + "; a pause cannot be renewed")
	}
	if h >= r.windowStart+PauseWindowBlocks {
		r.windowStart, r.used = h, 0
	}
	left := MaxPauseBlocks - r.used
	if left <= 0 {
		panic("pause budget of " + scope + " is spent until height " + itoa(r.windowStart+PauseWindowBlocks))
	}
	r.used += left
	r.until = h + left
	pauses.Set(scope, r)
	chain.Emit("Paused", "scope", scope, "until", itoa(r.until))
}

// Unpause ends a pause early and gives the unused blocks back to the budget.
func Unpause(cur realm, scope string) {
	assertNoDeposit(cur)
	assertAdmin(cur)
	assertScope(scope)
	h := height()
	r := pauseOf(scope)
	if h < r.until {
		r.used -= r.until - h
	}
	r.until = 0
	chain.Emit("Unpaused", "scope", scope)
}

func pauseOf(scope string) *pauseRecord {
	if v := pauses.Get(scope); v != nil {
		return v.(*pauseRecord)
	}
	return &pauseRecord{windowStart: -PauseWindowBlocks}
}

// Paused reports whether scope ("create", "mint", "trade") is paused now.
func Paused(scope string) bool {
	v := pauses.Get(scope)
	return v != nil && height() < v.(*pauseRecord).until
}

// PauseBudget is the scope's pause record as JSON: {until, used,
// windowStart, windowEnd, left}.
func PauseBudget(scope string) string {
	assertScope(scope)
	r := pauseOf(scope)
	used := r.used
	if height() >= r.windowStart+PauseWindowBlocks && height() >= r.until {
		used = 0
	}
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.IntField("until", r.until)
	w.IntField("used", used)
	w.IntField("windowStart", r.windowStart)
	w.IntField("windowEnd", r.windowStart+PauseWindowBlocks)
	w.IntField("left", MaxPauseBlocks-used)
	w.EndObject()
	return w.String()
}

func assertNotPaused(scope string) {
	if Paused(scope) {
		panic("paused: " + scope)
	}
}

func assertScope(scope string) {
	for _, s := range pauseScopes {
		if s == scope {
			return
		}
	}
	panic("pause scope must be one of " + strings.Join(pauseScopes, ", "))
}

func assertAdmin(cur realm) {
	if caller(cur) != admin {
		panic("admin only")
	}
}

func bootstrapping() bool { return collCount == 0 }

func earliestExecution(p *pendingOp) int64 {
	if bootstrapping() {
		return p.proposed
	}
	return p.proposed + TimelockBlocks
}

func mustOp(opID string) *pendingOp {
	v := ops.Get(safe.PadInt(safe.ParseID("opID", opID), cidWidth))
	if v == nil {
		panic("unknown op " + opID)
	}
	return v.(*pendingOp)
}

// validateOp is the closed list of admin powers (I-1).
func validateOp(op, arg string) {
	switch op {
	case OpFeeCreate:
		n := parseAmount(arg)
		if n > CreateFeeCap {
			panic("create fee above cap " + itoa(CreateFeeCap))
		}
	case OpFeePrimary, OpFeeSecondary:
		safe.AssertBps(op, parseAmount(arg), ProtocolFeeCapBps)
	case OpTreasury, OpAdminTransfer:
		if !address(arg).IsValid() {
			panic(op + ": invalid address")
		}
		if op == OpTreasury {
			assertSpendable(op, address(arg), "", "") // SA-L5
		}
	case OpBeacon:
		if arg != "" && !address(arg).IsValid() {
			panic(op + ": invalid address")
		}
	case OpMinterAdd:
		safe.AssertText("minter", arg, 256)
		if !strings.HasPrefix(arg, runtime.ChainDomain()+"/r/") || strings.Contains(arg, "#") {
			panic("minter must be a realm path")
		}
		if minters.Has(arg) {
			panic("minter already added")
		}
	case OpMinterDeprecate:
		if !minters.Has(arg) {
			panic("unknown minter")
		}
	case OpEngineReview:
		mustEngine(arg)
	default:
		panic("unknown op " + strconv.Quote(op))
	}
}

func applyOp(op, arg string) {
	switch op {
	case OpFeeCreate:
		fees.CreateFee = parseAmount(arg)
	case OpFeePrimary:
		fees.PrimaryBps = parseAmount(arg)
	case OpFeeSecondary:
		fees.SecondaryBps = parseAmount(arg)
	case OpTreasury:
		fees.Treasury = address(arg)
	case OpBeacon:
		beacon = address(arg)
	case OpMinterAdd:
		minters.Set(arg, &minterRecord{})
	case OpMinterDeprecate:
		minters.Get(arg).(*minterRecord).deprecated = true
	case OpEngineReview:
		mustEngine(arg).reviewed = true
	case OpAdminTransfer:
		pendingAdmin = address(arg)
	}
}

func assertActiveMinter(path string) {
	v := minters.Get(path)
	if v == nil {
		panic("caller " + strconv.Quote(path) + " is not an approved minter")
	}
	if v.(*minterRecord).deprecated {
		panic("minter " + path + " is deprecated")
	}
}

func parseAmount(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n < 0 {
		panic("expected a non-negative integer, got " + strconv.Quote(s))
	}
	return n
}
