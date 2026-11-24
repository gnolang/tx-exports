package board

import (
	"strconv"
	"strings"
	"time"
)

const maxProposals = 50

type proposal struct {
	title string
	deadline time.Time
	votes map[address]bool
	yes int
	no int
}

var members = make(map[address]bool)
var proposals []*proposal

// AddMember admits a voter. On a shared network the namespace must be the
// administrator's address-based namespace.
func AddMember(cur realm, member address) {
	caller := callerAddress(cur)
	namespace := strings.Split(cur.PkgPath(), "/")[2]
	if string(caller) != namespace {
		panic("only the namespace owner can add members")
	}
	members[member] = true
}

// Propose opens a yes/no poll for the specified number of minutes.
func Propose(cur realm, title string, minutes int) int {
	requireMember(cur)
	title = strings.TrimSpace(title)
	if len(title) == 0 || len(title) > 100 || strings.ContainsAny(title, "\r\n\x60") {
		panic("use a single-line title of 1–100 bytes without backticks")
	}
	if minutes < 1 || minutes > 10080 {
		panic("duration must be between 1 and 10080 minutes")
	}
	if len(proposals) >= maxProposals {
		panic("this board has reached its 50-proposal limit")
	}
	proposals = append(proposals, &proposal{
		title: title,
		deadline: time.Now().Add(time.Duration(minutes) * time.Minute),
		votes: make(map[address]bool),
	})
	return len(proposals)
}

// Vote accepts one vote from each member until the proposal's deadline.
func Vote(cur realm, id int, approve bool) {
	voter := requireMember(cur)
	if id < 1 || id > len(proposals) {
		panic("proposal not found")
	}
	proposals[id-1].cast(voter, approve, time.Now())
}

func (p *proposal) cast(voter address, approve bool, now time.Time) {
	if !now.Before(p.deadline) {
		panic("voting is closed")
	}
	if p.votes[voter] {
		panic("address has already voted")
	}
	p.votes[voter] = true
	if approve {
		p.yes++
	} else {
		p.no++
	}
}

func requireMember(cur realm) address {
	caller := callerAddress(cur)
	if !members[caller] {
		panic("address is not a board member")
	}
	return caller
}

func callerAddress(cur realm) address {
	if !cur.IsCurrent() {
		panic("invalid realm context")
	}
	return cur.Previous().Address()
}

func Render(_ string) string {
	out := "# Commons Board\n\nPublic proposals and votes for a community. Use **Actions** to create a proposal or vote with a member wallet.\n\n"
	if len(proposals) == 0 {
		return out + "No proposals yet."
	}
	now := time.Now()
	for i := len(proposals) - 1; i >= 0; i-- {
		p := proposals[i]
		status := "Open"
		if !now.Before(p.deadline) {
			switch {
			case p.yes+p.no == 0:
				status = "Closed · No votes"
			case p.yes > p.no:
				status = "Closed · Passed"
			case p.yes < p.no:
				status = "Closed · Rejected"
			default:
				status = "Closed · Tied"
			}
		}
		out += "## Proposal " + strconv.Itoa(i+1) + "\n\n"
		out += "`" + p.title + "`\n\n"
		out += "**" + status + "** · Yes " + strconv.Itoa(p.yes) + " · No " + strconv.Itoa(p.no) + "\n\n"
		out += "Deadline (UTC) · " + p.deadline.UTC().Format("2006-01-02 15:04:05") + "\n\n"
	}
	return out
}
