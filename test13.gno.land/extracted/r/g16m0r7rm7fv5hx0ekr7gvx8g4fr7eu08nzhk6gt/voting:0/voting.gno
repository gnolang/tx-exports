package voting

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/addrset"

	"chain/runtime/unsafe"
)

type Proposal struct {
	id          int
	description string
	yesVotes    int
	noVotes     int
	closed      bool
	voters      *addrset.Set
}

var (
	proposals avl.Tree
	nextID    int
	admin     address
)

func init() {
	admin = unsafe.OriginCaller()
	nextID = 1
}

func CreateProposal(cur realm, description string) int {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("only admin can create proposals")
	}
	id := nextID
	p := &Proposal{
		id:          id,
		description: description,
		voters:      addrset.New(),
	}
	proposals.Set(strconv.Itoa(id), p)
	nextID++
	return id
}

func Vote(cur realm, proposalID int, voteYes bool) {
	caller := cur.Previous().Address()
	raw, exists := proposals.Get(strconv.Itoa(proposalID))
	if !exists {
		panic("proposal does not exist")
	}
	p := raw.(*Proposal)
	if p.closed {
		panic("proposal is closed")
	}
	if p.voters.Has(caller.String()) {
		panic("already voted")
	}
	p.voters.Add(caller.String())
	if voteYes {
		p.yesVotes++
	} else {
		p.noVotes++
	}
}

func CloseProposal(cur realm, proposalID int) {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("only admin can close proposals")
	}
	raw, exists := proposals.Get(strconv.Itoa(proposalID))
	if !exists {
		panic("proposal does not exist")
	}
	p := raw.(*Proposal)
	p.closed = true
}

func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("Voting Realm\nAdmin: " + admin.String() + "\n\n")
	proposals.Iterate("", "", func(key string, value interface{}) bool {
		p := value.(*Proposal)
		status := "open"
		if p.closed {
			status = "closed"
		}
		sb.WriteString("Proposal #" + strconv.Itoa(p.id) + ": " + p.description +
			" | Yes: " + strconv.Itoa(p.yesVotes) +
			" No: " + strconv.Itoa(p.noVotes) +
			" [" + status + "]\n")
		return false
	})
	return sb.String()
}
