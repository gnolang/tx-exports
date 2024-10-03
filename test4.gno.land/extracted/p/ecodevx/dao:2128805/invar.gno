package dao

// TODO: Remove this file if Gno implements invar (inmutable) references

import (
	"std"
	"time"
)

func NewInvarProposalStrategy(s ProposalStrategy) InvarProposalStrategy {
	return InvarProposalStrategy{s}
}

type InvarProposalStrategy struct {
	ref ProposalStrategy
}

func (s InvarProposalStrategy) Name() string {
	return s.ref.Name()
}

func (s InvarProposalStrategy) Quorum() float64 {
	return s.ref.Quorum()
}

func (s InvarProposalStrategy) VotingPeriod() time.Duration {
	return s.ref.VotingPeriod()
}

func (s InvarProposalStrategy) VoteChoices() []VoteChoice {
	return s.ref.VoteChoices()
}

func (s InvarProposalStrategy) RenderParams() string {
	if r, ok := s.ref.(ParamsRenderer); ok {
		return r.RenderParams()
	}
	return ""
}

func NewInvarVote(v Vote) InvarVote {
	return InvarVote{
		Address:   v.Address,
		Choice:    v.Choice,
		Reason:    v.Reason,
		DAO:       NewInvarDAO(v.DAO),
		CreatedAt: v.CreatedAt,
	}
}

type InvarVote struct {
	Address   std.Address
	Choice    VoteChoice
	Reason    string
	DAO       InvarDAO
	CreatedAt time.Time
}

func NewInvarDAO(dao *DAO) InvarDAO {
	return InvarDAO{dao}
}

type InvarDAO struct {
	ref *DAO
}

func (dao InvarDAO) Name() string {
	return dao.ref.Name()
}

func (dao InvarDAO) Title() string {
	return dao.ref.Title()
}

func (dao InvarDAO) Manifest() string {
	return dao.ref.Manifest()
}

func (dao InvarDAO) CreatedAt() time.Time {
	return dao.ref.CreatedAt()
}

func (dao InvarDAO) Parent() (_ InvarDAO, exists bool) {
	if p := dao.ref.Parent(); p != nil {
		return NewInvarDAO(p), true
	}
	return InvarDAO{}, false
}

func (dao InvarDAO) Path() string {
	return dao.ref.Path()
}

func (dao InvarDAO) SubDAOs() (daos []InvarDAO) {
	for _, sub := range dao.ref.SubDAOs() {
		daos = append(daos, NewInvarDAO(sub))
	}
	return
}

func (dao InvarDAO) Members() []Member {
	return dao.ref.Members()
}

func (dao InvarDAO) LockReason() string {
	return dao.ref.LockReason()
}

func (dao InvarDAO) IsSuperCouncil() bool {
	return dao.ref.IsSuperCouncil()
}

func (dao InvarDAO) IsLocked() bool {
	return dao.ref.IsLocked()
}

func (dao InvarDAO) IsRoot() bool {
	return dao.ref.IsRoot()
}

func NewInvarProposal(p *Proposal) InvarProposal {
	return InvarProposal{p}
}

type InvarProposal struct {
	ref *Proposal
}

func (p InvarProposal) ID() ID {
	return p.ref.ID()
}

func (p InvarProposal) DAO() InvarDAO {
	return NewInvarDAO(p.ref.DAO())
}

func (p InvarProposal) InitialDAO() InvarDAO {
	return NewInvarDAO(p.ref.InitialDAO())
}

func (p InvarProposal) Strategy() InvarProposalStrategy {
	return NewInvarProposalStrategy(p.ref.Strategy())
}

func (p InvarProposal) Title() string {
	return p.ref.Title()
}

func (p InvarProposal) Description() string {
	return p.ref.Description()
}

func (p InvarProposal) StatusReason() string {
	return p.ref.StatusReason()
}

func (p InvarProposal) Proposer() std.Address {
	return p.ref.Proposer()
}

func (p InvarProposal) Choice() VoteChoice {
	return p.ref.Choice()
}

func (p InvarProposal) CreatedAt() time.Time {
	return p.ref.CreatedAt()
}

func (p InvarProposal) Promotions() (daos []InvarDAO) {
	for _, dao := range p.ref.Promotions() {
		daos = append(daos, NewInvarDAO(dao))
	}
	return
}

func (p InvarProposal) VotingDeadline() time.Time {
	return p.ref.VotingDeadline()
}

func (p InvarProposal) ReviewDeadline() time.Time {
	return p.ref.ReviewDeadline()
}

func (p InvarProposal) VoteChangeDuration() time.Duration {
	return p.ref.VoteChangeDuration()
}

func (p InvarProposal) Status() ProposalStatus {
	return p.ref.Status()
}

func (p InvarProposal) Votes() (votes []InvarVote) {
	for _, v := range p.ref.Votes() {
		votes = append(votes, NewInvarVote(v))
	}
	return
}

func (p InvarProposal) VotingRecord() InvarVotingRecord {
	return NewInvarVotingRecord(p.ref.VotingRecord())
}

func (p InvarProposal) VotingRecords() (records []InvarVotingRecord) {
	for _, r := range p.ref.VotingRecords() {
		records = append(records, NewInvarVotingRecord(r))
	}
	return
}

func NewInvarVotingRecord(r *VotingRecord) InvarVotingRecord {
	return InvarVotingRecord{r}
}

type InvarVotingRecord struct {
	ref *VotingRecord
}

func (r InvarVotingRecord) Votes() (votes []InvarVote) {
	for _, v := range r.ref.Votes() {
		votes = append(votes, NewInvarVote(v))
	}
	return
}

func (r InvarVotingRecord) VoteCount() int {
	return r.ref.VoteCount()
}

func (r InvarVotingRecord) Get(c VoteChoice) uint {
	return r.ref.Get(c)
}

func (r InvarVotingRecord) Iterate(fn VotingRecordIterFn) bool {
	return r.ref.Iterate(fn)
}
