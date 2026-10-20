package govtreasury

type PropStatus int

const (
	StatusVoting PropStatus = iota
	StatusApproved
	StatusRejected
	StatusExecuted
	StatusCancelled
)

type Proposal struct {
	ID              string
	Proposer        string
	Description     string
	Recipient       string
	Amount          int64
	VotesFor        int64
	VotesAgainst    int64
	CreatedHeight   int64
	VotingEndHeight int64
	ExecuteAfter    int64
	Status          PropStatus
	voted           map[string]bool
}

type Treasury struct {
	admin         string
	balance       int64
	votingPower   map[string]int64
	proposals     map[string]*Proposal
	nextSeq       int64
	currentHeight int64
	votingPeriod  int64
	timelockDelay int64
	quorum        int64 // minimum total votes (for+against) required
}

func NewTreasury(admin string, votingPeriod, timelockDelay, quorum int64) *Treasury {
	return &Treasury{
		admin:         admin,
		votingPower:   make(map[string]int64),
		proposals:     make(map[string]*Proposal),
		votingPeriod:  votingPeriod,
		timelockDelay: timelockDelay,
		quorum:        quorum,
	}
}

func (t *Treasury) Tick(height int64) {
	if height > t.currentHeight {
		t.currentHeight = height
	}
}

func (t *Treasury) Deposit(amount int64) bool {
	if amount <= 0 {
		return false
	}
	t.balance += amount
	return true
}

func (t *Treasury) SetVotingPower(caller, addr string, power int64) bool {
	if caller != t.admin || power < 0 {
		return false
	}
	t.votingPower[addr] = power
	return true
}

func (t *Treasury) Propose(proposer, description, recipient string, amount int64) (string, bool) {
	if amount <= 0 || recipient == "" || t.votingPower[proposer] == 0 {
		return "", false
	}
	t.nextSeq++
	id := itoa(t.nextSeq)
	t.proposals[id] = &Proposal{
		ID:              id,
		Proposer:        proposer,
		Description:     description,
		Recipient:       recipient,
		Amount:          amount,
		CreatedHeight:   t.currentHeight,
		VotingEndHeight: t.currentHeight + t.votingPeriod,
		Status:          StatusVoting,
		voted:           make(map[string]bool),
	}
	return id, true
}

func (t *Treasury) Vote(voter, proposalID string, support bool) bool {
	p, ok := t.proposals[proposalID]
	if !ok || p.Status != StatusVoting {
		return false
	}
	if t.currentHeight >= p.VotingEndHeight {
		return false
	}
	power := t.votingPower[voter]
	if power == 0 || p.voted[voter] {
		return false
	}
	p.voted[voter] = true
	if support {
		p.VotesFor += power
	} else {
		p.VotesAgainst += power
	}
	return true
}

// Finalize closes voting once the period has ended, checking quorum + simple majority.
func (t *Treasury) Finalize(proposalID string) bool {
	p, ok := t.proposals[proposalID]
	if !ok || p.Status != StatusVoting {
		return false
	}
	if t.currentHeight < p.VotingEndHeight {
		return false
	}
	total := p.VotesFor + p.VotesAgainst
	if total < t.quorum || p.VotesFor <= p.VotesAgainst {
		p.Status = StatusRejected
		return true
	}
	p.Status = StatusApproved
	p.ExecuteAfter = t.currentHeight + t.timelockDelay
	return true
}

func (t *Treasury) Execute(proposalID string) bool {
	p, ok := t.proposals[proposalID]
	if !ok || p.Status != StatusApproved {
		return false
	}
	if t.currentHeight < p.ExecuteAfter {
		return false
	}
	if p.Amount > t.balance {
		return false
	}
	t.balance -= p.Amount
	p.Status = StatusExecuted
	return true
}

func (t *Treasury) Cancel(caller, proposalID string) bool {
	p, ok := t.proposals[proposalID]
	if !ok {
		return false
	}
	if caller != t.admin && caller != p.Proposer {
		return false
	}
	if p.Status == StatusExecuted {
		return false
	}
	p.Status = StatusCancelled
	return true
}

func (t *Treasury) GetProposal(id string) (*Proposal, bool) {
	p, ok := t.proposals[id]
	return p, ok
}

func (t *Treasury) Balance() int64 {
	return t.balance
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	s := string(buf[i:])
	if neg {
		s = "-" + s
	}
	return s
}

// package-level singleton + exported entry points for the realm

var treasury = NewTreasury("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt", 100, 50, 10)

func Tick(height int64) {
	treasury.Tick(height)
}

func Deposit(amount int64) bool {
	return treasury.Deposit(amount)
}

func SetVotingPower(caller, addr string, power int64) bool {
	return treasury.SetVotingPower(caller, addr, power)
}

func Propose(proposer, description, recipient string, amount int64) string {
	id, ok := treasury.Propose(proposer, description, recipient, amount)
	if !ok {
		return ""
	}
	return id
}

func Vote(voter, proposalID string, support bool) bool {
	return treasury.Vote(voter, proposalID, support)
}

func Finalize(proposalID string) bool {
	return treasury.Finalize(proposalID)
}

func Execute(proposalID string) bool {
	return treasury.Execute(proposalID)
}

func Cancel(caller, proposalID string) bool {
	return treasury.Cancel(caller, proposalID)
}

func Balance() int64 {
	return treasury.Balance()
}

func Render(path string) string {
	if path == "" {
		return "GovTreasury realm — balance: " + itoa(treasury.Balance())
	}
	p, ok := treasury.GetProposal(path)
	if !ok {
		return "proposal not found: " + path
	}
	return p.Description + " | for:" + itoa(p.VotesFor) + " against:" + itoa(p.VotesAgainst)
}
