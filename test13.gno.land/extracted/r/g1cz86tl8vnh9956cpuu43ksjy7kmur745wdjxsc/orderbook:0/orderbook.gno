// Package orderbook is spike v2 of the GnoPulse on-chain order engine: it turns the
// proven one-shot Execute(args) (see r/<addr>/limitspike) into a persistent order book —
// CreateOrder stores an intent, a permissionless keeper pokes Execute(orderID), and the
// realm RE-VALIDATES the trigger on-chain before swapping on GnoSwap for the owner.
//
// Two order kinds share one machine:
//   - "dca":   time-gated. Executes `amountIn` wugnot every `intervalBlocks`, up to `runs` times.
//   - "limit": price-gated. Executes once when the pool tick >= minTick.
//
// Non-custodial: the realm never holds user funds. The owner grants THIS realm a wugnot
// allowance; each fill pulls exactly `amountIn`, swaps wugnot->GNS, and forwards the GNS to
// the owner. The keeper is trustless — it only controls TIMING; the realm re-checks the
// trigger, so a keeper can never force an early or off-limit fill. Cancel = deactivate (or
// the owner simply revokes the allowance).
package orderbook

import (
	"strconv"
	"time"

	"chain"
	"chain/runtime"

	"gno.land/p/nt/avl/v0"

	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/gns"
	"gno.land/r/gnoswap/pool"
	"gno.land/r/gnoswap/router"
)

const (
	inTok    = "gno.land/r/gnoland/wugnot"
	outTok   = "gno.land/r/gnoswap/gns"
	poolPath = "gno.land/r/gnoland/wugnot:gno.land/r/gnoswap/gns:3000"
	routeArr = poolPath
)

// routerAddr is the GnoSwap router role address — the wugnot spender each fill approves.
var routerAddr = address("g1vc883gshu5z7ytk5cdynhc8c2dh67pdp4cszkp")

type Order struct {
	ID       uint64
	Owner    address
	Kind     string // "dca" | "limit"
	AmountIn int64  // wugnot per fill
	MinOut   int64  // slippage floor per fill

	MinTick int32 // limit trigger: fill when pool tick >= MinTick

	IntervalBlocks int64 // dca trigger: min blocks between fills
	NextRun        int64 // earliest height for the next fill
	RunsLeft       int64 // fills remaining (limit orders start at 1)

	CreatedAt int64
	Active    bool
}

var (
	orders  avl.Tree // pad(id) -> *Order
	byOwner avl.Tree // owner:pad(id) -> true
	nextID  uint64
	paused  bool
)

// ---- helpers ----

func pad(id uint64) string {
	s := strconv.FormatInt(int64(id), 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }
func i32(n int32) string { return strconv.FormatInt(int64(n), 10) }

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func mustOrder(id uint64) *Order {
	v, ok := orders.Get(pad(id))
	if !ok {
		panic("no such order")
	}
	return v.(*Order)
}

// ---- writes ----

// CreateOrder stores an order intent and returns its id. The caller must first Approve
// THIS realm as a wugnot spender for at least amountIn (for dca, amountIn*runs so every
// fill is covered).
//   kind "dca":   intervalBlocks>0 and runs>=1; minTick ignored; first fill is due immediately.
//   kind "limit": minTick set; runs forced to 1; intervalBlocks ignored.
func CreateOrder(cur realm, kind string, amountIn, minOut int64, minTick int32, intervalBlocks, runs int64) uint64 {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if paused {
		panic("paused")
	}
	owner := cur.Previous().Address()
	self := cur.Address()
	if amountIn <= 0 {
		panic("amountIn must be > 0")
	}
	if wugnot.Allowance(owner, self) < amountIn {
		panic("approve this realm as a wugnot spender first (>= amountIn)")
	}

	o := &Order{
		ID:        nextID,
		Owner:     owner,
		Kind:      kind,
		AmountIn:  amountIn,
		MinOut:    minOut,
		MinTick:   minTick,
		CreatedAt: runtime.ChainHeight(),
		Active:    true,
	}
	switch kind {
	case "dca":
		if intervalBlocks <= 0 || runs < 1 {
			panic("dca needs intervalBlocks>0 and runs>=1")
		}
		o.IntervalBlocks = intervalBlocks
		o.RunsLeft = runs
		o.NextRun = runtime.ChainHeight() // first fill due now
	case "limit":
		o.RunsLeft = 1
	default:
		panic("kind must be dca or limit")
	}

	orders.Set(pad(nextID), o)
	byOwner.Set(owner.String()+":"+pad(nextID), true)
	chain.Emit("OrderCreated", "id", i64(int64(nextID)), "owner", owner.String(), "kind", kind)
	nextID++
	return o.ID
}

// CancelOrder deactivates an order. Owner only. No funds are held, so this just stops the
// keeper from filling it (the owner may also revoke the wugnot allowance).
func CancelOrder(cur realm, id uint64) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	o := mustOrder(id)
	if o.Owner != cur.Previous().Address() {
		panic("not owner")
	}
	o.Active = false
	chain.Emit("OrderCancelled", "id", i64(int64(id)))
}

// Execute runs one fill. PERMISSIONLESS — any keeper may poke it; the realm re-validates
// the trigger on-chain, so a keeper controls only TIMING, never whether a fill is allowed.
// Returns (tickAtExec, gnsOut).
func Execute(cur realm, id uint64) (int32, int64) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if paused {
		panic("paused")
	}
	o := mustOrder(id)
	if !o.Active {
		panic("order inactive")
	}

	tick := pool.GetSlot0Tick(poolPath)

	// TRIGGER GATE — re-checked on-chain regardless of what the keeper believes.
	switch o.Kind {
	case "dca":
		if runtime.ChainHeight() < o.NextRun {
			panic("dca: not due (height " + i64(runtime.ChainHeight()) + " < nextRun " + i64(o.NextRun) + ")")
		}
	case "limit":
		if tick < o.MinTick {
			panic("limit: tick " + i32(tick) + " < minTick " + i32(o.MinTick))
		}
	}

	// STATE-BEFORE-SEND: advance the schedule before any external call so a duplicate or
	// re-entrant poke can't double-fill. A revert below rolls this back atomically.
	o.RunsLeft--
	if o.Kind == "dca" {
		o.NextRun = runtime.ChainHeight() + o.IntervalBlocks
	}
	if o.RunsLeft <= 0 {
		o.Active = false
	}

	self := cur.Address()

	// Pull the owner's wugnot (owner pre-approved this realm), swap, forward GNS to owner.
	wugnot.TransferFrom(cross(cur), o.Owner, self, o.AmountIn)
	wugnot.Approve(cross(cur), routerAddr, o.AmountIn)

	before := gns.BalanceOf(self)
	router.ExactInSingleSwapRoute(
		cross(cur),
		inTok, outTok,
		i64(o.AmountIn),
		routeArr,
		i64(o.MinOut),
		"0",
		time.Now().Unix()+300,
		"",
	)
	out := gns.BalanceOf(self) - before
	if out > 0 {
		gns.Transfer(cross(cur), o.Owner, out)
	}

	chain.Emit("OrderFilled",
		"id", i64(int64(id)),
		"owner", o.Owner.String(),
		"kind", o.Kind,
		"tick", i32(tick),
		"amountIn", i64(o.AmountIn),
		"gnsOut", i64(out),
		"runsLeft", i64(o.RunsLeft),
	)
	return tick, out
}

// ---- reads ----

func Tick() int32 { return pool.GetSlot0Tick(poolPath) }

func GetOrderJSON(id uint64) string { return orderJSON(mustOrder(id)) }

// ListActiveJSON returns up to `limit` active orders from `offset` — the keeper's scan feed.
func ListActiveJSON(offset, limit int) string {
	out := "["
	n := 0
	seen := 0
	orders.Iterate("", "", func(_ string, v any) bool {
		o := v.(*Order)
		if !o.Active {
			return false
		}
		if seen >= offset && n < limit {
			if n > 0 {
				out += ","
			}
			out += orderJSON(o)
			n++
		}
		seen++
		return n >= limit
	})
	return out + "]"
}

func orderJSON(o *Order) string {
	return "{\"id\":" + i64(int64(o.ID)) +
		",\"owner\":\"" + o.Owner.String() + "\"" +
		",\"kind\":\"" + o.Kind + "\"" +
		",\"amountIn\":" + i64(o.AmountIn) +
		",\"minOut\":" + i64(o.MinOut) +
		",\"minTick\":" + i32(o.MinTick) +
		",\"intervalBlocks\":" + i64(o.IntervalBlocks) +
		",\"nextRun\":" + i64(o.NextRun) +
		",\"runsLeft\":" + i64(o.RunsLeft) +
		",\"active\":" + boolStr(o.Active) + "}"
}

func Render(_ string) string {
	out := "# GnoPulse Order Book (spike v2)\n\nLive pool tick: **" + i32(Tick()) + "**\n\n"
	out += "| id | kind | owner | amtIn | runsLeft | gate | active |\n|--|--|--|--|--|--|--|\n"
	orders.Iterate("", "", func(_ string, v any) bool {
		o := v.(*Order)
		gate := "t>=" + i32(o.MinTick)
		if o.Kind == "dca" {
			gate = "h>=" + i64(o.NextRun)
		}
		out += "| " + i64(int64(o.ID)) + " | " + o.Kind + " | " + short(o.Owner.String()) +
			" | " + i64(o.AmountIn) + " | " + i64(o.RunsLeft) + " | " + gate + " | " + boolStr(o.Active) + " |\n"
		return false
	})
	return out
}

func short(a string) string {
	if len(a) <= 12 {
		return a
	}
	return a[:8] + "…" + a[len(a)-4:]
}
