package agents

import (
	"testing"

	core "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/core"
	reg "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/registry"
)

const (
	adminAddr = address("g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq")
	aliceAddr = address("g1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	bobAddr   = address("g1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
)

const digestA = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2"

func expectAbort(t *testing.T, f func()) {
	t.Helper()
	if r := revive(f); r == nil {
		t.Fatal("expected abort, got none")
	}
}

func seedAll(cur realm) {
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !reg.IsInitialized() {
		reg.Init(cross(cur))
	}
	reg.GrantRegistrar(cross(cur), aliceAddr)
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	if !reg.HasProject("ag-proj") {
		reg.RegisterProject(cross(cur), "ag-proj", "Ag", "d", "repo", "service", "public")
	}
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !Initialized() {
		Init(cross(cur))
	}
}

func TestAgentLifecycle(cur realm, t *testing.T) {
	seedAll(cur)

	// bob registers an agent he owns
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	RegisterAgent(cross(cur), "code-review-bot", "Code Review Bot", "Reviews PRs", "1.0.0", "sandbox-runtime", []string{"code-review", "static-analysis"})

	a, ok := GetAgent("code-review-bot")
	if !ok || a.Owner != bobAddr || a.Status != core.AgentActive {
		t.Fatalf("agent registration broken: %v %s %s", ok, a.Owner, a.Status)
	}

	// alice (project owner) grants scoped permission
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	GrantPermission(cross(cur), "code-review-bot", "ag-proj", []string{core.AgentScopeRead, core.AgentScopeEvidence}, 0)

	if !HasPermission("code-review-bot", "ag-proj", core.AgentScopeEvidence) {
		t.Fatal("expected evidence permission")
	}
	if HasPermission("code-review-bot", "ag-proj", core.AgentScopePublishReq) {
		t.Fatal("publish scope must not be granted implicitly")
	}

	// bob records an execution receipt under the grant
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	eid := RecordExecution(cross(cur), "code-review-bot", "task-001", "ag-proj", digestA, "COMPLETED")
	e, _ := GetExecution(eid)
	if e.AgentID != "code-review-bot" || e.Status != "COMPLETED" {
		t.Fatal("execution record broken")
	}

	// duplicate execution id aborts
	expectAbort(t, func() {
		testing.SetRealm(testing.NewUserRealm(bobAddr))
		RecordExecution(cross(cur), "code-review-bot", "task-001", "ag-proj", digestA, "COMPLETED")
	})

	// suspension blocks execution recording
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	SuspendAgent(cross(cur), "code-review-bot")
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		RecordExecution(cross(cur), "code-review-bot", "task-002", "ag-proj", digestA, "COMPLETED")
	})

	// bob cannot suspend or resume alice-granted... bob owns the agent: resume
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	ResumeAgent(cross(cur), "code-review-bot")
	if a, _ := GetAgent("code-review-bot"); a.Status != core.AgentActive {
		t.Fatal("resume failed")
	}

	// revocation kills grants
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	RevokeAgent(cross(cur), "code-review-bot")
	if HasPermission("code-review-bot", "ag-proj", core.AgentScopeEvidence) {
		t.Fatal("revoked agent must lose grants")
	}
}

func TestGrantAuthorization(cur realm, t *testing.T) {
	seedAll(cur)

	testing.SetRealm(testing.NewUserRealm(bobAddr))
	RegisterAgent(cross(cur), "task-bot", "Task Bot", "Does tasks", "1.0.0", "runtime", []string{"tasks"})

	// bob (not project owner) cannot grant himself permissions
	expectAbort(t, func() {
		GrantPermission(cross(cur), "task-bot", "ag-proj", []string{core.AgentScopeRead}, 0)
	})

	// alice grants, then revokes
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	GrantPermission(cross(cur), "task-bot", "ag-proj", []string{core.AgentScopeTaskUpdate}, 0)

	// duplicate active grant aborts
	expectAbort(t, func() {
		GrantPermission(cross(cur), "task-bot", "ag-proj", []string{core.AgentScopeRead}, 0)
	})

	// invalid scope aborts
	expectAbort(t, func() {
		GrantPermission(cross(cur), "task-bot-x", "ag-proj", []string{"SUPERUSER"}, 0)
	})

	// bob records execution without permission: abort
	expectAbort(t, func() {
		testing.SetRealm(testing.NewUserRealm(bobAddr))
		RecordExecution(cross(cur), "task-bot", "task-100", "ag-proj", digestA, "COMPLETED")
	})

	// alice revokes the grant; bob still cannot execute
	RevokePermission(cross(cur), "task-bot", "ag-proj")
	expectAbort(t, func() {
		testing.SetRealm(testing.NewUserRealm(bobAddr))
		RecordExecution(cross(cur), "task-bot", "task-101", "ag-proj", digestA, "COMPLETED")
	})
}

func TestExpiringGrants(cur realm, t *testing.T) {
	seedAll(cur)

	testing.SetRealm(testing.NewUserRealm(bobAddr))
	RegisterAgent(cross(cur), "shortlived", "Short", "Expires fast", "1.0.0", "rt", nil)

	// grant that expires in the past aborts
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	expectAbort(t, func() {
		GrantPermission(cross(cur), "shortlived", "ag-proj", []string{core.AgentScopeRead}, 1000)
	})
}
