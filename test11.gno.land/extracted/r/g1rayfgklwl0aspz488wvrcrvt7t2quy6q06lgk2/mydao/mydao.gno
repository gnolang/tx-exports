package mydao

import (
	"chain/runtime"
	"strings"
	"strconv"
)

// ── Types ─────────────────────────────────────────────────

type Member struct {
	Address address
	Power   int
	Roles   []string
}

type Vote struct {
	Voter address
	Value string // "YES", "NO", "ABSTAIN"
}

type Proposal struct {
	ID          int
	Title       string
	Description string
	Category    string
	Author      address
	Status      string // "ACTIVE", "ACCEPTED", "REJECTED", "EXECUTED"
	Votes       []Vote
	YesVotes    int
	NoVotes     int
	Abstain     int
	TotalPower  int
	ActionType  string // "none", "add_member", "remove_member", "assign_role"
	ActionData  string // serialized action params (e.g. "addr|power|role1,role2")
}

// ── State ─────────────────────────────────────────────────

var (
	name              = "\\|<o_o>|/"
	description       = ""
	threshold         = 1 // percentage required to pass
	quorum            = 0  // minimum participation % (0 = disabled)
	members           []Member
	proposals         []Proposal
	nextID            = 0
	allowedCategories []string
	allowedRoles      []string
	archived          = false
)

func init() {
	members = append(members, Member{Address: address("g1rayfgklwl0aspz488wvrcrvt7t2quy6q06lgk2"), Power: 1, Roles: []string{"admin"}})
	allowedCategories = append(allowedCategories, "governance")
	allowedCategories = append(allowedCategories, "membership")
	allowedCategories = append(allowedCategories, "operations")
	allowedRoles = append(allowedRoles, "admin")
	allowedRoles = append(allowedRoles, "member")
}

// ── Queries ───────────────────────────────────────────────

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	// Parse proposal ID from path
	parts := strings.Split(path, "/")
	if len(parts) >= 1 {
		id, err := strconv.Atoi(parts[0])
		if err == nil && id >= 0 && id < len(proposals) {
			if len(parts) >= 2 && parts[1] == "votes" {
				return renderVotes(id)
			}
			return renderProposal(id)
		}
	}
	return "# Not Found"
}

func renderHome() string {
	out := "# " + name + "\n"
	out += description + "\n\n"
	out += "Threshold: " + strconv.Itoa(threshold) + "% | Quorum: " + strconv.Itoa(quorum) + "%\n\n"
	out += "## Members (" + strconv.Itoa(len(members)) + ")\n"
	for _, m := range members {
		out += "- " + string(m.Address) + " (roles: " + strings.Join(m.Roles, ", ") + ") | power: " + strconv.Itoa(m.Power) + "\n"
	}
	out += "\n## Proposals\n"
	for i := len(proposals) - 1; i >= 0; i-- {
		p := proposals[i]
		out += "### [Prop #" + strconv.Itoa(p.ID) + " - " + p.Title + "](:" + strconv.Itoa(p.ID) + ")\n"
		out += "Author: " + string(p.Author) + "\n\n"
		out += "Category: " + p.Category + "\n\n"
		out += "Status: " + p.Status + "\n\n---\n\n"
	}
	if len(proposals) == 0 {
		out += "No proposals yet.\n"
	}
	return out
}

func renderProposal(id int) string {
	p := proposals[id]
	out := "# Prop #" + strconv.Itoa(p.ID) + " - " + p.Title + "\n"
	out += p.Description + "\n\n"
	out += "Author: " + string(p.Author) + "\n\n"
	out += "Category: " + p.Category + "\n\n"
	out += "Status: " + p.Status + "\n\n"
	out += "YES: " + strconv.Itoa(p.YesVotes) + " | NO: " + strconv.Itoa(p.NoVotes) + " | ABSTAIN: " + strconv.Itoa(p.Abstain) + "\n"
	out += "Total Power: " + strconv.Itoa(p.TotalPower) + "/" + strconv.Itoa(totalPower()) + "\n"
	return out
}

func renderVotes(id int) string {
	p := proposals[id]
	out := "# Proposal #" + strconv.Itoa(p.ID) + " - Vote List\n\n"
	out += "YES:\n"
	for _, v := range p.Votes {
		if v.Value == "YES" {
			out += "- " + string(v.Voter) + "\n"
		}
	}
	out += "\nNO:\n"
	for _, v := range p.Votes {
		if v.Value == "NO" {
			out += "- " + string(v.Voter) + "\n"
		}
	}
	out += "\nABSTAIN:\n"
	for _, v := range p.Votes {
		if v.Value == "ABSTAIN" {
			out += "- " + string(v.Voter) + "\n"
		}
	}
	return out
}

// ── Actions ───────────────────────────────────────────────

func Propose(cur realm, title, desc, category string) int {
	caller := runtime.PreviousRealm().Address()
	assertNotArchived()
	assertMember(caller)
	assertCategory(category)
	id := nextID
	nextID++
	proposals = append(proposals, Proposal{
		ID:          id,
		Title:       title,
		Description: desc,
		Category:    category,
		Author:      caller,
		Status:      "ACTIVE",
		ActionType:  "none",
	})
	return id
}

func VoteOnProposal(cur realm, id int, vote string) {
	caller := runtime.PreviousRealm().Address()
	assertNotArchived()
	assertMember(caller)
	if id < 0 || id >= len(proposals) {
		panic("invalid proposal ID")
	}
	p := &proposals[id]
	if p.Status != "ACTIVE" {
		panic("proposal is not active")
	}
	// Check for duplicate votes
	for _, v := range p.Votes {
		if v.Voter == caller {
			panic("already voted")
		}
	}
	power := getMemberPower(caller)
	p.Votes = append(p.Votes, Vote{Voter: caller, Value: vote})
	switch vote {
	case "YES":
		p.YesVotes += power
	case "NO":
		p.NoVotes += power
	case "ABSTAIN":
		p.Abstain += power
	default:
		panic("invalid vote: must be YES, NO, or ABSTAIN")
	}
	p.TotalPower += power
	// Check quorum + threshold
	tpow := totalPower()
	if tpow > 0 {
		quorumMet := quorum == 0 || (p.TotalPower * 100 / tpow >= quorum)
		if quorumMet && p.YesVotes * 100 / tpow >= threshold {
			p.Status = "ACCEPTED"
		}
		if quorumMet && p.NoVotes * 100 / tpow > (100 - threshold) {
			p.Status = "REJECTED"
		}
	}
}

func ExecuteProposal(cur realm, id int) {
	caller := runtime.PreviousRealm().Address()
	assertMember(caller)
	if id < 0 || id >= len(proposals) {
		panic("invalid proposal ID")
	}
	p := &proposals[id]
	if p.Status != "ACCEPTED" {
		panic("proposal must be ACCEPTED to execute")
	}
	// Dispatch action
	switch p.ActionType {
	case "add_member":
		executeAddMember(p.ActionData)
	case "remove_member":
		executeRemoveMember(p.ActionData)
	case "assign_role":
		executeAssignRole(p.ActionData)
	case "none":
		// Text-only proposal — no action
	default:
		panic("unknown action type: " + p.ActionType)
	}
	p.Status = "EXECUTED"
}

// ── Member Proposals (governance-gated) ───────────────────

func ProposeAddMember(cur realm, targetAddr address, power int, roles string) int {
	caller := runtime.PreviousRealm().Address()
	assertNotArchived()
	assertMember(caller)
	// Validate target is not already a member
	for _, m := range members {
		if m.Address == targetAddr {
			panic("address is already a member")
		}
	}
	id := nextID
	nextID++
	title := "Add member " + string(targetAddr)[:10] + "... with power " + strconv.Itoa(power)
	desc := "**Action**: Add Member\n**Address**: " + string(targetAddr) + "\n**Power**: " + strconv.Itoa(power) + "\n**Roles**: " + roles
	data := string(targetAddr) + "|" + strconv.Itoa(power) + "|" + roles
	proposals = append(proposals, Proposal{
		ID:          id,
		Title:       title,
		Description: desc,
		Category:    "membership",
		Author:      caller,
		Status:      "ACTIVE",
		ActionType:  "add_member",
		ActionData:  data,
	})
	return id
}

func ProposeRemoveMember(cur realm, targetAddr address) int {
	caller := runtime.PreviousRealm().Address()
	assertNotArchived()
	assertMember(caller)
	assertMember(targetAddr) // target must be a member
	id := nextID
	nextID++
	title := "Remove member " + string(targetAddr)[:10] + "..."
	desc := "**Action**: Remove Member\n**Address**: " + string(targetAddr)
	proposals = append(proposals, Proposal{
		ID:          id,
		Title:       title,
		Description: desc,
		Category:    "membership",
		Author:      caller,
		Status:      "ACTIVE",
		ActionType:  "remove_member",
		ActionData:  string(targetAddr),
	})
	return id
}

func ProposeAssignRole(cur realm, targetAddr address, role string) int {
	caller := runtime.PreviousRealm().Address()
	assertNotArchived()
	assertMember(caller)
	assertMember(targetAddr) // target must be a member
	assertRole(role)
	id := nextID
	nextID++
	title := "Assign role " + strconv.Quote(role) + " to " + string(targetAddr)[:10] + "..."
	desc := "**Action**: Assign Role\n**Address**: " + string(targetAddr) + "\n**Role**: " + role
	proposals = append(proposals, Proposal{
		ID:          id,
		Title:       title,
		Description: desc,
		Category:    "membership",
		Author:      caller,
		Status:      "ACTIVE",
		ActionType:  "assign_role",
		ActionData:  string(targetAddr) + "|" + role,
	})
	return id
}

// ── Action Executors (internal) ───────────────────────────

func executeAddMember(data string) {
	parts := strings.Split(data, "|")
	if len(parts) != 3 {
		panic("invalid add_member action data")
	}
	addr := address(parts[0])
	power, err := strconv.Atoi(parts[1])
	if err != nil {
		panic("invalid power in action data")
	}
	roles := strings.Split(parts[2], ",")
	// Check not already a member
	for _, m := range members {
		if m.Address == addr {
			panic("address is already a member")
		}
	}
	members = append(members, Member{Address: addr, Power: power, Roles: roles})
}

func executeRemoveMember(data string) {
	addr := address(data)
	// Prevent removing last admin
	if hasRole(addr, "admin") {
		adminCount := 0
		for _, m := range members {
			if hasRoleInternal(m, "admin") {
				adminCount++
			}
		}
		if adminCount <= 1 {
			panic("cannot remove the last admin")
		}
	}
	newMembers := []Member{}
	found := false
	for _, m := range members {
		if m.Address == addr {
			found = true
			continue
		}
		newMembers = append(newMembers, m)
	}
	if !found {
		panic("member not found")
	}
	members = newMembers
}

func executeAssignRole(data string) {
	parts := strings.Split(data, "|")
	if len(parts) != 2 {
		panic("invalid assign_role action data")
	}
	addr := address(parts[0])
	role := parts[1]
	assertRole(role)
	for i, m := range members {
		if m.Address == addr {
			for _, r := range m.Roles {
				if r == role {
					panic("role already assigned")
				}
			}
			members[i].Roles = append(members[i].Roles, role)
			return
		}
	}
	panic("member not found")
}

// ── Role Management (admin-only) ──────────────────────────

func AssignRole(cur realm, target address, role string) {
	caller := runtime.PreviousRealm().Address()
	assertAdmin(caller)
	assertRole(role)
	for i, m := range members {
		if m.Address == target {
			// Check role not already assigned
			for _, r := range m.Roles {
				if r == role {
					panic("role already assigned")
				}
			}
			members[i].Roles = append(members[i].Roles, role)
			return
		}
	}
	panic("target is not a member")
}

func RemoveRole(cur realm, target address, role string) {
	caller := runtime.PreviousRealm().Address()
	assertAdmin(caller)
	// Prevent removing last admin
	if role == "admin" {
		adminCount := 0
		for _, m := range members {
			if hasRoleInternal(m, "admin") {
				adminCount++
			}
		}
		if adminCount <= 1 {
			panic("cannot remove the last admin")
		}
	}
	for i, m := range members {
		if m.Address == target {
			newRoles := []string{}
			for _, r := range m.Roles {
				if r != role {
					newRoles = append(newRoles, r)
				}
			}
			members[i].Roles = newRoles
			return
		}
	}
	panic("target is not a member")
}

// ── Archive Management ────────────────────────────────────

func Archive(cur realm) {
	caller := runtime.PreviousRealm().Address()
	assertAdmin(caller)
	archived = true
}

func IsArchived() bool {
	return archived
}

// ── Helpers ───────────────────────────────────────────────

func assertNotArchived() {
	if archived {
		panic("DAO is archived — no new proposals or votes")
	}
}

func assertMember(addr address) {
	for _, m := range members {
		if m.Address == addr {
			return
		}
	}
	panic("not a member")
}

func assertAdmin(addr address) {
	for _, m := range members {
		if m.Address == addr {
			for _, r := range m.Roles {
				if r == "admin" {
					return
				}
			}
		}
	}
	panic("admin role required")
}

func hasRole(addr address, role string) bool {
	for _, m := range members {
		if m.Address == addr {
			return hasRoleInternal(m, role)
		}
	}
	return false
}

func hasRoleInternal(m Member, role string) bool {
	for _, r := range m.Roles {
		if r == role {
			return true
		}
	}
	return false
}

func getMemberPower(addr address) int {
	for _, m := range members {
		if m.Address == addr {
			return m.Power
		}
	}
	return 0
}

func totalPower() int {
	total := 0
	for _, m := range members {
		total += m.Power
	}
	return total
}

func assertCategory(cat string) {
	for _, c := range allowedCategories {
		if c == cat {
			return
		}
	}
	panic("invalid proposal category: " + cat)
}

func assertRole(role string) {
	for _, r := range allowedRoles {
		if r == role {
			return
		}
	}
	panic("invalid role: " + role)
}

// ── Config (for Memba integration) ────────────────────────

func GetDAOConfig() string {
	return name
}
