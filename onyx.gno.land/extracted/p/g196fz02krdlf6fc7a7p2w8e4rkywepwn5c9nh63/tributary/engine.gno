package tributary

import (
	"errors"
	"sort"
	"strings"

	"gno.land/p/nt/avl/v0"
)

var (
	ErrInvalidID         = errors.New("tributary: node id must be 2..40 chars [a-z0-9_-]")
	ErrNodeExists        = errors.New("tributary: node id already exists")
	ErrNodeNotFound      = errors.New("tributary: node not found")
	ErrUnauthorized      = errors.New("tributary: caller is not node owner")
	ErrNodeLocked        = errors.New("tributary: node graph is permanently locked")
	ErrInvalidAddress    = errors.New("tributary: invalid address")
	ErrInvalidBPS        = errors.New("tributary: edge bps must be 1..10000 and total <= 10000")
	ErrDuplicateEdge     = errors.New("tributary: duplicate upstream target in split set")
	ErrTooManyEdges      = errors.New("tributary: exceeds max upstream edges per node")
	ErrCycleDetected     = errors.New("tributary: cycle detected in dependency graph")
	ErrMaxDepthExceeded  = errors.New("tributary: dependency graph exceeds max depth")
	ErrInvalidAmount     = errors.New("tributary: amount must be positive")
	ErrNothingToClaim    = errors.New("tributary: no claimable balance for address")
)

// Engine is a deterministic, cycle-proof, zero-dust DAG revenue waterfall ledger.
// It is pure state + accounting so any realm can embed it and pair it with
// its own chain/banker escrow under strict Checks-Effects-Interactions.
type Engine struct {
	nodes         *avl.Tree // nodeID -> *Node
	pending       *avl.Tree // addr.String() -> int64
	claimed       *avl.Tree // addr.String() -> int64
	receipts      []DepositReceipt
	nextSeq       int64
	totalRouted   int64
	totalClaimed  int64
	lockedCount   int
}

// NewEngine initializes an empty Tributary DAG engine.
func NewEngine() *Engine {
	return &Engine{
		nodes:   avl.NewTree(),
		pending: avl.NewTree(),
		claimed: avl.NewTree(),
	}
}

// ValidateID checks that id is a clean URL-safe slug (2..40 chars, lowercase alnum/-/_).
func ValidateID(id string) bool {
	if len(id) < 2 || len(id) > 40 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

// RegisterNode creates a new node in the dependency graph.
func (e *Engine) RegisterNode(id, title, pkgRef string, owner, beneficiary address, height int64) (*Node, error) {
	if !ValidateID(id) {
		return nil, ErrInvalidID
	}
	if e.nodes.Has(id) {
		return nil, ErrNodeExists
	}
	if !owner.IsValid() || !beneficiary.IsValid() {
		return nil, ErrInvalidAddress
	}
	cleanTitle := strings.TrimSpace(title)
	if cleanTitle == "" {
		cleanTitle = id
	}
	n := &Node{
		ID:            id,
		Title:         cleanTitle,
		PkgRef:        strings.TrimSpace(pkgRef),
		Owner:         owner,
		Beneficiary:   beneficiary,
		CreatedHeight: height,
	}
	e.nodes.Set(id, n)
	return n, nil
}

// GetNode returns a node by ID, or nil if absent.
func (e *Engine) GetNode(id string) *Node {
	v := e.nodes.Get(id)
	if v == nil {
		return nil
	}
	return v.(*Node)
}

// NodeCount returns the total number of registered nodes.
func (e *Engine) NodeCount() int {
	return e.nodes.Size()
}

// LockedCount returns how many nodes have cryptographically frozen splits.
func (e *Engine) LockedCount() int {
	return e.lockedCount
}

// TotalRouted returns cumulative ugnot routed across all deposits.
func (e *Engine) TotalRouted() int64 {
	return e.totalRouted
}

// TotalClaimed returns cumulative ugnot withdrawn by beneficiaries.
func (e *Engine) TotalClaimed() int64 {
	return e.totalClaimed
}

// EscrowedTotal returns total ugnot currently held pending claim across all addresses.
func (e *Engine) EscrowedTotal() int64 {
	return e.totalRouted - e.totalClaimed
}

// PendingOf returns the claimable balance for an address.
func (e *Engine) PendingOf(addr address) int64 {
	v := e.pending.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

// ClaimedOf returns cumulative claimed amount for an address.
func (e *Engine) ClaimedOf(addr address) int64 {
	v := e.claimed.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

// SetBeneficiary updates a node's beneficiary address (only when unlocked and called by owner).
func (e *Engine) SetBeneficiary(id string, caller, newBeneficiary address) error {
	n := e.GetNode(id)
	if n == nil {
		return ErrNodeNotFound
	}
	if n.Owner != caller {
		return ErrUnauthorized
	}
	if n.Locked {
		return ErrNodeLocked
	}
	if !newBeneficiary.IsValid() {
		return ErrInvalidAddress
	}
	n.Beneficiary = newBeneficiary
	return nil
}

// SetSplits atomically replaces the upstream dependency edges of node id.
// Enforces: owner auth, unlocked check, valid BPS (sum <= 10000), no duplicates,
// strict acyclicity (DFS), and bounded graph depth (<= MaxDepth).
func (e *Engine) SetSplits(id string, caller address, edges []Edge) error {
	n := e.GetNode(id)
	if n == nil {
		return ErrNodeNotFound
	}
	if n.Owner != caller {
		return ErrUnauthorized
	}
	if n.Locked {
		return ErrNodeLocked
	}
	if len(edges) > MaxEdgesPerNode {
		return ErrTooManyEdges
	}

	seen := make(map[string]bool, len(edges))
	var sumBPS int64
	cleaned := make([]Edge, 0, len(edges))

	for _, ed := range edges {
		if ed.BPS <= 0 || ed.BPS > ScaleBPS {
			return ErrInvalidBPS
		}
		if ed.TargetID == id {
			return ErrCycleDetected
		}
		if seen[ed.TargetID] {
			return ErrDuplicateEdge
		}
		target := e.GetNode(ed.TargetID)
		if target == nil {
			return ErrNodeNotFound
		}
		// Cycle check: if target can already reach id, adding id -> target creates a cycle.
		if e.canReach(ed.TargetID, id) {
			return ErrCycleDetected
		}
		seen[ed.TargetID] = true
		sumBPS += ed.BPS
		if sumBPS > ScaleBPS {
			return ErrInvalidBPS
		}
		cleaned = append(cleaned, Edge{
			TargetID: ed.TargetID,
			BPS:      ed.BPS,
			Label:    strings.TrimSpace(ed.Label),
		})
	}

	// Temporarily apply to check depth invariant across the full DAG, rollback if exceeded.
	prev := n.Edges
	n.Edges = cleaned
	if e.maxDepthFromAnyAncestor(id) > MaxDepth {
		n.Edges = prev
		return ErrMaxDepthExceeded
	}
	return nil
}

// Lock permanently freezes a node's beneficiary and upstream splits so downstream
// funders have an immutable on-chain guarantee that royalty shares cannot be rug-pulled.
func (e *Engine) Lock(id string, caller address) error {
	n := e.GetNode(id)
	if n == nil {
		return ErrNodeNotFound
	}
	if n.Owner != caller {
		return ErrUnauthorized
	}
	if n.Locked {
		return nil
	}
	n.Locked = true
	e.lockedCount++
	return nil
}

// canReach reports whether start can reach goal along directed upstream edges.
func (e *Engine) canReach(start, goal string) bool {
	visited := make(map[string]bool)
	stack := []string{start}
	for len(stack) > 0 {
		cur := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if cur == goal {
			return true
		}
		if visited[cur] {
			continue
		}
		visited[cur] = true
		node := e.GetNode(cur)
		if node == nil {
			continue
		}
		for _, ed := range node.Edges {
			if !visited[ed.TargetID] {
				stack = append(stack, ed.TargetID)
			}
		}
	}
	return false
}

// subgraphDepth computes longest directed path length starting at root.
func (e *Engine) subgraphDepth(root string, memo map[string]int) int {
	if d, ok := memo[root]; ok {
		return d
	}
	n := e.GetNode(root)
	if n == nil || len(n.Edges) == 0 {
		memo[root] = 0
		return 0
	}
	best := 0
	for _, ed := range n.Edges {
		d := 1 + e.subgraphDepth(ed.TargetID, memo)
		if d > best {
			best = d
		}
	}
	memo[root] = best
	return best
}

// maxDepthFromAnyAncestor checks longest chain passing through or rooted at any node
// that can reach changedID (keeps total DAG depth <= MaxDepth).
func (e *Engine) maxDepthFromAnyAncestor(changedID string) int {
	memo := make(map[string]int)
	best := e.subgraphDepth(changedID, memo)
	e.nodes.Iterate("", "", func(k string, _ any) bool {
		if k == changedID || e.canReach(k, changedID) {
			d := e.subgraphDepth(k, memo)
			if d > best {
				best = d
			}
		}
		return false
	})
	return best
}

// TopologicalOrder collects all nodes reachable from rootID in topological order
// (downstream before upstream), ensuring diamond-DAG convergence is exact in one pass.
func (e *Engine) TopologicalOrder(rootID string) []string {
	// Step 1: collect reachable subgraph and compute in-degrees within subgraph.
	reachable := make(map[string]bool)
	inDeg := make(map[string]int)
	queue := []string{rootID}
	reachable[rootID] = true
	inDeg[rootID] = 0

	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		n := e.GetNode(cur)
		if n == nil {
			continue
		}
		for _, ed := range n.Edges {
			if !reachable[ed.TargetID] {
				reachable[ed.TargetID] = true
				queue = append(queue, ed.TargetID)
			}
			inDeg[ed.TargetID]++
		}
	}

	// Step 2: Kahn's algorithm with deterministic lexicographical tie-breaking.
	ready := make([]string, 0)
	for id := range reachable {
		if inDeg[id] == 0 {
			ready = append(ready, id)
		}
	}
	sort.Strings(ready)

	order := make([]string, 0, len(reachable))
	for len(ready) > 0 {
		cur := ready[0]
		ready = ready[1:]
		order = append(order, cur)
		n := e.GetNode(cur)
		if n == nil {
			continue
		}
		added := false
		for _, ed := range n.Edges {
			inDeg[ed.TargetID]--
			if inDeg[ed.TargetID] == 0 {
				ready = append(ready, ed.TargetID)
				added = true
			}
		}
		if added {
			sort.Strings(ready)
		}
	}
	return order
}

// Route cascades amount deterministically from entryID through its entire upstream DAG
// in topological order. Every single integer truncation remainder stays with the node's
// beneficiary so total credited == amount with ZERO dust ever lost.
func (e *Engine) Route(entryID string, depositor address, amount int64, height int64, memo string) (DepositReceipt, []TraceStep, error) {
	if amount <= 0 {
		return DepositReceipt{}, nil, ErrInvalidAmount
	}
	if e.GetNode(entryID) == nil {
		return DepositReceipt{}, nil, ErrNodeNotFound
	}

	order := e.TopologicalOrder(entryID)
	inflow := make(map[string]int64, len(order))
	inflow[entryID] = amount

	traces := make([]TraceStep, 0, len(order)*2)
	creditedAddrs := make(map[address]bool)
	hops := 0

	for _, id := range order {
		amt := inflow[id]
		if amt <= 0 {
			continue
		}
		n := e.GetNode(id)
		n.TotalInflow += amt

		var forwarded int64
		for _, ed := range n.Edges {
			share := (amt * ed.BPS) / ScaleBPS
			if share > 0 {
				inflow[ed.TargetID] += share
				forwarded += share
				hops++
				traces = append(traces, TraceStep{
					FromID: id,
					ToID:   ed.TargetID,
					Amount: share,
					BPS:    ed.BPS,
				})
			}
		}

		// Zero-dust conservation: any integer rounding remainder stays cleanly with n.Beneficiary.
		retained := amt - forwarded
		n.TotalForwarded += forwarded
		n.TotalRetained += retained

		if retained > 0 {
			e.credit(n.Beneficiary, retained)
			creditedAddrs[n.Beneficiary] = true
			traces = append(traces, TraceStep{
				FromID: id,
				ToID:   "",
				Amount: retained,
				BPS:    n.RetainedBPS(),
			})
		}
	}

	e.nextSeq++
	e.totalRouted += amount
	rcpt := DepositReceipt{
		Seq:       e.nextSeq,
		EntryID:   entryID,
		Depositor: depositor,
		Amount:    amount,
		Height:    height,
		Hops:      hops,
		Credits:   len(creditedAddrs),
		Memo:      strings.TrimSpace(memo),
	}
	e.receipts = append(e.receipts, rcpt)
	if len(e.receipts) > MaxReceiptsStored {
		e.receipts = e.receipts[len(e.receipts)-MaxReceiptsStored:]
	}
	return rcpt, traces, nil
}

// EffectiveShares simulates routing 10,000 BPS (100.00%) into rootID and returns
// the exact effective basis-point share received by every node in the DAG.
func (e *Engine) EffectiveShares(rootID string) []ShareEntry {
	if e.GetNode(rootID) == nil {
		return nil
	}
	order := e.TopologicalOrder(rootID)
	inflow := make(map[string]int64, len(order))
	inflow[rootID] = ScaleBPS

	out := make([]ShareEntry, 0, len(order))
	for _, id := range order {
		amt := inflow[id]
		n := e.GetNode(id)
		var forwarded int64
		for _, ed := range n.Edges {
			share := (amt * ed.BPS) / ScaleBPS
			inflow[ed.TargetID] += share
			forwarded += share
		}
		retained := amt - forwarded
		out = append(out, ShareEntry{
			NodeID:       n.ID,
			Title:        n.Title,
			Beneficiary:  n.Beneficiary,
			EffectiveBPS: retained,
		})
	}
	return out
}

// DeductClaim atomically zeroes addr's pending balance and records it as claimed.
// Call this BEFORE Banker.SendCoins to uphold strict Checks-Effects-Interactions.
func (e *Engine) DeductClaim(addr address) (int64, error) {
	if !addr.IsValid() {
		return 0, ErrInvalidAddress
	}
	amt := e.PendingOf(addr)
	if amt <= 0 {
		return 0, ErrNothingToClaim
	}
	key := addr.String()
	e.pending.Set(key, int64(0))
	e.claimed.Set(key, e.ClaimedOf(addr)+amt)
	e.totalClaimed += amt
	return amt, nil
}

// ListNodes returns all registered nodes in deterministic alphabetical order.
func (e *Engine) ListNodes() []*Node {
	out := make([]*Node, 0, e.nodes.Size())
	e.nodes.Iterate("", "", func(_ string, v any) bool {
		out = append(out, v.(*Node))
		return false
	})
	return out
}

// RecentReceipts returns stored deposit receipts (newest first).
func (e *Engine) RecentReceipts() []DepositReceipt {
	n := len(e.receipts)
	out := make([]DepositReceipt, n)
	for i := 0; i < n; i++ {
		out[i] = e.receipts[n-1-i]
	}
	return out
}

func (e *Engine) credit(addr address, amt int64) {
	key := addr.String()
	e.pending.Set(key, e.PendingOf(addr)+amt)
}
