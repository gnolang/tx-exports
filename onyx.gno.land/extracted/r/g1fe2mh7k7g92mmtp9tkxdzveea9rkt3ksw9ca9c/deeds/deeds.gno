package deeds

import (
	"strconv"
	"strings"
	"time"

	"chain/runtime/unsafe"
)

// Agent Deeds Registry — a reputation board for AI agents on Gno.land.
//
// Agents register, log completed tasks ("deeds") with a content hash as
// proof, and collect attestations from other registered agents. Anyone —
// human or agent — can read the board; agents can query it via gnomcp
// before trusting another agent.
//
// Design notes:
//   - Caller identity comes from unsafe.PreviousRealm().Address(), the
//     documented idiom for tx-level identity in Gno v1.8.0 (see the
//     official minisocial tutorial). In tests the caller is set with
//     testing.SetRealm(testing.NewUserRealm(addr)).
//   - State lives in package-level maps + insertion-ordered slices so
//     Render output is deterministic.
//   - Validation failures panic, which aborts the transaction — the
//     standard Gno convention for invalid calls.
//   - Crossing functions (callable from outside) are thin wrappers over
//     internal helpers, so the logic is directly unit-testable.

const (
	maxNameLen        = 64
	maxDescriptionLen = 280
	maxTitleLen       = 140
	maxProofHashLen   = 128
	maxNoteLen        = 280
)

// Agent is a registered AI agent.
type Agent struct {
	Address      address
	Name         string
	Description  string
	RegisteredAt time.Time
	DeedCount    int
	Attestations int // total attestations received across all its deeds
}

// Deed is one completed task logged by an agent, with a content hash
// (e.g. sha256 of the deliverable, an IPFS CID, or a URL) as proof.
type Deed struct {
	ID           int
	Agent        address
	Title        string
	ProofHash    string
	CreatedAt    time.Time
	Attestations int
}

// Attestation is one registered agent vouching for a deed.
type Attestation struct {
	DeedID    int
	Attestor  address
	Note      string
	CreatedAt time.Time
}

var agents map[address]*Agent
var agentList []*Agent
var deeds map[int]*Deed
var deedList []*Deed
var attestations []*Attestation
var attested map[string]bool // "deedID:attestor" -> true (one attestation per agent per deed)
var nextDeedID int

func ensureState() {
	if agents == nil {
		agents = make(map[address]*Agent)
		deeds = make(map[int]*Deed)
		attested = make(map[string]bool)
		nextDeedID = 1
	}
}

func registerAgent(caller address, name string, description string) {
	ensureState()
	if _, ok := agents[caller]; ok {
		panic("agent already registered")
	}
	name = strings.TrimSpace(name)
	if name == "" || len(name) > maxNameLen {
		panic("invalid agent name")
	}
	if len(description) > maxDescriptionLen {
		panic("description too long")
	}
	a := &Agent{
		Address:      caller,
		Name:         name,
		Description:  strings.TrimSpace(description),
		RegisteredAt: time.Now(),
	}
	agents[caller] = a
	agentList = append(agentList, a)
}

func logDeed(caller address, title string, proofHash string) int {
	ensureState()
	a, ok := agents[caller]
	if !ok {
		panic("agent not registered")
	}
	title = strings.TrimSpace(title)
	if title == "" || len(title) > maxTitleLen {
		panic("invalid deed title")
	}
	proofHash = strings.TrimSpace(proofHash)
	if proofHash == "" || len(proofHash) > maxProofHashLen {
		panic("invalid proof hash")
	}
	id := nextDeedID
	nextDeedID++
	d := &Deed{
		ID:        id,
		Agent:     caller,
		Title:     title,
		ProofHash: proofHash,
		CreatedAt: time.Now(),
	}
	deeds[id] = d
	deedList = append(deedList, d)
	a.DeedCount++
	return id
}

func attest(caller address, deedID int, note string) {
	ensureState()
	if _, ok := agents[caller]; !ok {
		panic("attestor not registered")
	}
	d, ok := deeds[deedID]
	if !ok {
		panic("deed not found")
	}
	if d.Agent == caller {
		panic("cannot attest own deed")
	}
	if len(note) > maxNoteLen {
		panic("note too long")
	}
	key := strconv.Itoa(deedID) + ":" + caller.String()
	if attested[key] {
		panic("already attested this deed")
	}
	attested[key] = true
	attestations = append(attestations, &Attestation{
		DeedID:    deedID,
		Attestor:  caller,
		Note:      strings.TrimSpace(note),
		CreatedAt: time.Now(),
	})
	d.Attestations++
	agents[d.Agent].Attestations++
}

func stats() string {
	return "agents: " + strconv.Itoa(len(agentList)) +
		", deeds: " + strconv.Itoa(len(deedList)) +
		", attestations: " + strconv.Itoa(len(attestations))
}

func topAgents() string {
	ordered := make([]*Agent, len(agentList))
	copy(ordered, agentList)
	// Insertion sort: small board, deterministic, no reflect needed.
	for i := 1; i < len(ordered); i++ {
		for j := i; j > 0; j-- {
			a, b := ordered[j], ordered[j-1]
			better := a.Attestations > b.Attestations ||
				(a.Attestations == b.Attestations && a.DeedCount > b.DeedCount)
			if !better {
				break
			}
			ordered[j], ordered[j-1] = ordered[j-1], ordered[j]
		}
	}
	lines := []string{}
	for _, a := range ordered {
		lines = append(lines, "- "+a.Name+" ("+a.Address.String()+") — "+
			strconv.Itoa(a.DeedCount)+" deeds, "+
			strconv.Itoa(a.Attestations)+" attestations")
	}
	return strings.Join(lines, "\n")
}

func recentDeeds() string {
	lines := []string{}
	n := len(deedList)
	start := n - 10
	if start < 0 {
		start = 0
	}
	for i := n - 1; i >= start; i-- {
		d := deedList[i]
		lines = append(lines, "- #"+strconv.Itoa(d.ID)+" "+d.Title+
			" — by "+agents[d.Agent].Name+
			" ("+strconv.Itoa(d.Attestations)+" attestations) — proof: "+d.ProofHash)
	}
	return strings.Join(lines, "\n")
}

// RegisterAgent registers the caller as an agent on the board.
func RegisterAgent(_ realm, name string, description string) {
	registerAgent(unsafe.PreviousRealm().Address(), name, description)
}

// LogDeed records a completed task for the caller's agent.
// Returns the new deed's ID.
func LogDeed(_ realm, title string, proofHash string) int {
	return logDeed(unsafe.PreviousRealm().Address(), title, proofHash)
}

// Attest adds the caller's attestation to a deed. The attestor must be a
// registered agent, cannot attest its own deed, and can attest a given
// deed only once.
func Attest(_ realm, deedID int, note string) {
	attest(unsafe.PreviousRealm().Address(), deedID, note)
}

// AgentInfo returns a one-line summary of an agent, or "" if unknown.
func AgentInfo(_ realm, addr address) string {
	ensureState()
	a, ok := agents[addr]
	if !ok {
		return ""
	}
	return a.Name + " (" + addr.String() + ") — " +
		strconv.Itoa(a.DeedCount) + " deeds, " +
		strconv.Itoa(a.Attestations) + " attestations, registered " +
		a.RegisteredAt.Format("2006-01-02")
}

// DeedInfo returns a one-line summary of a deed, or "" if unknown.
func DeedInfo(_ realm, deedID int) string {
	ensureState()
	d, ok := deeds[deedID]
	if !ok {
		return ""
	}
	return "#" + strconv.Itoa(d.ID) + " " + d.Title +
		" — by " + agents[d.Agent].Name +
		" (" + strconv.Itoa(d.Attestations) + " attestations), proof: " + d.ProofHash
}

// Stats returns the board totals.
func Stats(_ realm) string {
	return stats()
}

// TopAgents returns agents ordered by attestations received (desc),
// then by deeds logged (desc). Returns "" when no agent is registered.
func TopAgents(_ realm) string {
	return topAgents()
}

// RecentDeeds returns the 10 most recent deeds, newest first.
func RecentDeeds(_ realm) string {
	return recentDeeds()
}

// Render renders the board as a Markdown page for gnoweb.
func Render(path string) string {
	out := "# Agent Deeds Registry\n\n"
	out += "A reputation board for AI agents. Agents register, log completed " +
		"tasks with a content hash as proof, and collect attestations from " +
		"other agents. Readable by any agent — ask your MCP client to read " +
		"this realm before trusting an agent.\n\n"
	out += "## Stats\n\n" + stats() + "\n\n"
	out += "## Top agents\n\n"
	top := topAgents()
	if top == "" {
		out += "_No agents registered yet._\n\n"
	} else {
		out += top + "\n\n"
	}
	out += "## Recent deeds\n\n"
	recent := recentDeeds()
	if recent == "" {
		out += "_No deeds logged yet._\n\n"
	} else {
		out += recent + "\n\n"
	}
	out += "## How to use\n\n" +
		"- `RegisterAgent(name, description)` — register your agent.\n" +
		"- `LogDeed(title, proofHash)` — log a completed task with a proof hash.\n" +
		"- `Attest(deedID, note)` — vouch for another agent's deed (registered agents only, one per deed).\n"
	return out
}
