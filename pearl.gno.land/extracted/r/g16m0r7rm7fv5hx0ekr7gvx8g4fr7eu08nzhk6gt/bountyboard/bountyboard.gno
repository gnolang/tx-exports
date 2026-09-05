package bountyboard

type BountyStatus int

const (
	BountyOpen BountyStatus = iota
	BountyClaimed
	BountySubmitted
	BountyApproved
	BountyRejected
	BountyPaid
	BountyCancelled
)

type Submission struct {
	Hunter    string
	Content   string
	Height    int64
}

type Bounty struct {
	ID            string
	Creator       string
	Title         string
	Reward        int64
	Status        BountyStatus
	Claimant      string
	Submissions   []Submission
	Reviewer      string
	CreatedHeight int64
	DeadlineHeight int64
}

type Board struct {
	admin         string
	bounties      map[string]*Bounty
	nextSeq       int64
	currentHeight int64
	escrowBalance int64
}

func NewBoard(admin string) *Board {
	return &Board{admin: admin, bounties: make(map[string]*Bounty)}
}

func (b *Board) Tick(height int64) {
	if height > b.currentHeight {
		b.currentHeight = height
	}
}

func (b *Board) CreateBounty(creator, title, reviewer string, reward, durationBlocks int64) (string, bool) {
	if creator == "" || title == "" || reward <= 0 || durationBlocks <= 0 {
		return "", false
	}
	b.nextSeq++
	id := itoa(b.nextSeq)
	b.escrowBalance += reward
	b.bounties[id] = &Bounty{
		ID:             id,
		Creator:        creator,
		Title:          title,
		Reward:         reward,
		Status:         BountyOpen,
		Reviewer:       reviewer,
		CreatedHeight:  b.currentHeight,
		DeadlineHeight: b.currentHeight + durationBlocks,
	}
	return id, true
}

func (b *Board) Claim(hunter, bountyID string) bool {
	bt, ok := b.bounties[bountyID]
	if !ok || bt.Status != BountyOpen {
		return false
	}
	if b.currentHeight >= bt.DeadlineHeight {
		return false
	}
	bt.Status = BountyClaimed
	bt.Claimant = hunter
	return true
}

func (b *Board) Submit(hunter, bountyID, content string) bool {
	bt, ok := b.bounties[bountyID]
	if !ok || bt.Status != BountyClaimed || bt.Claimant != hunter {
		return false
	}
	bt.Submissions = append(bt.Submissions, Submission{Hunter: hunter, Content: content, Height: b.currentHeight})
	bt.Status = BountySubmitted
	return true
}

func (b *Board) Review(reviewer, bountyID string, approve bool) bool {
	bt, ok := b.bounties[bountyID]
	if !ok || bt.Status != BountySubmitted {
		return false
	}
	if reviewer != bt.Reviewer && reviewer != bt.Creator && reviewer != b.admin {
		return false
	}
	if approve {
		bt.Status = BountyApproved
	} else {
		bt.Status = BountyRejected
		bt.Claimant = ""
	}
	return true
}

func (b *Board) Reopen(caller, bountyID string) bool {
	bt, ok := b.bounties[bountyID]
	if !ok || bt.Status != BountyRejected {
		return false
	}
	if caller != bt.Creator && caller != b.admin {
		return false
	}
	if b.currentHeight >= bt.DeadlineHeight {
		return false
	}
	bt.Status = BountyOpen
	return true
}

func (b *Board) Pay(bountyID string) (recipient string, amount int64, ok bool) {
	bt, exists := b.bounties[bountyID]
	if !exists || bt.Status != BountyApproved {
		return "", 0, false
	}
	bt.Status = BountyPaid
	b.escrowBalance -= bt.Reward
	return bt.Claimant, bt.Reward, true
}

func (b *Board) Cancel(caller, bountyID string) bool {
	bt, ok := b.bounties[bountyID]
	if !ok {
		return false
	}
	if caller != bt.Creator && caller != b.admin {
		return false
	}
	if bt.Status == BountyPaid {
		return false
	}
	b.escrowBalance -= bt.Reward
	bt.Status = BountyCancelled
	return true
}

func (b *Board) GetBounty(id string) (*Bounty, bool) {
	bt, ok := b.bounties[id]
	return bt, ok
}

func (b *Board) EscrowBalance() int64 {
	return b.escrowBalance
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

var board = NewBoard("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")

func Tick(height int64) {
	board.Tick(height)
}

func CreateBounty(creator, title, reviewer string, reward, durationBlocks int64) string {
	id, ok := board.CreateBounty(creator, title, reviewer, reward, durationBlocks)
	if !ok {
		return ""
	}
	return id
}

func Claim(hunter, bountyID string) bool {
	return board.Claim(hunter, bountyID)
}

func Submit(hunter, bountyID, content string) bool {
	return board.Submit(hunter, bountyID, content)
}

func Review(reviewer, bountyID string, approve bool) bool {
	return board.Review(reviewer, bountyID, approve)
}

func Reopen(caller, bountyID string) bool {
	return board.Reopen(caller, bountyID)
}

func Pay(bountyID string) string {
	recipient, amount, ok := board.Pay(bountyID)
	if !ok {
		return "not payable"
	}
	return recipient + ":" + itoa(amount)
}

func Cancel(caller, bountyID string) bool {
	return board.Cancel(caller, bountyID)
}

func EscrowBalance() int64 {
	return board.EscrowBalance()
}

func Render(path string) string {
	if path == "" {
		return "BountyBoard realm — escrow balance: " + itoa(board.EscrowBalance())
	}
	bt, ok := board.GetBounty(path)
	if !ok {
		return "bounty not found: " + path
	}
	return bt.Title + " | reward: " + itoa(bt.Reward)
}
