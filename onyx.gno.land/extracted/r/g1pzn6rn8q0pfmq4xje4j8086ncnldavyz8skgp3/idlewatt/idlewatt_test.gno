package idlewatt

import (
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
	boss  = testutils.TestAddress("boss")

	who address // the account the next call is signed by
)

// reset puts the realm back to a clean state between tests.
func reset() {
	admin = boss
	paused = false
	onlineWindow = 30 * time.Minute
	nextNodeID = 1
	nextJobID = 1
	nodes = avl.NewTree()
	byOperator = avl.NewTree()
	leaderboard = avl.NewTree()
	jobs = avl.NewTree()
	nodeJobs = avl.NewTree()
	totalGrossCents = 0
	poolCents = 0
	poolPaidCents = 0
	bonusRounds = 0
	lastDistribution = time.Time{}
}

func registerGPU(cur realm, op address, name string, rate int64) int {
	who = op
	testing.SetRealm(testing.NewUserRealm(who))
	return RegisterNode(cross(cur), name, KindHomeGPU, "RTX 4090 24GB", "US-NY Buffalo", PowerGrid, rate)
}

// bringOnline heartbeats a node and makes it available.
func bringOnline(cur realm, op address, id int) {
	who = op
	testing.SetRealm(testing.NewUserRealm(who))
	Heartbeat(cross(cur), id, "")
	SetAvailability(cross(cur), id, ModeAvailable)
}

func TestRegisterNode(cur realm, t *testing.T) {
	reset()
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	id := RegisterNode(cross(cur), "Tonawanda Cybertruck (simulated)", KindVehicle, "AMD Ryzen infotainment + AI4", "US-NY Tonawanda", PowerPowershare, 30)
	uassert.Equal(t, 1, id)
	uassert.Equal(t, 1, NodeCount())

	n := mustGetNode(id)
	uassert.Equal(t, alice, n.Operator)
	uassert.Equal(t, KindVehicle, n.Kind)
	uassert.Equal(t, ModePaused, n.Mode, "new nodes start paused")
	uassert.Equal(t, int64(30), n.RateCents)
	uassert.True(t, n.LastHeartbeat.IsZero())
	uassert.Equal(t, 1, operatorNodeCount(alice))
	uassert.Equal(t, 1, leaderboard.Size())

	id2 := registerGPU(cur, bob, "Garage 4090", 45)
	uassert.Equal(t, 2, id2, "ids are sequential")
}

func TestRegisterValidation(cur realm, t *testing.T) {
	reset()
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	cases := []struct {
		name, kind, hw, region, power string
		rate                          int64
		want                          string
	}{
		{"ab", KindCPU, "Xeon", "US", PowerGrid, 10, "name must be 3-48 characters"},
		{strings.Repeat("x", 49), KindCPU, "Xeon", "US", PowerGrid, 10, "name must be 3-48 characters"},
		{" lead", KindCPU, "Xeon", "US", PowerGrid, 10, "name must not start or end with a space"},
		{"bad|pipe", KindCPU, "Xeon", "US", PowerGrid, 10, "name contains an unsupported character: only letters, digits, spaces and - . , ( ) ' / + : @ # % & = are allowed"},
		{"<script>", KindCPU, "Xeon", "US", PowerGrid, 10, "name contains an unsupported character: only letters, digits, spaces and - . , ( ) ' / + : @ # % & = are allowed"},
		{"[link](x)", KindCPU, "Xeon", "US", PowerGrid, 10, "name contains an unsupported character: only letters, digits, spaces and - . , ( ) ' / + : @ # % & = are allowed"},
		{"Box", "datacenter", "Xeon", "US", PowerGrid, 10, "kind must be one of: home-gpu, vehicle, cpu"},
		{"Box", KindCPU, "Xeon", "US", "coal", 10, "power must be one of: grid, solar, powershare-backup"},
		{"Box", KindCPU, "Xeon", "U", PowerGrid, 10, "region must be 2-40 characters"},
		{"Box", KindCPU, "X", "US", PowerGrid, 10, "hardware must be 3-80 characters"},
		{"Box", KindCPU, "Xeon", "US", PowerGrid, 0, "rate must be between 1 and 100000 US cents per hour"},
		{"Box", KindCPU, "Xeon", "US", PowerGrid, 100001, "rate must be between 1 and 100000 US cents per hour"},
	}
	for _, c := range cases {
		urequire.AbortsWithMessage(t, cur, c.want, func() {
			testing.SetRealm(testing.NewUserRealm(who))

			RegisterNode(cross(cur), c.name, c.kind, c.hw, c.region, c.power, c.rate)
		})
	}
	uassert.Equal(t, 0, NodeCount(), "no invalid node was stored")
}

func TestOperatorLimit(cur realm, t *testing.T) {
	reset()
	for i := 0; i < maxNodesPerOperator; i++ {
		registerGPU(cur, alice, "Node number "+string(rune('A'+i)), 10)
	}
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	urequire.AbortsWithMessage(t, cur, "an operator can register at most 10 nodes", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		RegisterNode(cross(cur), "One too many", KindCPU, "Xeon", "US", PowerGrid, 10)
	})
	// Another operator is unaffected.
	registerGPU(cur, bob, "Bob box", 10)
	uassert.Equal(t, maxNodesPerOperator+1, NodeCount())
}

func TestAccessControl(cur realm, t *testing.T) {
	reset()
	id := registerGPU(cur, alice, "Alice box", 40)
	who = bob
	testing.SetRealm(testing.NewUserRealm(who))
	const msg = "only the node's operator can do this"
	urequire.AbortsWithMessage(t, cur, msg, func() {
		testing.SetRealm(testing.NewUserRealm(who))
		Heartbeat(cross(cur), id, "")
	})
	urequire.AbortsWithMessage(t, cur, msg, func() {
		testing.SetRealm(testing.NewUserRealm(who))
		SetAvailability(cross(cur), id, ModeAvailable)
	})
	urequire.AbortsWithMessage(t, cur, msg, func() {
		testing.SetRealm(testing.NewUserRealm(who))
		SetRate(cross(cur), id, 1)
	})
	urequire.AbortsWithMessage(t, cur, msg, func() {
		testing.SetRealm(testing.NewUserRealm(who))

		UpdateNode(cross(cur), id, "Stolen", "RTX", "US", PowerGrid, 1)
	})
	urequire.AbortsWithMessage(t, cur, msg, func() {
		testing.SetRealm(testing.NewUserRealm(who))
		RecordJob(cross(cur), id, "steal", 60)
	})
	urequire.AbortsWithMessage(t, cur, msg, func() {
		testing.SetRealm(testing.NewUserRealm(who))
		RemoveNode(cross(cur), id)
	})
	urequire.AbortsWithMessage(t, cur, "node 99 not found", func() {
		testing.SetRealm(testing.NewUserRealm(who))
		Heartbeat(cross(cur), 99, "")
	})

	n := mustGetNode(id)
	uassert.Equal(t, int64(40), n.RateCents, "bob changed nothing")
	uassert.Equal(t, "Alice box", n.Name)
}

func TestUpdateAndRate(cur realm, t *testing.T) {
	reset()
	id := registerGPU(cur, alice, "Alice box", 40)
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	UpdateNode(cross(cur), id, "Alice solar box", "RTX 3090", "US-NY Amherst", PowerSolar, 35)
	n := mustGetNode(id)
	uassert.Equal(t, "Alice solar box", n.Name)
	uassert.Equal(t, PowerSolar, n.Power)
	uassert.Equal(t, int64(35), n.RateCents)
	SetRate(cross(cur), id, 50)
	uassert.Equal(t, int64(50), n.RateCents)
	urequire.AbortsWithMessage(t, cur, "rate must be between 1 and 100000 US cents per hour", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		SetRate(cross(cur), id, -5)
	})
}

func TestHeartbeatAndOnline(cur realm, t *testing.T) {
	reset()
	id := registerGPU(cur, alice, "Alice box", 40)
	n := mustGetNode(id)
	uassert.False(t, isOnlineAt(n, time.Now()), "no heartbeat yet")

	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	Heartbeat(cross(cur), id, "GPU 41C")
	uassert.True(t, isOnlineAt(n, time.Now()))
	uassert.Equal(t, 1, n.HeartbeatCount)
	uassert.Equal(t, "GPU 41C", n.LastNote)

	urequire.AbortsWithMessage(t, cur, "heartbeat too frequent: wait at least 10 seconds", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		Heartbeat(cross(cur), id, "")
	})
	urequire.AbortsContains(t, cur, "note contains an unsupported character", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		testing.SkipHeights(3)
		Heartbeat(cross(cur), id, "<b>")
	})

	// Steady heartbeats extend the session.
	start := n.SessionStart
	testing.SkipHeights(60) // 5 minutes
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	Heartbeat(cross(cur), id, "")
	uassert.True(t, start.Equal(n.SessionStart), "session continues")
	uassert.Equal(t, 2, n.HeartbeatCount)

	// Silence longer than the online window: offline, and a new session.
	testing.SkipHeights(12 * 31) // 31 minutes
	uassert.False(t, isOnlineAt(n, time.Now()))
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	Heartbeat(cross(cur), id, "")
	uassert.True(t, n.SessionStart.After(start), "session restarted")
	uassert.True(t, isOnlineAt(n, time.Now()))
}

func TestAvailabilityModes(cur realm, t *testing.T) {
	reset()
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	truck := RegisterNode(cross(cur), "Truck", KindVehicle, "AI4", "US-NY", PowerPowershare, 20)
	gpu := RegisterNode(cross(cur), "Desk GPU", KindHomeGPU, "RTX 4090", "US-NY", PowerGrid, 40)

	SetAvailability(cross(cur), truck, ModeDriving)
	uassert.Equal(t, ModeDriving, mustGetNode(truck).Mode)
	SetAvailability(cross(cur), truck, ModeAvailable)
	uassert.Equal(t, ModeAvailable, mustGetNode(truck).Mode)

	urequire.AbortsWithMessage(t, cur, "only vehicle nodes can be set to driving", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		SetAvailability(cross(cur), gpu, ModeDriving)
	})
	urequire.AbortsWithMessage(t, cur, "mode must be one of: available, driving, paused", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		SetAvailability(cross(cur), gpu, "sleeping")
	})
}

func TestRecordJob(cur realm, t *testing.T) {
	reset()
	id := registerGPU(cur, alice, "Alice box", 45) // $0.45/h
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))

	urequire.AbortsWithMessage(t, cur, "node must be available (parked & plugged in) to take jobs", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		RecordJob(cross(cur), id, "inference", 60)
	})
	SetAvailability(cross(cur), id, ModeAvailable)
	urequire.AbortsWithMessage(t, cur, "node is offline: send a heartbeat first", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		RecordJob(cross(cur), id, "inference", 60)
	})
	Heartbeat(cross(cur), id, "")
	urequire.AbortsWithMessage(t, cur, "minutes must be between 1 and 1440", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		RecordJob(cross(cur), id, "inference", 0)
	})
	urequire.AbortsWithMessage(t, cur, "minutes must be between 1 and 1440", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		RecordJob(cross(cur), id, "inference", 1441)
	})

	jid := RecordJob(cross(cur), id, "llama-3.3-70b inference", 200) // 200 min at 45c/h = 150c
	uassert.Equal(t, 1, jid)
	j := jobs.Get(padID(jid)).(*Job)
	uassert.Equal(t, int64(150), j.GrossCents)
	uassert.Equal(t, int64(21), j.PoolCents) // 14% of 150
	uassert.Equal(t, int64(129), j.OperatorCents)

	n := mustGetNode(id)
	uassert.Equal(t, 1, n.JobCount)
	uassert.Equal(t, int64(200), n.JobMinutes)
	uassert.Equal(t, int64(129), n.EarnedCents)
	uassert.Equal(t, int64(150), totalGrossCents)
	uassert.Equal(t, int64(21), poolCents)

	// Driving vehicles can't take jobs.
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	truck := RegisterNode(cross(cur), "Truck", KindVehicle, "AI4", "US-NY", PowerPowershare, 20)
	Heartbeat(cross(cur), truck, "")
	SetAvailability(cross(cur), truck, ModeDriving)
	urequire.AbortsWithMessage(t, cur, "node must be available (parked & plugged in) to take jobs", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		RecordJob(cross(cur), truck, "inference", 30)
	})
}

func TestLeaderboardOrder(cur realm, t *testing.T) {
	reset()
	a := registerGPU(cur, alice, "Small", 10)
	b := registerGPU(cur, bob, "Big", 100)
	c := registerGPU(cur, carol, "Idle", 50)
	bringOnline(cur, alice, a)
	bringOnline(cur, bob, b)

	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	RecordJob(cross(cur), a, "batch", 600) // 100c gross
	who = bob
	testing.SetRealm(testing.NewUserRealm(who))
	RecordJob(cross(cur), b, "batch", 600) // 1000c gross

	var order []int
	leaderboard.Iterate("", "", func(_ string, v any) bool {
		order = append(order, v.(int))
		return false
	})
	urequire.Equal(t, 3, len(order), "one leaderboard entry per node")
	uassert.Equal(t, b, order[0])
	uassert.Equal(t, a, order[1])
	uassert.Equal(t, c, order[2])
	uassert.Equal(t, 1, rankOf(mustGetNode(b)))
	uassert.Equal(t, 3, rankOf(mustGetNode(c)))

	// Small overtakes Big with more work; still one entry each.
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	for i := 0; i < 12; i++ {
		RecordJob(cross(cur), a, "batch", 1440)
	}
	uassert.Equal(t, 3, leaderboard.Size())
	uassert.Equal(t, 1, rankOf(mustGetNode(a)))
}

func TestDistributeBonus(cur realm, t *testing.T) {
	reset()
	a := registerGPU(cur, alice, "Small", 10)
	b := registerGPU(cur, bob, "Big", 1000)
	c := registerGPU(cur, carol, "Offline", 50)
	bringOnline(cur, alice, a)
	bringOnline(cur, bob, b)
	who = carol
	testing.SetRealm(testing.NewUserRealm(who))
	SetAvailability(cross(cur), c, ModeAvailable) // available but never heartbeated

	who = carol
	testing.SetRealm(testing.NewUserRealm(who))
	urequire.AbortsWithMessage(t, cur, "the fairness pool is empty", func() {
		testing.SetRealm(testing.NewUserRealm(who))
		DistributeBonus(cross(cur))
	})

	who = bob
	testing.SetRealm(testing.NewUserRealm(who))
	RecordJob(cross(cur), b, "training", 60) // 1000c gross, 140c to the pool
	uassert.Equal(t, int64(140), poolCents)

	who = carol
	testing.SetRealm(testing.NewUserRealm(who)) // anyone can crank it
	shared := DistributeBonus(cross(cur))
	uassert.Equal(t, 2, shared, "only online + available nodes share")
	uassert.Equal(t, int64(70), mustGetNode(a).BonusCents, "small node gets an equal share")
	uassert.Equal(t, int64(70), mustGetNode(b).BonusCents)
	uassert.Equal(t, int64(0), mustGetNode(c).BonusCents)
	uassert.Equal(t, int64(0), poolCents)
	uassert.Equal(t, int64(140), poolPaidCents)
	uassert.Equal(t, 1, bonusRounds)

	// Rate limited to once per hour.
	who = bob
	testing.SetRealm(testing.NewUserRealm(who))
	RecordJob(cross(cur), b, "training", 1) // 16c gross, 2c pool
	urequire.AbortsWithMessage(t, cur, "the bonus can be distributed at most once per hour", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		DistributeBonus(cross(cur))
	})

	// After an hour with everyone offline, nobody is eligible.
	testing.SkipHeights(12 * 61)
	urequire.AbortsWithMessage(t, cur, "no node is online and available to share the pool", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		DistributeBonus(cross(cur))
	})

	// A remainder smaller than one cent per node stays in the pool.
	bringOnline(cur, alice, a)
	bringOnline(cur, bob, b)
	who = carol
	testing.SetRealm(testing.NewUserRealm(who))
	Heartbeat(cross(cur), c, "")
	poolCents = 2
	urequire.AbortsWithMessage(t, cur, "the pool is too small to split", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		DistributeBonus(cross(cur))
	})
}

func TestRemoveNode(cur realm, t *testing.T) {
	reset()
	id := registerGPU(cur, alice, "Alice box", 60)
	bringOnline(cur, alice, id)
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	RecordJob(cross(cur), id, "render", 60)
	RemoveNode(cross(cur), id)
	uassert.Equal(t, 0, NodeCount())
	uassert.Equal(t, 0, leaderboard.Size())
	uassert.Equal(t, 0, operatorNodeCount(alice))
	uassert.Equal(t, 1, jobs.Size(), "job history is kept")
	uassert.Equal(t, "", NodeSummary(id))
}

func TestAdmin(cur realm, t *testing.T) {
	reset()
	id := registerGPU(cur, alice, "Spam node", 60)

	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	urequire.AbortsWithMessage(t, cur, "only the admin can do this", func() {
		testing.SetRealm(testing.NewUserRealm(who))
		SetPaused(cross(cur), true)
	})
	urequire.AbortsWithMessage(t, cur, "only the admin can do this", func() {
		testing.SetRealm(testing.NewUserRealm(who))
		AdminRemoveNode(cross(cur), id)
	})
	urequire.AbortsWithMessage(t, cur, "only the admin can do this", func() {
		testing.SetRealm(testing.NewUserRealm(who))
		TransferAdmin(cross(cur), alice)
	})
	urequire.AbortsWithMessage(t, cur, "only the admin can do this", func() {
		testing.SetRealm(testing.NewUserRealm(who))
		SetOnlineWindowMinutes(cross(cur), 60)
	})

	who = boss
	testing.SetRealm(testing.NewUserRealm(who))
	SetPaused(cross(cur), true)
	who = bob
	testing.SetRealm(testing.NewUserRealm(who))
	urequire.AbortsWithMessage(t, cur, "registrations are paused by the realm admin", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		RegisterNode(cross(cur), "Late", KindCPU, "Xeon", "US", PowerGrid, 5)
	})
	who = boss
	testing.SetRealm(testing.NewUserRealm(who))
	SetPaused(cross(cur), false)
	AdminRemoveNode(cross(cur), id)
	uassert.Equal(t, 0, NodeCount())

	urequire.AbortsWithMessage(t, cur, "online window must be between 5 and 10080 minutes", func() {
		testing.SetRealm(testing.NewUserRealm(who))

		SetOnlineWindowMinutes(cross(cur), 1)
	})
	SetOnlineWindowMinutes(cross(cur), 120)
	uassert.True(t, onlineWindow == 2*time.Hour)

	TransferAdmin(cross(cur), carol)
	uassert.Equal(t, carol, Admin())
	urequire.AbortsWithMessage(t, cur, "only the admin can do this", func() {
		testing.SetRealm(testing.NewUserRealm(who))
		SetPaused(cross(cur), true)
	})
}

func TestStats(cur realm, t *testing.T) {
	reset()
	a := registerGPU(cur, alice, "A box", 60)
	registerGPU(cur, bob, "B box", 60)
	bringOnline(cur, alice, a)
	who = alice
	testing.SetRealm(testing.NewUserRealm(who))
	RecordJob(cross(cur), a, "render", 120)
	total, online, gross, pool := Stats()
	uassert.Equal(t, 2, total)
	uassert.Equal(t, 1, online)
	uassert.Equal(t, int64(120), gross)
	uassert.Equal(t, int64(16), pool)
	uassert.True(t, strings.Contains(NodeSummary(a), "A box | home-gpu"))
}
