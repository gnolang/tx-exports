package foufou_dao_club

import (
	"chain/runtime"
	"strings"
	"strconv"
)

// ── Types ─────────────────────────────────────────────────

type Member struct {
	Address address
	Power   int
}

type Vote struct {
	Voter address
	Value string // "YES", "NO", "ABSTAIN"
}

type Proposal struct {
	ID          int
	Title       string
	Description string
	Author      address
	Status      string // "ACTIVE", "ACCEPTED", "REJECTED", "EXECUTED"
	Votes       []Vote
	YesVotes    int
	NoVotes     int
	Abstain     int
	TotalPower  int
}

// ── State ─────────────────────────────────────────────────

var (
	name        = "FOUFOU DAO CLUB"
	description = "FOUFOU DAO is a pure FOUFOU dictactorship."
	threshold   = 51 // percentage required to pass
	members     []Member
	proposals   []Proposal
	nextID      = 0
)

func init() {
	members = append(members, Member{Address: address("g187sfsghc9tqayr5rgdmpy2tetnq9ttluxuk79h"), Power: 1000})
	members = append(members, Member{Address: address("g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c"), Power: 337})
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
	out += "## Members (" + strconv.Itoa(len(members)) + ")\n"
	for _, m := range members {
		out += "- " + string(m.Address) + " (power: " + strconv.Itoa(m.Power) + ")\n"
	}
	out += "\n## Proposals\n"
	for i := len(proposals) - 1; i >= 0; i-- {
		p := proposals[i]
		out += "### [Prop #" + strconv.Itoa(p.ID) + " - " + p.Title + "](:" + strconv.Itoa(p.ID) + ")\n"
		out += "Author: " + string(p.Author) + "\n\n"
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
	out += "Status: " + p.Status + "\n\n"
	out += "YES: " + strconv.Itoa(p.YesVotes) + " — NO: " + strconv.Itoa(p.NoVotes) + " — ABSTAIN: " + strconv.Itoa(p.Abstain) + "\n"
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

func Propose(title, desc string) int {
	caller := runtime.OriginCaller()
	assertMember(caller)
	id := nextID
	nextID++
	proposals = append(proposals, Proposal{
		ID:          id,
		Title:       title,
		Description: desc,
		Author:      caller,
		Status:      "ACTIVE",
	})
	return id
}

func VoteOnProposal(id int, vote string) {
	caller := runtime.OriginCaller()
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
	// Check if threshold reached
	tpow := totalPower()
	if tpow > 0 && p.YesVotes * 100 / tpow >= threshold {
		p.Status = "ACCEPTED"
	}
	if tpow > 0 && p.NoVotes * 100 / tpow > (100 - threshold) {
		p.Status = "REJECTED"
	}
}

func ExecuteProposal(id int) {
	caller := runtime.OriginCaller()
	assertMember(caller)
	if id < 0 || id >= len(proposals) {
		panic("invalid proposal ID")
	}
	p := &proposals[id]
	if p.Status != "ACCEPTED" {
		panic("proposal must be ACCEPTED to execute")
	}
	p.Status = "EXECUTED"
}

// ── Helpers ───────────────────────────────────────────────

func assertMember(addr address) {
	for _, m := range members {
		if m.Address == addr {
			return
		}
	}
	panic("not a member")
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

// ── Config (for Memba integration) ────────────────────────

func GetDAOConfig() string {
	return name
}
