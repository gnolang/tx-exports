// Package agentwallet is a spend-limited wallet bound to an Agent ID.
//
// The owner funds it and sets the policy. A different address, the agent,
// is the only caller that can move those funds. Swap, exchange, liquidity,
// and stake stay inside this realm. They are not a public exchange.
package agentwallet

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	std "gno.land/p/g1y0n2geu0rmdrm9u30c5fmk3ykkl2enw9n9yr2k/agentid"
	"gno.land/p/nt/avl/v0"
	book "gno.land/r/g1y0n2geu0rmdrm9u30c5fmk3ykkl2enw9n9yr2k/agentbook"
)

const denomUgnot = "ugnot"

type wallet struct {
	owner     address
	agent     address
	name      string
	armed     bool
	txCap     int64
	allowance int64
	actions   []string
	names     []string
	free      int64
	exchange  int64
	staked    int64
	units     int64
	shares    int64
}

var (
	wallets    avl.Tree // owner.String() -> *wallet
	byAgent    avl.Tree // agent.String() -> owner.String()
	poolUgnot  int64
	poolUnits  int64
	poolShares int64
)

// Open binds a fresh agent address to the caller's Agent ID.
// The agent address must be a different key from the owner.
func Open(cur realm, agent address) {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("no payment")
	}
	caller := cur.Previous().Address()
	name := book.NameOf(caller)
	if name == "" {
		panic("claim a name")
	}
	if !agent.IsValid() {
		panic("invalid caller")
	}
	if agent == caller {
		panic("same key")
	}
	if wallets.Has(caller.String()) || byAgent.Has(agent.String()) {
		panic("already open")
	}
	wallets.Set(caller.String(), &wallet{owner: caller, agent: agent, name: name})
	byAgent.Set(agent.String(), caller.String())
	chain.Emit("Open", "owner", caller.String(), "agent", agent.String(), "name", name)
}

// Fund adds the ugnot attached to this call to the owner's agent wallet.
func Fund(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denomUgnot || sent[0].Amount <= 0 {
		panic("send ugnot")
	}
	w := mustOwner(cur.Previous().Address())
	amt := sent[0].Amount
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if banker_.GetCoins(cur.Address()).AmountOf(denomUgnot) < amt {
		panic("ugnot not received")
	}
	w.free += amt
	chain.Emit("Fund", "owner", w.owner.String(), "ugnot", strconv.FormatInt(amt, 10))
}

// SetPolicy replaces the per-action cap, the remaining allowance, and the allowlists.
// actions and names are comma-separated. The owner calls this.
func SetPolicy(cur realm, txCap int64, allowance int64, actions string, names string) {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("no payment")
	}
	if txCap < 0 {
		panic("over cap")
	}
	if allowance < 0 {
		panic("over allowance")
	}
	w := mustOwner(cur.Previous().Address())
	w.txCap = txCap
	w.allowance = allowance
	w.actions = cleanActions(splitCSV(actions))
	w.names = cleanNames(splitCSV(names))
	chain.Emit("Policy", "owner", w.owner.String())
}

// Arm lets the agent address submit actions.
func Arm(cur realm) {
	setArmed(cur, true)
}

// Disarm stops the agent address until the owner arms it again.
func Disarm(cur realm) {
	setArmed(cur, false)
}

func setArmed(cur realm, armed bool) {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("no payment")
	}
	w := mustOwner(cur.Previous().Address())
	w.armed = armed
}

// Act moves funds already inside the agent wallet.
// The caller must be the bound agent address, not the owner.
func Act(cur realm, action string, dest string, amount int64) {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("no payment")
	}
	w := walletByAgent(cur.Previous().Address())
	if w == nil {
		panic("agent only")
	}
	if !w.armed {
		panic("disarmed")
	}
	if !allowed(w.actions, groupOf(action)) {
		panic("action denied")
	}
	switch action {
	case "transfer":
		transfer(cur, w, dest, amount)
	case "exchange-in":
		takeFree(w, amount)
		w.exchange += amount
	case "exchange-out":
		moveBack(w, &w.exchange, amount)
	case "stake":
		takeFree(w, amount)
		w.staked += amount
	case "unstake":
		moveBack(w, &w.staked, amount)
	case "swap-buy":
		swapBuy(w, amount)
	case "swap-sell":
		swapSell(w, amount)
	case "liquidity-add":
		addLiquidity(w, amount)
	case "liquidity-remove":
		removeLiquidity(w, amount, true)
	default:
		panic("action denied")
	}
	chain.Emit("Act", "agent", w.agent.String(), "action", action, "ugnot", strconv.FormatInt(amount, 10))
}

// Recover returns the owner's agent funds to the owner and disarms the agent.
func Recover(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("no payment")
	}
	w := mustOwner(cur.Previous().Address())
	w.free += w.exchange + w.staked
	w.exchange = 0
	w.staked = 0
	if w.shares > 0 {
		removeLiquidity(w, w.shares, false)
	}
	if w.units > 0 && poolUgnot > 0 && poolUnits > 0 {
		out := quoteOut(poolUnits, poolUgnot, w.units)
		if out > 0 {
			poolUnits += w.units
			poolUgnot -= out
			w.free += out
		}
	}
	w.units = 0
	amt := w.free
	w.free = 0
	w.armed = false
	if amt > 0 {
		banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		if banker_.GetCoins(cur.Address()).AmountOf(denomUgnot) < amt {
			panic("ugnot not received")
		}
		banker_.SendCoins(cur.Address(), w.owner, chain.NewCoins(chain.NewCoin(denomUgnot, amt)))
	}
	chain.Emit("Recover", "owner", w.owner.String(), "ugnot", strconv.FormatInt(amt, 10))
}

// Free returns the spendable ugnot inside the owner's agent wallet.
func Free(owner address) int64 {
	w := ownerWallet(owner)
	if w == nil {
		return 0
	}
	return w.free
}

func transfer(cur realm, w *wallet, dest string, amount int64) {
	if !allowed(w.names, dest) {
		panic("not allowed")
	}
	to, ok := book.Resolve(dest)
	if !ok {
		panic("unknown name")
	}
	takeFree(w, amount)
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if banker_.GetCoins(cur.Address()).AmountOf(denomUgnot) < amount {
		panic("ugnot not received")
	}
	banker_.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(denomUgnot, amount)))
}

func swapBuy(w *wallet, amount int64) {
	out := quoteOut(poolUgnot, poolUnits, amount)
	if out <= 0 {
		panic("no output")
	}
	takeFree(w, amount)
	poolUgnot += amount
	poolUnits -= out
	w.units += out
}

func swapSell(w *wallet, amount int64) {
	out := quoteOut(poolUnits, poolUgnot, amount)
	if out <= 0 {
		panic("no output")
	}
	if out > w.txCap {
		panic("over cap")
	}
	if w.units < amount {
		panic("insufficient")
	}
	w.units -= amount
	poolUnits += amount
	poolUgnot -= out
	w.free += out
}

func addLiquidity(w *wallet, amount int64) {
	if poolShares != 0 {
		if poolUgnot <= 0 {
			panic("no output")
		}
		sharesOut := amount * poolShares / poolUgnot
		unitsNeeded := amount * poolUnits / poolUgnot
		if sharesOut <= 0 || unitsNeeded <= 0 {
			panic("no output")
		}
		if w.units < unitsNeeded {
			panic("insufficient")
		}
		takeFree(w, amount)
		w.units -= unitsNeeded
		w.shares += sharesOut
		poolUgnot += amount
		poolUnits += unitsNeeded
		poolShares += sharesOut
		return
	}
	takeFree(w, amount)
	poolUgnot += amount
	poolUnits += amount
	poolShares += amount
	w.shares += amount
}

func removeLiquidity(w *wallet, shares int64, capped bool) {
	if shares <= 0 || shares > w.shares || poolShares <= 0 {
		panic("insufficient")
	}
	if shares == poolShares {
		if capped && poolUgnot > w.txCap {
			panic("over cap")
		}
		w.free += poolUgnot
		poolUgnot = 0
		poolUnits = 0
		poolShares = 0
		w.shares = 0
		return
	}
	ugnotOut := shares * poolUgnot / poolShares
	unitsOut := shares * poolUnits / poolShares
	if ugnotOut <= 0 {
		panic("no output")
	}
	if capped && ugnotOut > w.txCap {
		panic("over cap")
	}
	w.shares -= shares
	poolShares -= shares
	poolUgnot -= ugnotOut
	poolUnits -= unitsOut
	w.free += ugnotOut
	w.units += unitsOut
}

func takeFree(w *wallet, amount int64) {
	if amount <= 0 {
		panic("send ugnot")
	}
	if amount > w.txCap {
		panic("over cap")
	}
	if amount > w.allowance {
		panic("over allowance")
	}
	if amount > w.free {
		panic("insufficient")
	}
	w.free -= amount
	w.allowance -= amount
}

func moveBack(w *wallet, bucket *int64, amount int64) {
	if amount <= 0 {
		panic("send ugnot")
	}
	if amount > w.txCap {
		panic("over cap")
	}
	if *bucket < amount {
		panic("insufficient")
	}
	*bucket -= amount
	w.free += amount
}

func quoteOut(reserveIn int64, reserveOut int64, amountIn int64) int64 {
	if amountIn <= 0 || reserveIn <= 0 || reserveOut <= 0 {
		return 0
	}
	if reserveOut > int64(9223372036854775807)/amountIn {
		panic("overflow")
	}
	return reserveOut * amountIn / (reserveIn + amountIn)
}

func mustOwner(caller address) *wallet {
	w := ownerWallet(caller)
	if w == nil {
		panic("no wallet")
	}
	return w
}

func ownerWallet(caller address) *wallet {
	raw := wallets.Get(caller.String())
	if raw == nil {
		return nil
	}
	return raw.(*wallet)
}

func walletByAgent(caller address) *wallet {
	raw := byAgent.Get(caller.String())
	if raw == nil {
		return nil
	}
	return ownerWallet(address(raw.(string)))
}

func groupOf(action string) string {
	switch action {
	case "transfer":
		return "transfer"
	case "exchange-in", "exchange-out":
		return "exchange"
	case "swap-buy", "swap-sell":
		return "swap"
	case "liquidity-add", "liquidity-remove":
		return "liquidity"
	case "stake", "unstake":
		return "stake"
	default:
		return ""
	}
}

func allowed(list []string, want string) bool {
	if want == "" {
		return false
	}
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}

func cleanActions(items []string) []string {
	if len(items) > 8 {
		panic("invalid action")
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		switch item {
		case "transfer", "exchange", "swap", "liquidity", "stake":
			out = append(out, item)
		default:
			panic("invalid action")
		}
	}
	return out
}

func cleanNames(items []string) []string {
	if len(items) > 16 {
		panic("invalid name")
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		if !std.Valid(item) || std.Reserved(item) {
			panic("invalid name")
		}
		out = append(out, item)
	}
	return out
}

func splitCSV(s string) []string {
	if s == "" {
		return []string{}
	}
	out := []string{}
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == ',' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}
