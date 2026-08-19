package govtreasury

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type ProposalStatus int

const (
	StatusVoting ProposalStatus = iota
	StatusApproved
	StatusRejected
	StatusExecuted
)

func (s ProposalStatus) String() string {
	switch s {
	case StatusVoting:
		return "voting"
	case StatusApproved:
		return "approved"
	case StatusRejected:
		return "rejected"
	case StatusExecuted:
		return "executed"
	default:
		return "unknown"
	}
}

type Proposal struct {
	ID          int64
	Proposer    address
	Recipient   address
	Amount      int64
	Description string
	Status      ProposalStatus
	YesVotes    int64
	NoVotes     int64
	VotersYes   *avl.Tree // addr -> bool
	VotersNo    *avl.Tree // addr -> bool
	CreatedAt   int64
	VotingEndsAt int64
}

const votingPeriodBlocks int64 = 100
const quorum int64 = 3 // minimum total votes required

var (
	admin      address
	members    *avl.Tree // addr -> bool, eligible voters
	proposals  *avl.Tree // id (string) -> *Proposal
	nextID     int64
)

func init() {
	admin = address("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")
	members = avl.NewTree()
	members.Set(string(admin), true)
	proposals = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("govtreasury: must be a direct user call")
	}
	return cur.Previous().Address()
}

func idKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

func AddMember(cur realm, addr address) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("govtreasury: admin only")
	}
	members.Set(string(addr), true)
}

// Deposit adds funds to the treasury (anyone can fund it).
func Deposit(cur realm) {
	assertUserCall(cur)
	sent := unsafe.OriginSend()
	if sent.AmountOf("ugnot") <= 0 {
		panic("govtreasury: must send ugnot")
	}
	// funds are automatically held by the realm's own coin balance
}

func Propose(cur realm, recipient address, amount int64, description string) int64 {
	caller := assertUserCall(cur)
	if !members.Has(string(caller)) {
		panic("govtreasury: only members can propose")
	}
	if amount <= 0 {
		panic("govtreasury: amount must be positive")
	}

	id := nextID
	nextID++
	now := runtime.ChainHeight()

	proposals.Set(idKey(id), &Proposal{
		ID:           id,
		Proposer:     caller,
		Recipient:    recipient,
		Amount:       amount,
		Description:  description,
		Status:       StatusVoting,
		VotersYes:    avl.NewTree(),
		VotersNo:     avl.NewTree(),
		CreatedAt:    now,
		VotingEndsAt: now + votingPeriodBlocks,
	})
	return id
}

func getProposal(id int64) *Proposal {
	key := idKey(id)
	if !proposals.Has(key) {
		panic("govtreasury: proposal not found")
	}
	raw := proposals.Get(key)
	return raw.(*Proposal)
}

func Vote(cur realm, id int64, approve bool) {
	caller := assertUserCall(cur)
	if !members.Has(string(caller)) {
		panic("govtreasury: only members can vote")
	}
	p := getProposal(id)
	if p.Status != StatusVoting {
		panic("govtreasury: proposal is not open for voting")
	}
	if runtime.ChainHeight() > p.VotingEndsAt {
		panic("govtreasury: voting period has ended")
	}
	if p.VotersYes.Has(string(caller)) || p.VotersNo.Has(string(caller)) {
		panic("govtreasury: already voted")
	}

	if approve {
		p.VotersYes.Set(string(caller), true)
		p.YesVotes++
	} else {
		p.VotersNo.Set(string(caller), true)
		p.NoVotes++
	}
}

// Finalize closes voting after the period ends and marks the outcome.
func Finalize(cur realm, id int64) {
	assertUserCall(cur)
	p := getProposal(id)
	if p.Status != StatusVoting {
		panic("govtreasury: proposal already finalized")
	}
	if runtime.ChainHeight() <= p.VotingEndsAt {
		panic("govtreasury: voting period has not ended yet")
	}

	total := p.YesVotes + p.NoVotes
	if total < quorum {
		p.Status = StatusRejected
		return
	}
	if p.YesVotes > p.NoVotes {
		p.Status = StatusApproved
	} else {
		p.Status = StatusRejected
	}
}

// Execute pays out an approved proposal.
func Execute(cur realm, id int64) {
	assertUserCall(cur)
	p := getProposal(id)
	if p.Status != StatusApproved {
		panic("govtreasury: proposal is not approved")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := bk.GetCoins(realmAddr).AmountOf("ugnot")
	if have < p.Amount {
		panic("govtreasury: insufficient treasury balance")
	}
	bk.SendCoins(realmAddr, p.Recipient, chain.Coins{chain.NewCoin("ugnot", p.Amount)})

	p.Status = StatusExecuted
}

func Render(path string) string {
	out := "# Governance Treasury\n\n"
	out += ufmt.Sprintf("Members: %d | Proposals: %d\n\n", members.Size(), proposals.Size())
	proposals.Iterate("", "", func(key string, value interface{}) bool {
		p := value.(*Proposal)
		out += ufmt.Sprintf("## #%d: %s\n", p.ID, p.Description)
		out += ufmt.Sprintf("Status: %s | Amount: %d ugnot | Yes: %d No: %d\n\n",
			p.Status.String(), p.Amount, p.YesVotes, p.NoVotes)
		return false
	})
	return out
}
