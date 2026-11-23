// Package agentvault is the AgentVault spend-guard realm: the first
// wallet an AI agent cannot drain.
//
// The owner funds the vault in ugnot and sets a per-transaction cap
// and a daily cap per agent. Agents spend only through this realm.
// Every spend call checks both caps, logs the attempt, and rejects
// anything over the limit — the rejection is a logged return value,
// not a panicked transaction, so the blocked attempt stays visible
// on the Render page as evidence. Payments can address an agent by
// registered name (resolved on-chain through r/sys/users, with a
// local name map as fallback) and are held in escrow until the named
// recipient confirms delivery or the owner refunds after the
// deadline.
//
// Security rules followed here (see docs/resources/gno-security-guide.md
// and gno-ai-contract-review.md):
//   - Caller identity comes from cur.Previous(), never from an
//     address parameter. No IsCurrent guard: the runtime puts cur
//     into the current realm-context on entry, so it is always true
//     in a crossing function.
//   - Payments in use cur.Previous().IsUserCall() with
//     unsafe.OriginSend(): only a direct user call guarantees the
//     send envelope landed at this realm. unsafe.OriginSend is the
//     sanctioned payment-read API (effective-gno.md: "the OriginSend
//     amount check + IsUserCall guard is the only pattern
//     available"); unsafe is imported ONLY for OriginSend, never
//     for PreviousRealm, which the guide forbids in a crossing
//     function.
//   - Balances are read with banker.GetCoin for one denom, never
//     GetCoins(...).AmountOf on a caller-supplied address.
//   - Getters return values/copies, never pointers to internal
//     mutable state.
//   - No realm value is stored; only addresses and paths (strings).
//   - Render sanitizes every user-controlled string.
//   - The owner is set by an explicit SetOwner call after deployment
//     (the empty-owner bootstrap), not captured in init, because
//     there is no safe deployer getter in init.
package agentvault

import (
	"time"

	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	caps "gno.land/p/g16740fm9kd28luuktn3g42jfq3r998fm35chclv/agentvault"
	susers "gno.land/r/sys/users"
)

// currentPkgPath is this realm's package path; init derives the
// realm's own address from it.
const currentPkgPath = "gno.land/r/g16740fm9kd28luuktn3g42jfq3r998fm35chclv/agentvault"

// denom is the only coin this vault handles.
const denom = "ugnot"

// maxAttempts caps the append-only spend log so storage stays
// bounded; the oldest entries are dropped first.
const maxAttempts = 500

var (
	owner         address
	selfAddr      address
	budgets       map[address]caps.AgentBudget
	agentList     []address
	nameMap       map[string]address
	attempts      []caps.Attempt
	escrows       map[int64]caps.Escrow
	nextEscrowID  int64
	nextAttemptID int64
	totalFunded   int64
	totalSpent    int64
	escrowedTotal int64
)

func init() {
	// The realm's own address is derived from its package path.
	// The owner is NOT captured here: there is no safe deployer
	// getter in init, and capturing via unsafe.PreviousRealm is
	// against the security guide. The owner starts empty and the
	// deployer calls SetOwner right after deployment (SetOwner's
	// empty-owner bootstrap allows the first call without an owner
	// check). That call must happen promptly: until then anyone
	// could claim the vault by calling SetOwner.
	selfAddr = chain.PackageAddress(currentPkgPath)
	budgets = make(map[address]caps.AgentBudget)
	nameMap = make(map[string]address)
	escrows = make(map[int64]caps.Escrow)
	nextEscrowID = 1
	nextAttemptID = 1
}

// mustOwner panics unless the caller is the vault owner. No
// IsCurrent guard: in a crossing function cur is always current.
func mustOwner(cur realm) {
	if owner == "" {
		panic("owner not set: call SetOwner first")
	}
	if cur.Previous().Address() != owner {
		panic("not the owner")
	}
}

// Owner returns the vault owner's address.
func Owner() address {
	return owner
}

// SetOwner sets (first call, while the owner is unset) or changes
// (owner only) the vault owner. The deployer calls this right after
// addpkg, while the owner is still unset; afterwards only the owner
// can rotate it.
func SetOwner(cur realm, newOwner address) {
	if owner != "" && cur.Previous().Address() != owner {
		panic("not the owner")
	}
	if newOwner == "" {
		panic("new owner must not be empty")
	}
	owner = newOwner
}

// logAttempt appends one entry to the spend log, dropping the oldest
// entries once the log reaches maxAttempts.
func logAttempt(kind string, agent address, name string, amount int64, purpose string, allowed bool, reason string) {
	attempts = append(attempts, caps.Attempt{
		ID:      nextAttemptID,
		Kind:    kind,
		Agent:   agent,
		Name:    name,
		Amount:  amount,
		Purpose: purpose,
		Allowed: allowed,
		Reason:  reason,
		Day:     caps.DayIndex(time.Now().Unix()),
	})
	nextAttemptID++
	if len(attempts) > maxAttempts {
		attempts = attempts[len(attempts)-maxAttempts:]
	}
}

// VaultBalance returns the realm's actual ugnot balance.
// Single-denom read: GetCoin, not GetCoins.
func VaultBalance() int64 {
	return banker.NewReadonlyBanker().GetCoin(selfAddr, denom)
}

// AvailableBalance is the balance not held in escrow.
func AvailableBalance() int64 {
	avail := VaultBalance() - escrowedTotal
	if avail < 0 {
		return 0
	}
	return avail
}

// TotalFunded returns the ugnot the owner has funded into the vault.
func TotalFunded() int64 { return totalFunded }

// TotalSpent returns the ugnot paid out through successful spends.
func TotalSpent() int64 { return totalSpent }

// EscrowedTotal returns the ugnot currently held in escrow.
func EscrowedTotal() int64 { return escrowedTotal }

// Fund tops up the vault. Only the owner may fund, and only as a
// direct user call: IsUserCall guarantees the OriginSend envelope
// landed at this realm, so the attached amount is the funded amount.
// Returns the vault balance after funding.
func Fund(cur realm) int64 {
	mustOwner(cur)
	// Paired guards (see effective-gno.md: verifying inbound coin
	// payments). IsUserCall alone would let the owner fund nothing;
	// OriginSend alone could describe coins an intermediary consumed.
	if !cur.Previous().IsUserCall() {
		panic("fund must be a direct user call")
	}
	amount := unsafe.OriginSend().AmountOf(denom)
	if amount <= 0 {
		panic("fund amount must be positive")
	}
	totalFunded += amount
	logAttempt("fund", cur.Previous().Address(), "", amount, "vault top-up", true, "ok")
	return VaultBalance()
}

// SetCap sets (or updates) an agent's caps. Updating preserves the
// amount already spent today: re-setting caps must not reset the
// daily spend, or the owner could launder the limit away.
func SetCap(cur realm, agent address, perTxCap, dailyCap int64) {
	mustOwner(cur)
	if reason := caps.ValidateCaps(perTxCap, dailyCap); reason != "" {
		panic(reason)
	}
	if agent == "" {
		panic("agent address must not be empty")
	}
	if old, ok := budgets[agent]; ok {
		old.PerTxCap = perTxCap
		old.DailyCap = dailyCap
		budgets[agent] = old
		return
	}
	budgets[agent] = caps.NewBudget(perTxCap, dailyCap)
	agentList = append(agentList, agent)
}

// SetName maps a name to an address in the vault's local name map.
// The owner resolves names off-chain (or from the registry) and
// registers them here; PayByName and SetCapByName consult the
// on-chain registry first and this map second.
func SetName(cur realm, name string, addr address) {
	mustOwner(cur)
	if name == "" {
		panic("name must not be empty")
	}
	if addr == "" {
		panic("address must not be empty")
	}
	nameMap[name] = addr
}

// ResolveName resolves a name to an address. The on-chain registry
// (r/sys/users) is consulted first and only the user's CURRENT name
// counts; the vault's local name map is the fallback. Returns false
// when the name resolves nowhere.
func ResolveName(name string) (address, bool) {
	if data, isCurrent := susers.ResolveName(name); data != nil && isCurrent {
		return data.Addr(), true
	}
	if addr, ok := nameMap[name]; ok {
		return addr, true
	}
	return "", false
}

// SetCapByName sets an agent's caps by registered name.
func SetCapByName(cur realm, name string, perTxCap, dailyCap int64) {
	mustOwner(cur)
	agent, ok := ResolveName(name)
	if !ok {
		panic("name not found: " + name)
	}
	SetCap(cur, agent, perTxCap, dailyCap)
}

// Budget returns a copy of an agent's budget and whether one is set.
func Budget(agent address) (caps.AgentBudget, bool) {
	b, ok := budgets[agent]
	return b, ok
}

// BudgetByName returns a copy of an agent's budget by name.
func BudgetByName(name string) (caps.AgentBudget, bool) {
	agent, ok := ResolveName(name)
	if !ok {
		return caps.AgentBudget{}, false
	}
	return Budget(agent)
}

// Agents returns the agent addresses with budgets, in the order
// their caps were first set. A copy: callers cannot mutate vault state.
func Agents() []address {
	cp := make([]address, len(agentList))
	copy(cp, agentList)
	return cp
}

// Spend pays amount ugnot to the calling agent, if both caps allow
// it. The caller is the agent: identity comes from the live crossing
// frame. A blocked spend returns false with the reason and is logged;
// it does not panic, because a panicked transaction would erase the
// evidence the guard report is built from.
func Spend(cur realm, amount int64, purpose string) (bool, string) {
	caller := cur.Previous().Address()
	b, ok := budgets[caller]
	if !ok {
		logAttempt("spend", caller, "", amount, purpose, false, "no budget set for this agent")
		return false, "no budget set for this agent"
	}
	caps.RefreshDay(&b, time.Now().Unix())
	allowed, reason := caps.CheckSpend(b, amount)
	if !allowed {
		// Persist the refreshed day even on a blocked spend, so the
		// rollover sticks.
		budgets[caller] = b
		logAttempt("spend", caller, "", amount, purpose, false, reason)
		return false, reason
	}
	if amount > AvailableBalance() {
		budgets[caller] = b
		logAttempt("spend", caller, "", amount, purpose, false, "insufficient vault balance")
		return false, "insufficient vault balance"
	}
	caps.ApplySpend(&b, amount)
	budgets[caller] = b
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), caller, chain.Coins{{Denom: denom, Amount: amount}})
	totalSpent += amount
	logAttempt("spend", caller, "", amount, purpose, true, "ok")
	return true, "ok"
}

// PayByName holds amount ugnot in escrow for a named recipient. The
// name resolves through the on-chain registry first, then the local
// name map. The coins stay in the vault while held; ConfirmEscrow
// releases them, RefundEscrow returns them to the free balance after
// the deadline. Returns the escrow id, whether it was created, and a
// reason.
func PayByName(cur realm, name string, amount int64, deadlineBlocks int64) (int64, bool, string) {
	mustOwner(cur)
	recipient, ok := ResolveName(name)
	if !ok {
		return -1, false, "name not found: " + name
	}
	if amount <= 0 {
		return -1, false, "amount must be positive"
	}
	if deadlineBlocks <= 0 {
		return -1, false, "deadline must be a positive block count"
	}
	if amount > AvailableBalance() {
		return -1, false, "insufficient vault balance"
	}
	id := nextEscrowID
	nextEscrowID++
	escrows[id] = caps.Escrow{
		ID:             id,
		Payer:          cur.Previous().Address(),
		RecipientName:  name,
		Recipient:      recipient,
		Amount:         amount,
		DeadlineHeight: runtime.ChainHeight() + deadlineBlocks,
		Status:         caps.EscrowHeld,
	}
	escrowedTotal += amount
	logAttempt("escrow", recipient, name, amount, "payment held in escrow", true, "ok")
	return id, true, "ok"
}

// ConfirmEscrow releases a held escrow to its named recipient. Only
// the recipient may confirm, and only while the escrow is held.
func ConfirmEscrow(cur realm, id int64) (bool, string) {
	e, ok := escrows[id]
	if !ok {
		return false, "escrow not found"
	}
	if e.Status != caps.EscrowHeld {
		return false, "escrow not held"
	}
	if cur.Previous().Address() != e.Recipient {
		return false, "only the recipient can confirm"
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), e.Recipient, chain.Coins{{Denom: denom, Amount: e.Amount}})
	e.Status = caps.EscrowReleased
	escrows[id] = e
	escrowedTotal -= e.Amount
	logAttempt("release", e.Recipient, e.RecipientName, e.Amount, "escrow released to recipient", true, "ok")
	return true, "ok"
}

// RefundEscrow returns a held escrow to the vault's free balance.
// Only the owner may refund, and only after the deadline block has
// passed. The coins never left the vault, so refunding only flips
// the status and frees the held amount.
func RefundEscrow(cur realm, id int64) (bool, string) {
	mustOwner(cur)
	e, ok := escrows[id]
	if !ok {
		return false, "escrow not found"
	}
	if !caps.EscrowRefundable(e, runtime.ChainHeight()) {
		if e.Status != caps.EscrowHeld {
			return false, "escrow not held"
		}
		return false, "deadline has not passed"
	}
	e.Status = caps.EscrowRefunded
	escrows[id] = e
	escrowedTotal -= e.Amount
	logAttempt("refund", e.Recipient, e.RecipientName, e.Amount, "escrow refunded to vault", true, "ok")
	return true, "ok"
}

// Escrow returns a copy of one escrow and whether it exists.
func Escrow(id int64) (caps.Escrow, bool) {
	e, ok := escrows[id]
	return e, ok
}

// Escrows returns copies of all escrows, ordered by id. A copy:
// callers cannot mutate vault state.
func Escrows() []caps.Escrow {
	out := make([]caps.Escrow, 0, len(escrows))
	for _, e := range escrows {
		out = append(out, e)
	}
	// Insertion sort by id (escrow counts are small).
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].ID < out[j-1].ID; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

// Attempts returns a copy of the spend log, oldest first. A copy:
// callers cannot mutate vault state.
func Attempts() []caps.Attempt {
	cp := make([]caps.Attempt, len(attempts))
	copy(cp, attempts)
	return cp
}
