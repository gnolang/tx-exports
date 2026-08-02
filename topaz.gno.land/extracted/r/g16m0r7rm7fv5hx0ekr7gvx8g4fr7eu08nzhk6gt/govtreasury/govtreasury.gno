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
	StatusPending ProposalStatus = iota
	StatusExecuted
	StatusRejected
	StatusExpired
)

func (s ProposalStatus) String() string {
	switch s {
	case StatusPending:
		return "Pending"
	case StatusExecuted:
		return "Executed"
	case StatusRejected:
		return "Rejected"
	case StatusExpired:
		return "Expired"
	default:
		return "Unknown"
	}
}

type Proposal struct {
	ID                   int64
	Proposer             address
	Recipient            address
	Amount               int64
	Description          string
	CreatedAtBlock       int64
	VotingDeadlineHeight int64
	Status               ProposalStatus
	SnapshotMemberCount  int64
	YesVotes             *avl.Tree
	NoVotes              *avl.Tree
}

var (
	admin          address
	adminSet       bool
	members        avl.Tree
	memberCount    int64
	proposals      avl.Tree
	nextProposalID int64
)

func Bootstrap(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("govtreasury: only direct user calls can bootstrap")
	}
	if adminSet {
		panic("govtreasury: already bootstrapped")
	}

	caller := cur.Previous().Address()
	admin = caller
	adminSet = true
	members.Set(caller.String(), true)
	memberCount = 1
}

func AddMember(cur realm, member address) {
	requireAdmin(cur)
	if members.Get(member.String()) != nil {
		panic("govtreasury: address is already a member")
	}
	members.Set(member.String(), true)
	memberCount++
}

func RemoveMember(cur realm, member address) {
	requireAdmin(cur)
	if member == admin {
		panic("govtreasury: admin cannot remove themselves")
	}
	if members.Get(member.String()) == nil {
		panic("govtreasury: address is not a member")
	}
	members.Remove(member.String())
	memberCount--
}

func Fund(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("govtreasury: only direct user calls can fund the treasury")
	}
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("govtreasury: funding amount must be positive")
	}
}

func CreateProposal(cur realm, recipient address, amount int64, description string, votingBlocks int64) int64 {
	requireMember(cur)
	if amount <= 0 {
		panic("govtreasury: proposal amount must be positive")
	}
	if votingBlocks <= 0 {
		panic("govtreasury: votingBlocks must be positive")
	}
	if description == "" {
		panic("govtreasury: description cannot be empty")
	}

	caller := cur.Previous().Address()
	nowHeight := runtime.ChainHeight()

	nextProposalID++
	id := nextProposalID

	p := &Proposal{
		ID:                   id,
		Proposer:             caller,
		Recipient:            recipient,
		Amount:               amount,
		Description:          description,
		CreatedAtBlock:       nowHeight,
		VotingDeadlineHeight: nowHeight + votingBlocks,
		Status:               StatusPending,
		SnapshotMemberCount:  memberCount,
		YesVotes:             avl.NewTree(),
		NoVotes:              avl.NewTree(),
	}

	proposals.Set(itoa(id), p)
	return id
}

func Vote(cur realm, proposalID int64, approve bool) {
	requireMember(cur)

	p := mustGetProposal(proposalID)
	caller := cur.Previous().Address()

	if p.Status != StatusPending {
		panic("govtreasury: proposal is not pending (status=" + p.Status.String() + ")")
	}
	if runtime.ChainHeight() >= p.VotingDeadlineHeight {
		panic("govtreasury: voting period has ended")
	}
	if p.YesVotes.Get(caller.String()) != nil || p.NoVotes.Get(caller.String()) != nil {
		panic("govtreasury: caller has already voted on this proposal")
	}

	if approve {
		p.YesVotes.Set(caller.String(), true)
	} else {
		p.NoVotes.Set(caller.String(), true)
	}

	yesCount := int64(p.YesVotes.Size())
	noCount := int64(p.NoVotes.Size())

	if yesCount*2 > p.SnapshotMemberCount {
		executeProposal(cur, p)
		return
	}
	if noCount*2 > p.SnapshotMemberCount {
		p.Status = StatusRejected
	}
}

func ExpireProposal(cur realm, proposalID int64) {
	p := mustGetProposal(proposalID)

	if p.Status != StatusPending {
		panic("govtreasury: proposal is not pending (status=" + p.Status.String() + ")")
	}
	if runtime.ChainHeight() < p.VotingDeadlineHeight {
		panic("govtreasury: voting period has not ended yet")
	}

	p.Status = StatusExpired
}

func executeProposal(cur realm, p *Proposal) {
	p.Status = StatusExecuted

	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	have := b.GetCoins(realmAddr).AmountOf("ugnot")
	if have < p.Amount {
		panic("govtreasury: insufficient treasury balance to execute this proposal")
	}

	b.SendCoins(realmAddr, p.Recipient, chain.Coins{chain.NewCoin("ugnot", p.Amount)})
}

func requireAdmin(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("govtreasury: only direct user calls are accepted")
	}
	if !adminSet {
		panic("govtreasury: treasury has not been bootstrapped yet")
	}
	if cur.Previous().Address() != admin {
		panic("govtreasury: caller is not the admin")
	}
}

func requireMember(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("govtreasury: only direct user calls are accepted")
	}
	if !adminSet {
		panic("govtreasury: treasury has not been bootstrapped yet")
	}
	if members.Get(cur.Previous().Address().String()) == nil {
		panic("govtreasury: caller is not a member")
	}
}

func mustGetProposal(proposalID int64) *Proposal {
	raw := proposals.Get(itoa(proposalID))
	if raw == nil {
		panic("govtreasury: proposal not found")
	}
	p, ok := raw.(*Proposal)
	if !ok {
		panic("govtreasury: internal error, corrupted proposal entry")
	}
	return p
}

func itoa(i int64) string {
	return ufmt.Sprintf("%d", i)
}

func IsMember(addr address) bool {
	return members.Get(addr.String()) != nil
}

func GetAdmin() address {
	return admin
}

func GetMemberCount() int64 {
	return memberCount
}

func GetProposalStatus(proposalID int64) string {
	return mustGetProposal(proposalID).Status.String()
}

func GetProposalAmount(proposalID int64) int64 {
	return mustGetProposal(proposalID).Amount
}

func GetProposalRecipient(proposalID int64) address {
	return mustGetProposal(proposalID).Recipient
}

func GetProposalYesVotes(proposalID int64) int64 {
	return int64(mustGetProposal(proposalID).YesVotes.Size())
}

func GetProposalNoVotes(proposalID int64) int64 {
	return int64(mustGetProposal(proposalID).NoVotes.Size())
}

func GetProposalSnapshotMemberCount(proposalID int64) int64 {
	return mustGetProposal(proposalID).SnapshotMemberCount
}
