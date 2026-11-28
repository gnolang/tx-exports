// Package agents is the on-chain registry and accountability layer for
// autonomous AI agents in the PROOFLOOM protocol.
//
// Agents are first-class protocol participants, but they never receive
// implicit authority: every permission is a scoped, expiring, revocable
// grant made by a project owner. Execution receipts make agent work
// auditable and attributable on-chain.
//
// The agent runtime itself (LLM inference, tool use, evidence collection)
// runs entirely off-chain. This realm records identities, permissions,
// grants and execution receipts — nothing else.
package agents

import (
	"time"

	core "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/core"
	reg "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/registry"
)

// Agent is a registered autonomous actor.
type Agent struct {
	ID           string
	Name         string
	Description  string
	Owner        address
	Version      string
	Runtime      string // off-chain runtime/provider metadata reference
	Capabilities []string
	Status       string
	CreatedAt    int64
}

// Grant is a scoped, expiring permission for an agent over a project.
type Grant struct {
	AgentID   string
	ProjectID string
	Scopes    []string
	ExpiresAt int64
	GrantedBy address
	GrantedAt int64
	Revoked   bool
}

// Execution is an immutable agent execution receipt.
type Execution struct {
	ID       string
	AgentID  string
	TaskID   string
	ProjectID string
	Digest   string // content digest of the execution report
	Status   string // COMPLETED or FAILED
	RecordedBy address
	At       int64
}

var (
	agents     map[string]*Agent
	grants     map[string]*Grant // key: agentID + "/" + projectID
	executions map[string]*Execution
	agentIDs     []string
	executionIDs []string
)

func ensure() {
	if agents == nil {
		panic("agents: realm not initialized")
	}
}

// Init seeds realm state.
func Init(cur realm) {
	if agents != nil {
		panic("agents: already initialized")
	}
	agents = make(map[string]*Agent)
	grants = make(map[string]*Grant)
	executions = make(map[string]*Execution)
}

func validScope(s string) bool {
	switch s {
	case core.AgentScopeRead, core.AgentScopeEvidence, core.AgentScopeVerifyRequest,
		core.AgentScopeTaskUpdate, core.AgentScopeReviewPropose, core.AgentScopePublishReq:
		return true
	}
	return false
}

// RegisterAgent records a new agent owned by the caller.
func RegisterAgent(cur realm, id, name, description, version, runtime string, capabilities []string) {
	ensure()
	if !cur.IsCurrent() {
		panic("agents: register must run in current realm")
	}
	if !core.IsValidID(id) {
		panic("agents: invalid agent id")
	}
	if _, ok := agents[id]; ok {
		panic("agents: agent id already registered")
	}
	if !core.BoundedText(name, 128) || !core.BoundedText(description, core.MaxTextLen) ||
		!core.BoundedText(version, 32) || !core.BoundedText(runtime, 128) {
		panic("agents: metadata exceeds size limits")
	}
	if name == "" {
		panic("agents: agent name required")
	}
	if len(capabilities) > core.MaxListLen {
		panic("agents: too many capabilities")
	}
	caps := make([]string, 0, len(capabilities))
	for _, c := range capabilities {
		if !core.BoundedText(c, 64) || c == "" {
			panic("agents: invalid capability")
		}
		caps = append(caps, c)
	}
	agents[id] = &Agent{
		ID:           id,
		Name:         name,
		Description:  description,
		Owner:        cur.Previous().Address(),
		Version:      version,
		Runtime:      runtime,
		Capabilities: caps,
		Status:       core.AgentActive,
		CreatedAt:    time.Now().Unix(),
	}
	agentIDs = append(agentIDs, id)
}

// canSuspend reports whether caller may suspend the agent: the agent
// owner, the protocol admin, or the owner of any project the agent holds a
// grant on (protective control for affected project owners).
func canSuspend(a *Agent, caller address) bool {
	if a.Owner == caller || reg.IsProtocolAdmin(caller) {
		return true
	}
	for _, g := range grants {
		if g.AgentID == a.ID && !g.Revoked && reg.IsProjectOwner(g.ProjectID, caller) {
			return true
		}
	}
	return false
}

// SuspendAgent pauses an agent. Owner, protocol admin, or any project owner
// holding an active grant for the agent.
func SuspendAgent(cur realm, id string) {
	ensure()
	a := getAgent(id)
	caller := cur.Previous().Address()
	if !canSuspend(a, caller) {
		panic("agents: not authorized to suspend")
	}
	if a.Status != core.AgentActive {
		panic("agents: agent is not active")
	}
	a.Status = core.AgentSuspended
}

// ResumeAgent reactivates a suspended agent. Owner only.
func ResumeAgent(cur realm, id string) {
	ensure()
	a := getAgent(id)
	if a.Owner != cur.Previous().Address() {
		panic("agents: only the owner may resume")
	}
	if a.Status != core.AgentSuspended {
		panic("agents: agent is not suspended")
	}
	a.Status = core.AgentActive
}

// RevokeAgent permanently revokes an agent. Owner or protocol admin.
func RevokeAgent(cur realm, id string) {
	ensure()
	a := getAgent(id)
	caller := cur.Previous().Address()
	if a.Owner != caller && !reg.IsProtocolAdmin(caller) {
		panic("agents: not authorized to revoke")
	}
	if a.Status == core.AgentRevoked {
		panic("agents: agent already revoked")
	}
	a.Status = core.AgentRevoked
	// revoke all grants immediately: least privilege on termination.
	for k, g := range grants {
		if g.AgentID == id && !g.Revoked {
			g.Revoked = true
			_ = k
		}
	}
}

// GrantPermission gives an agent scoped access to a project until expiresAt.
// Only the project owner may grant. Scopes are additive across grants but
// every grant is independently revocable and expiring.
func GrantPermission(cur realm, agentID, projectID string, scopes []string, expiresAt int64) {
	ensure()
	a := getAgent(agentID)
	if a.Status != core.AgentActive {
		panic("agents: agent is not active")
	}
	if !reg.HasProject(projectID) {
		panic("agents: unknown project")
	}
	if !reg.IsProjectOwner(projectID, cur.Previous().Address()) {
		panic("agents: only the project owner may grant permissions")
	}
	if len(scopes) == 0 || len(scopes) > core.MaxListLen {
		panic("agents: invalid scope count")
	}
	for _, s := range scopes {
		if !validScope(s) {
			panic("agents: invalid scope " + s)
		}
	}
	if expiresAt != 0 && expiresAt <= time.Now().Unix() {
		panic("agents: expiry must be in the future")
	}
	key := agentID + "/" + projectID
	if g, ok := grants[key]; ok && !g.Revoked && (g.ExpiresAt == 0 || g.ExpiresAt > time.Now().Unix()) {
		panic("agents: active grant already exists for this agent and project")
	}
	grants[key] = &Grant{
		AgentID:   agentID,
		ProjectID: projectID,
		Scopes:    scopes,
		ExpiresAt: expiresAt,
		GrantedBy: cur.Previous().Address(),
		GrantedAt: time.Now().Unix(),
		Revoked:   false,
	}
}

// RevokePermission withdraws an agent's grant for a project immediately.
func RevokePermission(cur realm, agentID, projectID string) {
	ensure()
	key := agentID + "/" + projectID
	g, ok := grants[key]
	if !ok {
		panic("agents: no grant for this agent and project")
	}
	if !reg.IsProjectOwner(g.ProjectID, cur.Previous().Address()) && !reg.IsProtocolAdmin(cur.Previous().Address()) {
		panic("agents: only the project owner or admin may revoke")
	}
	g.Revoked = true
}

// HasPermission reports whether an agent holds an active, unexpired grant
// with the given scope on the project. Used by other realms and the
// off-chain runtime as the authorization gate.
func HasPermission(agentID, projectID, scope string) bool {
	ensure()
	g, ok := grants[agentID+"/"+projectID]
	if !ok || g.Revoked {
		return false
	}
	if g.ExpiresAt != 0 && g.ExpiresAt <= time.Now().Unix() {
		return false
	}
	a := agents[agentID]
	if a == nil || a.Status != core.AgentActive {
		return false
	}
	for _, s := range g.Scopes {
		if s == scope {
			return true
		}
	}
	return false
}

// RecordExecution records an immutable execution receipt. Caller must be
// the agent owner; the agent must hold EVIDENCE or TASK_UPDATE scope on the
// target project. Duplicate execution ids are structurally rejected.
func RecordExecution(cur realm, agentID, taskID, projectID, digest, status string) string {
	ensure()
	a := getAgent(agentID)
	if a.Owner != cur.Previous().Address() {
		panic("agents: only the agent owner may record executions")
	}
	if a.Status != core.AgentActive {
		panic("agents: agent is not active")
	}
	if status != "COMPLETED" && status != "FAILED" {
		panic("agents: invalid execution status")
	}
	if !core.IsValidDigest(digest) {
		panic("agents: invalid report digest")
	}
	if !core.BoundedText(taskID, 64) || !core.BoundedText(projectID, 64) {
		panic("agents: field exceeds size limits")
	}
	if projectID != "" {
		if !reg.HasProject(projectID) {
			panic("agents: unknown project")
		}
		if !HasPermission(agentID, projectID, core.AgentScopeEvidence) &&
			!HasPermission(agentID, projectID, core.AgentScopeTaskUpdate) {
			panic("agents: agent lacks required permission for project")
		}
	}
	id := agentID + "-" + taskID
	if _, exists := executions[id]; exists {
		panic("agents: duplicate execution record " + id)
	}
	executions[id] = &Execution{
		ID:         id,
		AgentID:    agentID,
		TaskID:     taskID,
		ProjectID:  projectID,
		Digest:     digest,
		Status:     status,
		RecordedBy: cur.Previous().Address(),
		At:         time.Now().Unix(),
	}
	executionIDs = append(executionIDs, id)
	return id
}

func getAgent(id string) *Agent {
	a, ok := agents[id]
	if !ok {
		panic("agents: unknown agent " + id)
	}
	return a
}

// GetAgent returns a copy of the agent record.
func GetAgent(id string) (Agent, bool) {
	ensure()
	a, ok := agents[id]
	if !ok {
		return Agent{}, false
	}
	cp := *a
	caps := make([]string, len(a.Capabilities))
	copy(caps, a.Capabilities)
	cp.Capabilities = caps
	return cp, true
}

// GetGrant returns a copy of the grant for an agent/project pair.
func GetGrant(agentID, projectID string) (Grant, bool) {
	ensure()
	g, ok := grants[agentID+"/"+projectID]
	if !ok {
		return Grant{}, false
	}
	cp := *g
	sc := make([]string, len(g.Scopes))
	copy(sc, g.Scopes)
	cp.Scopes = sc
	return cp, true
}

// GetExecution returns a copy of an execution receipt.
func GetExecution(id string) (Execution, bool) {
	ensure()
	e, ok := executions[id]
	if !ok {
		return Execution{}, false
	}
	return *e, true
}

// ListAgentIDs returns registered agent ids, newest first.
func ListAgentIDs() []string {
	ensure()
	out := make([]string, len(agentIDs))
	copy(out, agentIDs)
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// ListExecutionsByAgent returns execution ids for an agent, newest first.
func ListExecutionsByAgent(agentID string) []string {
	ensure()
	var out []string
	for _, id := range executionIDs {
		if e := executions[id]; e != nil && e.AgentID == agentID {
			out = append(out, id)
		}
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// AgentCount returns the number of registered agents.
func AgentCount() int {
	ensure()
	return len(agentIDs)
}

// Initialized reports whether the realm is initialized.
func Initialized() bool {
	return agents != nil
}
