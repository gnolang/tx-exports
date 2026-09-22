package upgrade_registry

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

// ContractEntry represents a registered contract and its upgrade status.
//
// An entry's Address is ALWAYS the address that called Register — a
// contract can only register itself. That call is the proof of control:
// nobody can claim an address they don't command, so a Deprecate
// redirect on an entry always originates from whoever genuinely
// controlled the contract. Entries are permanent by design: migration
// history is what consumers rely on, so it must not be erasable (and a
// delete would reopen re-registration squatting).
//
// Ownership is two-step (re-audit 2026-09-02): Register/Transfer only
// NOMINATE an owner; the nominee must AcceptOwnership. Until then the
// entry is owned by the contract itself, so nobody's address can be
// attached as "owner" without their consent.
type ContractEntry struct {
	Address      address
	Owner        address // current manager (accepted)
	PendingOwner address // nominated, not yet accepted; empty if none
	Name         string
	Deprecated   bool
	Successor    address // address of the upgraded contract, empty if current
}

const (
	MaxNameLen  = 64
	MaxChainLen = 50 // GetMigrationChain traversal/output bound (marked when hit)

	// Render bounds (re-audit): rendering is paginated and the per-row
	// "latest" annotation walks a bounded number of hops, so an
	// attacker-built long chain cannot blow up the realm page.
	MaxRenderEntries = 100
	RenderLatestHops = 10
)

// NOTE (re-audit): there is deliberately NO global entry cap. Entries
// are one-per-address by construction (self-registration), so spam
// costs funded accounts and gas; a hard cap combined with the
// registered-successor rule would let an attacker saturate the
// registry and permanently disable deprecation for every legitimate
// entry.

var (
	entries        map[address]*ContractEntry
	entryAddrs     []address // insertion-ordered for deterministic Render
	ownerContracts map[address][]address
)

func init() {
	entries = make(map[address]*ContractEntry)
	entryAddrs = []address{}
	ownerContracts = make(map[address][]address)
}

// rejectStraySend aborts when coins are attached to a call (audit Y2):
// this realm handles no funds and holds no banker, so an attached send
// would strand on the realm address forever. Aborting reverts the
// transfer back to the sender. Fails open for realm-routed calls, whose
// attached send lands on the intermediary realm, never here.
func rejectStraySend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this realm does not accept coins")
	}
}

// isValidName restricts names to lowercase alphanumeric with
// underscores. Names appear in rendered markdown and query output, so
// no delimiter or markdown character may enter one.
func isValidName(name string) bool {
	if name == "" || len(name) > MaxNameLen {
		return false
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}

func ownerIndexRemove(owner, contractAddr address) {
	old := ownerContracts[owner]
	for i, addr := range old {
		if addr == contractAddr {
			ownerContracts[owner] = append(old[:i], old[i+1:]...)
			break
		}
	}
	if len(ownerContracts[owner]) == 0 {
		delete(ownerContracts, owner)
	}
}

// ---------- write operations ----------

// Register adds the CALLING contract to the registry — the entry's
// address is the caller's own address, which is the proof of control.
// owner NOMINATES a manager (team EOA or governance realm); it holds no
// power until it calls AcceptOwnership (nobody can be made an owner
// without consent — re-audit). Pass "" to manage from the contract
// itself — but note (audit Y4): entries are permanent, so an entry
// managed by a contract that has no code path for calling this
// registry again is FROZEN as active forever: never deprecatable,
// never transferable. Realms registering from init() should nominate
// an EOA or governance manager instead.
func Register(cur realm, name string, owner address) string {
	rejectStraySend(cur)
	if !isValidName(name) {
		panic("name must be 1-" + strconv.Itoa(MaxNameLen) +
			" chars, lowercase alphanumeric with underscores only")
	}
	contractAddr := cur.Previous().Address()
	if _, exists := entries[contractAddr]; exists {
		panic("contract already registered: " + string(contractAddr))
	}
	pending := address("")
	if owner != "" && owner != contractAddr {
		if !owner.IsValid() {
			panic("invalid owner address: " + string(owner))
		}
		pending = owner
	}

	entries[contractAddr] = &ContractEntry{
		Address:      contractAddr,
		Owner:        contractAddr,
		PendingOwner: pending,
		Name:         name,
	}
	entryAddrs = append(entryAddrs, contractAddr)
	ownerContracts[contractAddr] = append(ownerContracts[contractAddr], contractAddr)
	return "registered " + name + " at " + string(contractAddr)
}

// AcceptOwnership completes a nominated ownership: only the pending
// owner can accept, and only acceptance moves the entry (and the
// ownerContracts index) to them.
func AcceptOwnership(cur realm, contractAddr address) string {
	rejectStraySend(cur)
	entry := mustGet(contractAddr)
	c := cur.Previous().Address()
	if entry.PendingOwner == "" || c != entry.PendingOwner {
		panic("caller is not the pending owner of " + string(contractAddr))
	}
	ownerIndexRemove(entry.Owner, contractAddr)
	ownerContracts[c] = append(ownerContracts[c], contractAddr)
	entry.Owner = c
	entry.PendingOwner = ""
	return "ownership accepted by " + string(c)
}

// TransferOwnership NOMINATES a new owner for a registry entry; the
// nominee must AcceptOwnership to take control (two-step — re-audit).
// Passing "" clears a pending nomination.
func TransferOwnership(cur realm, contractAddr, newOwner address) string {
	rejectStraySend(cur)
	entry := mustGet(contractAddr)
	if entry.Owner != cur.Previous().Address() {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" {
		entry.PendingOwner = ""
		return "pending ownership nomination cleared"
	}
	if !newOwner.IsValid() {
		panic("invalid new owner address: " + string(newOwner))
	}
	entry.PendingOwner = newOwner
	return "ownership nominated to " + string(newOwner) + " (pending acceptance)"
}

// Deprecate marks a contract as deprecated and points to its successor.
// Only the entry's owner can deprecate. The successor must itself be a
// REGISTERED entry — registration is self-proving, so a successor can
// never be a dangling pointer or an address squatted by a third party —
// and the successor entry must be OWNED BY THE CALLER (re-audit: without
// consent, an attacker could chain their entry INTO a legitimate
// contract, forging "official predecessor" provenance). Consent is
// checked AT CALL TIME: transferring the successor entry away later
// does not unlink an existing chain — the attestation is that both
// ends shared an owner when the deprecation was recorded.
func Deprecate(cur realm, contractAddr, successorAddr address) string {
	rejectStraySend(cur)
	entry := mustGet(contractAddr)
	if entry.Owner != cur.Previous().Address() {
		panic("only the owner can deprecate this contract")
	}
	if entry.Deprecated {
		panic("contract is already deprecated")
	}
	if successorAddr == contractAddr {
		panic("successor cannot be the contract itself")
	}
	succ, exists := entries[successorAddr]
	if !exists {
		panic("successor is not a registered contract: " + string(successorAddr))
	}
	if succ.Owner != cur.Previous().Address() {
		panic("successor entry is not owned by the caller: " + string(successorAddr))
	}

	// Prevent circular chains: walk from successor and ensure we don't
	// loop back to contractAddr. Successors are immutable once set, so
	// a check over the existing chain is complete.
	visited := make(map[address]bool)
	visited[contractAddr] = true
	walk := successorAddr
	for hops := 0; ; hops++ {
		if hops > MaxChainLen {
			// bounded-walk discipline (round-3 audit): a successor chain
			// this long is pathological; refuse rather than walk unbounded
			panic("successor chain too long to verify; cannot deprecate")
		}
		if visited[walk] {
			panic("deprecating " + string(contractAddr) + " to " +
				string(successorAddr) + " would create a circular migration chain")
		}
		e, exists := entries[walk]
		if !exists || !e.Deprecated || e.Successor == "" {
			break
		}
		visited[walk] = true
		walk = e.Successor
	}

	entry.Deprecated = true
	entry.Successor = successorAddr
	return "deprecated " + entry.Name + ", successor: " + string(successorAddr)
}

// ---------- read-only queries ----------

// GetLatest follows the migration chain from a contract address and
// returns the latest non-deprecated address. Safe against circular refs.
//
// COST WARNING (audit Y3): unlike the write-path walks, this read is
// deliberately UNBOUNDED in hops so it always resolves the true
// endpoint. Chain length is attacker-buildable, so an on-chain
// integrator resolving an UNTRUSTED address inside its own transaction
// must treat the gas cost as O(chain length) — wrap it, bound the
// input set, or resolve off-chain via query.
func GetLatest(contractAddr address) address {
	visited := make(map[address]bool)
	current := contractAddr

	for {
		entry, exists := entries[current]
		if !exists {
			return current
		}
		if !entry.Deprecated || entry.Successor == "" {
			return current
		}
		if visited[current] {
			return current // break on circular
		}
		visited[current] = true
		current = entry.Successor
	}
}

// GetMigrationChain returns the full upgrade path starting from the
// given address, at most MaxChainLen hops. A chain longer than the
// bound is explicitly marked as truncated (re-audit: silent truncation
// presented a mid-chain node as the endpoint).
func GetMigrationChain(contractAddr address) string {
	visited := make(map[address]bool)
	current := contractAddr
	var parts []string

	for {
		if len(parts) >= MaxChainLen {
			parts = append(parts, "... (truncated at "+strconv.Itoa(MaxChainLen)+
				" hops; use GetLatest for the endpoint)")
			break
		}
		entry, exists := entries[current]
		if !exists {
			if len(parts) == 0 {
				return "not found: " + string(contractAddr)
			}
			parts = append(parts, string(current)+" (unregistered)")
			break
		}
		if visited[current] {
			parts = append(parts, string(current)+" (circular)")
			break
		}
		visited[current] = true

		tag := ""
		if entry.Deprecated {
			tag = " [deprecated]"
		}
		parts = append(parts, string(entry.Address)+" ("+entry.Name+")"+tag)

		if !entry.Deprecated || entry.Successor == "" {
			break
		}
		current = entry.Successor
	}

	return strings.Join(parts, " -> ")
}

// GetInfo returns a one-line summary for a contract.
func GetInfo(contractAddr address) string {
	entry := mustGet(contractAddr)
	status := "active"
	if entry.Deprecated {
		status = "deprecated -> " + string(entry.Successor)
	}
	return entry.Name + " | owner: " + string(entry.Owner) + " | " + status
}

// GetOwnerContracts returns all contract addresses whose ACCEPTED owner
// is the given address (nominations don't count until accepted).
func GetOwnerContracts(owner address) string {
	addrs, exists := ownerContracts[owner]
	if !exists || len(addrs) == 0 {
		return "none"
	}
	parts := make([]string, len(addrs))
	for i, a := range addrs {
		parts[i] = string(a)
	}
	return strings.Join(parts, ", ")
}

// ---------- render ----------

// renderLatest walks at most RenderLatestHops hops for the per-row
// annotation; longer chains are marked rather than walked (render gas
// bound — re-audit).
func renderLatest(contractAddr address) (address, bool) {
	current := contractAddr
	for i := 0; i < RenderLatestHops; i++ {
		entry, exists := entries[current]
		if !exists || !entry.Deprecated || entry.Successor == "" {
			return current, true
		}
		current = entry.Successor
	}
	// round-3 audit off-by-one: the node reached ON the budget boundary
	// may itself be terminal — check before declaring the walk incomplete
	entry, exists := entries[current]
	if !exists || !entry.Deprecated || entry.Successor == "" {
		return current, true
	}
	return current, false
}

// Render returns a markdown overview of the most recent entries.
// Never panics.
func Render(path string) string {
	if entries == nil || len(entries) == 0 {
		return "# Upgrade Registry\n\nNo contracts registered.\n"
	}

	var b strings.Builder
	b.WriteString("# Upgrade Registry\n\n")
	b.WriteString("**Registered contracts:** " + strconv.Itoa(len(entries)) + "\n\n")

	show := entryAddrs
	if len(show) > MaxRenderEntries {
		b.WriteString("_Showing the most recent " + strconv.Itoa(MaxRenderEntries) +
			" entries._\n\n")
		show = show[len(show)-MaxRenderEntries:]
	}

	var active []string
	var deprecated []string

	for _, addr := range show {
		entry := entries[addr]
		if entry == nil {
			continue
		}
		line := "- **" + entry.Name + "** (`" + string(addr) + "`) — owner: `" + string(entry.Owner) + "`"
		if entry.Deprecated {
			line += " — **DEPRECATED** -> `" + string(entry.Successor) + "`"
			latest, complete := renderLatest(addr)
			if !complete {
				line += " (long chain; use GetLatest)"
			} else if latest != entry.Successor {
				line += " (latest: `" + string(latest) + "`)"
			}
			deprecated = append(deprecated, line)
		} else {
			active = append(active, line)
		}
	}

	if len(active) > 0 {
		b.WriteString("## Active\n\n")
		for _, l := range active {
			b.WriteString(l + "\n")
		}
		b.WriteString("\n")
	}

	if len(deprecated) > 0 {
		b.WriteString("## Deprecated\n\n")
		for _, l := range deprecated {
			b.WriteString(l + "\n")
		}
		b.WriteString("\n")
	}

	return b.String()
}

// ---------- helpers ----------

func mustGet(addr address) *ContractEntry {
	entry, ok := entries[addr]
	if !ok {
		panic("contract not found: " + string(addr))
	}
	return entry
}
