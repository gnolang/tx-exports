// Package idlewatt is an on-chain registry and dashboard for idle compute
// nodes: home GPU boxes today, and someday parked vehicles, that want to rent
// spare capacity on decentralized compute networks such as Akash.
//
// IMPORTANT: every node, heartbeat and job in this realm is self-reported or
// simulated by its operator. There is no Tesla or Akash integration and no
// hardware attestation; earnings are simulated USD figures, not payments.
package idlewatt

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

// Tunables.
const (
	maxNodes             = 1000
	maxNodesPerOperator  = 10
	minHeartbeatInterval = 10 * time.Second
	poolBps              = 1400 // 14% of every job feeds the fairness pool (a nod to AtomOne's Nakamoto Bonus)
	minBonusEpoch        = time.Hour
	minOnlineWindow      = 5 * time.Minute
	maxOnlineWindow      = 7 * 24 * time.Hour
)

var (
	admin        address
	paused       bool // when true, new registrations are refused
	onlineWindow = 30 * time.Minute

	nextNodeID = 1
	nextJobID  = 1

	nodes       = avl.NewTree() // padID(nodeID) -> *Node
	byOperator  = avl.NewTree() // operator + "/" + padID -> nodeID
	leaderboard = avl.NewTree() // rankKey(total, id) -> nodeID
	jobs        = avl.NewTree() // padID(jobID) -> *Job
	nodeJobs    = avl.NewTree() // padID(nodeID) + "/" + padID(jobID) -> jobID

	totalGrossCents  int64
	poolCents        int64 // undistributed fairness pool
	poolPaidCents    int64 // distributed so far
	bonusRounds      int
	lastDistribution time.Time
)

// realmURL is this realm's gnoweb path, e.g. /r/<addr>/idlewatt.
var realmURL string

func init(cur realm) {
	admin = cur.Previous().Address()
	realmURL = strings.TrimPrefix(cur.PkgPath(), "gno.land")
}

// ---------------------------------------------------------------------------
// Operator actions. Every one of them is a signed transaction, so the
// operator address is authenticated by the chain itself.

// RegisterNode adds a node owned by the caller and returns its ID.
// kind: home-gpu | vehicle | cpu. power: grid | solar | powershare-backup.
// rateCents: asking price in US cents per hour (e.g. 45 = $0.45/h).
func RegisterNode(cur realm, name, kind, hardware, region, power string, rateCents int64) int {
	caller := mustCaller(cur)
	if paused {
		panic("registrations are paused by the realm admin")
	}
	checkText("name", name, minNameLen, maxNameLen)
	checkKind(kind)
	checkText("hardware", hardware, minNameLen, maxHardwareLen)
	checkText("region", region, minRegionLen, maxRegionLen)
	checkPower(power)
	checkRate(rateCents)
	if nodes.Size() >= maxNodes {
		panic("registry is full")
	}
	if operatorNodeCount(caller) >= maxNodesPerOperator {
		panic("an operator can register at most " + strconv.Itoa(maxNodesPerOperator) + " nodes")
	}

	now := time.Now()
	n := &Node{
		ID:           nextNodeID,
		Operator:     caller,
		Name:         name,
		Kind:         kind,
		Hardware:     hardware,
		Region:       region,
		Power:        power,
		RateCents:    rateCents,
		Mode:         ModePaused,
		RegisteredAt: now,
	}
	nextNodeID++
	nodes.Set(padID(n.ID), n)
	byOperator.Set(caller.String()+"/"+padID(n.ID), n.ID)
	leaderboard.Set(rankKey(0, n.ID), n.ID)

	chain.Emit("NodeRegistered",
		"id", strconv.Itoa(n.ID),
		"operator", caller.String(),
		"kind", kind,
		"region", region,
		"power", power,
		"rateCents", strconv.FormatInt(rateCents, 10),
	)
	return n.ID
}

// UpdateNode changes a node's descriptive fields and rate. Only the operator.
func UpdateNode(cur realm, id int, name, hardware, region, power string, rateCents int64) {
	caller := mustCaller(cur)
	n := mustOwnNode(id, caller)
	checkText("name", name, minNameLen, maxNameLen)
	checkText("hardware", hardware, minNameLen, maxHardwareLen)
	checkText("region", region, minRegionLen, maxRegionLen)
	checkPower(power)
	checkRate(rateCents)

	n.Name = name
	n.Hardware = hardware
	n.Region = region
	n.Power = power
	n.RateCents = rateCents
	chain.Emit("NodeUpdated", "id", strconv.Itoa(id), "rateCents", strconv.FormatInt(rateCents, 10))
}

// SetRate changes only the hourly asking rate (US cents). Only the operator.
func SetRate(cur realm, id int, rateCents int64) {
	caller := mustCaller(cur)
	n := mustOwnNode(id, caller)
	checkRate(rateCents)
	n.RateCents = rateCents
	chain.Emit("NodeUpdated", "id", strconv.Itoa(id), "rateCents", strconv.FormatInt(rateCents, 10))
}

// SetAvailability switches a node between available (parked & plugged in),
// driving (vehicles only) and paused. Only the operator.
func SetAvailability(cur realm, id int, mode string) {
	caller := mustCaller(cur)
	n := mustOwnNode(id, caller)
	checkMode(n.Kind, mode)
	if n.Mode == mode {
		return
	}
	prev := n.Mode
	n.Mode = mode
	chain.Emit("AvailabilityChanged", "id", strconv.Itoa(id), "from", prev, "to", mode)
}

// Heartbeat records a signed liveness ping for a node, with an optional
// short status note (e.g. "SoC 82%, 41C"). Only the operator.
func Heartbeat(cur realm, id int, note string) {
	caller := mustCaller(cur)
	n := mustOwnNode(id, caller)
	if note != "" {
		checkText("note", note, 1, maxNoteLen)
	}
	now := time.Now()
	if !n.LastHeartbeat.IsZero() {
		gap := now.Sub(n.LastHeartbeat)
		if gap < minHeartbeatInterval {
			panic("heartbeat too frequent: wait at least 10 seconds")
		}
		if gap > onlineWindow {
			n.SessionStart = now // the previous run was broken
		}
	} else {
		n.SessionStart = now
	}
	n.LastHeartbeat = now
	n.HeartbeatCount++
	n.LastNote = note
	chain.Emit("Heartbeat", "id", strconv.Itoa(id), "count", strconv.Itoa(n.HeartbeatCount))
}

// RecordJob records a completed (simulated) job on a node, e.g. an AI
// inference lease. Earnings are computed by the realm from the node's rate
// and the duration, so operators cannot claim arbitrary amounts. The node
// must be available and online. 14% of the gross goes to the fairness pool.
func RecordJob(cur realm, id int, workload string, minutes int) int {
	caller := mustCaller(cur)
	n := mustOwnNode(id, caller)
	checkText("workload", workload, minNameLen, maxWorkloadLen)
	if minutes < 1 || minutes > maxJobMinutes {
		panic("minutes must be between 1 and 1440")
	}
	if n.Mode != ModeAvailable {
		panic("node must be available (parked & plugged in) to take jobs")
	}
	now := time.Now()
	if !isOnlineAt(n, now) {
		panic("node is offline: send a heartbeat first")
	}

	gross := n.RateCents * int64(minutes) / 60
	pool := gross * poolBps / 10000
	op := gross - pool

	j := &Job{
		ID:            nextJobID,
		NodeID:        n.ID,
		NodeName:      n.Name,
		Workload:      workload,
		Minutes:       minutes,
		RateCents:     n.RateCents,
		GrossCents:    gross,
		PoolCents:     pool,
		OperatorCents: op,
		CompletedAt:   now,
	}
	nextJobID++
	jobs.Set(padID(j.ID), j)
	nodeJobs.Set(padID(n.ID)+"/"+padID(j.ID), j.ID)

	oldTotal := n.TotalCents()
	n.JobCount++
	n.JobMinutes += int64(minutes)
	n.EarnedCents += op
	reRank(n, oldTotal)

	totalGrossCents += gross
	poolCents += pool

	chain.Emit("JobRecorded",
		"job", strconv.Itoa(j.ID),
		"node", strconv.Itoa(n.ID),
		"minutes", strconv.Itoa(minutes),
		"grossCents", strconv.FormatInt(gross, 10),
		"poolCents", strconv.FormatInt(pool, 10),
		"simulated", "true",
	)
	return j.ID
}

// RemoveNode deletes the caller's node. Its job history stays on the record.
func RemoveNode(cur realm, id int) {
	caller := mustCaller(cur)
	n := mustOwnNode(id, caller)
	removeNode(n)
	chain.Emit("NodeRemoved", "id", strconv.Itoa(id), "by", "operator")
}

// DistributeBonus splits the fairness pool equally across every node that is
// online and available right now, regardless of size or earnings, like
// AtomOne's Nakamoto Bonus splits its pool equally across validators.
// Anyone may call it, at most once per hour. Returns how many nodes shared.
func DistributeBonus(cur realm) int {
	mustCaller(cur)
	now := time.Now()
	if !lastDistribution.IsZero() && now.Sub(lastDistribution) < minBonusEpoch {
		panic("the bonus can be distributed at most once per hour")
	}
	if poolCents <= 0 {
		panic("the fairness pool is empty")
	}
	var eligible []*Node
	nodes.Iterate("", "", func(_ string, v any) bool {
		n := v.(*Node)
		if n.Mode == ModeAvailable && isOnlineAt(n, now) {
			eligible = append(eligible, n)
		}
		return false
	})
	if len(eligible) == 0 {
		panic("no node is online and available to share the pool")
	}
	share := poolCents / int64(len(eligible))
	if share == 0 {
		panic("the pool is too small to split")
	}
	for _, n := range eligible {
		old := n.TotalCents()
		n.BonusCents += share
		reRank(n, old)
	}
	paid := share * int64(len(eligible))
	poolCents -= paid // the remainder stays for next round
	poolPaidCents += paid
	bonusRounds++
	lastDistribution = now
	chain.Emit("BonusDistributed",
		"round", strconv.Itoa(bonusRounds),
		"nodes", strconv.Itoa(len(eligible)),
		"shareCents", strconv.FormatInt(share, 10),
	)
	return len(eligible)
}

// ---------------------------------------------------------------------------
// Admin actions (moderation of a public demo registry).

// SetPaused stops or resumes new registrations.
func SetPaused(cur realm, p bool) {
	mustAdmin(cur)
	paused = p
	chain.Emit("PausedChanged", "paused", strconv.FormatBool(p))
}

// SetOnlineWindowMinutes sets how long after its last heartbeat a node still
// counts as online (5 minutes to 7 days).
func SetOnlineWindowMinutes(cur realm, minutes int) {
	mustAdmin(cur)
	w := time.Duration(minutes) * time.Minute
	if w < minOnlineWindow || w > maxOnlineWindow {
		panic("online window must be between 5 and 10080 minutes")
	}
	onlineWindow = w
	chain.Emit("OnlineWindowChanged", "minutes", strconv.Itoa(minutes))
}

// AdminRemoveNode removes a spam or abusive node.
func AdminRemoveNode(cur realm, id int) {
	mustAdmin(cur)
	n := mustGetNode(id)
	removeNode(n)
	chain.Emit("NodeRemoved", "id", strconv.Itoa(id), "by", "admin")
}

// TransferAdmin hands the admin role to another address.
func TransferAdmin(cur realm, newAdmin address) {
	mustAdmin(cur)
	if !newAdmin.IsValid() {
		panic("invalid address")
	}
	old := admin
	admin = newAdmin
	chain.Emit("AdminChanged", "from", old.String(), "to", newAdmin.String())
}

// ---------------------------------------------------------------------------
// Read-only helpers (safe to query with vm/qeval).

// Admin returns the admin address.
func Admin() address { return admin }

// NodeCount returns the number of registered nodes.
func NodeCount() int { return nodes.Size() }

// Stats returns nodes, online nodes, simulated gross earnings (cents) and the
// undistributed fairness pool (cents).
func Stats() (int, int, int64, int64) {
	return nodes.Size(), countOnline(time.Now()), totalGrossCents, poolCents
}

// NodeSummary returns a one-line text summary of a node, or "" if unknown.
func NodeSummary(id int) string {
	v := nodes.Get(padID(id))
	if v == nil {
		return ""
	}
	n := v.(*Node)
	return n.Name + " | " + n.Kind + " | " + n.Region + " | " + n.Power + " | " +
		fmtUSD(n.RateCents) + "/h | " + statusOf(n, time.Now()) + " | earned " + fmtUSD(n.TotalCents())
}

// ---------------------------------------------------------------------------
// internals

func mustCaller(cur realm) address {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	prev := cur.Previous()
	if !prev.IsUser() {
		panic("only user accounts can call this")
	}
	return prev.Address()
}

func mustAdmin(cur realm) {
	if mustCaller(cur) != admin {
		panic("only the admin can do this")
	}
}

func mustGetNode(id int) *Node {
	v := nodes.Get(padID(id))
	if v == nil {
		panic("node " + strconv.Itoa(id) + " not found")
	}
	return v.(*Node)
}

func mustOwnNode(id int, caller address) *Node {
	n := mustGetNode(id)
	if n.Operator != caller {
		panic("only the node's operator can do this")
	}
	return n
}

func removeNode(n *Node) {
	nodes.Remove(padID(n.ID))
	byOperator.Remove(n.Operator.String() + "/" + padID(n.ID))
	leaderboard.Remove(rankKey(n.TotalCents(), n.ID))
}

func reRank(n *Node, oldTotal int64) {
	leaderboard.Remove(rankKey(oldTotal, n.ID))
	leaderboard.Set(rankKey(n.TotalCents(), n.ID), n.ID)
}

func operatorNodeCount(op address) int {
	count := 0
	prefix := op.String() + "/"
	byOperator.Iterate(prefix, prefix+"~", func(_ string, _ any) bool {
		count++
		return false
	})
	return count
}

func isOnlineAt(n *Node, now time.Time) bool {
	if n.LastHeartbeat.IsZero() {
		return false
	}
	return now.Sub(n.LastHeartbeat) <= onlineWindow
}

func countOnline(now time.Time) int {
	count := 0
	nodes.Iterate("", "", func(_ string, v any) bool {
		if isOnlineAt(v.(*Node), now) {
			count++
		}
		return false
	})
	return count
}

// padID makes IDs sort numerically as avl keys.
func padID(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 9 {
		s = "0" + s
	}
	return s
}

// rankKey sorts the highest total first, ties broken by lowest node ID.
func rankKey(totalCents int64, id int) string {
	const ceiling = int64(999999999999999)
	inv := strconv.FormatInt(ceiling-totalCents, 10)
	for len(inv) < 15 {
		inv = "0" + inv
	}
	return inv + "/" + padID(id)
}
