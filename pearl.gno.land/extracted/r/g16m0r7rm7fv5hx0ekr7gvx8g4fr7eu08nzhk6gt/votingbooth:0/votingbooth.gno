package votingbooth

type PollStatus int

const (
	PollOpen PollStatus = iota
	PollClosed
)

type Poll struct {
	ID          string
	Creator     string
	Question    string
	Options     []string
	Tally       []int64
	EndHeight   int64
	Status      PollStatus
	OneVoteOnly bool
	voted       map[string]int // voter -> option index (for revote tracking)
	hasVoted    map[string]bool
}

type Booth struct {
	admin         string
	polls         map[string]*Poll
	nextSeq       int64
	currentHeight int64
}

func NewBooth(admin string) *Booth {
	return &Booth{admin: admin, polls: make(map[string]*Poll)}
}

func (b *Booth) Tick(height int64) {
	if height > b.currentHeight {
		b.currentHeight = height
	}
}

func (b *Booth) CreatePoll(creator, question string, options []string, durationBlocks int64, oneVoteOnly bool) (string, bool) {
	if creator == "" || question == "" || len(options) < 2 || durationBlocks <= 0 {
		return "", false
	}
	b.nextSeq++
	id := itoa(b.nextSeq)
	b.polls[id] = &Poll{
		ID:          id,
		Creator:     creator,
		Question:    question,
		Options:     options,
		Tally:       make([]int64, len(options)),
		EndHeight:   b.currentHeight + durationBlocks,
		Status:      PollOpen,
		OneVoteOnly: oneVoteOnly,
		voted:       make(map[string]int),
		hasVoted:    make(map[string]bool),
	}
	return id, true
}

func (b *Booth) Vote(voter, pollID string, optionIdx int) bool {
	p, ok := b.polls[pollID]
	if !ok || p.Status != PollOpen {
		return false
	}
	if b.currentHeight >= p.EndHeight {
		p.Status = PollClosed
		return false
	}
	if optionIdx < 0 || optionIdx >= len(p.Options) {
		return false
	}
	if p.hasVoted[voter] {
		if p.OneVoteOnly {
			return false
		}
		// allow revote: undo previous choice
		prev := p.voted[voter]
		p.Tally[prev]--
	}
	p.Tally[optionIdx]++
	p.voted[voter] = optionIdx
	p.hasVoted[voter] = true
	return true
}

func (b *Booth) ClosePoll(caller, pollID string) bool {
	p, ok := b.polls[pollID]
	if !ok || p.Status != PollOpen {
		return false
	}
	if caller != p.Creator && caller != b.admin {
		return false
	}
	p.Status = PollClosed
	return true
}

func (b *Booth) Winner(pollID string) (string, bool) {
	p, ok := b.polls[pollID]
	if !ok || p.Status != PollClosed {
		return "", false
	}
	if len(p.Tally) == 0 {
		return "", false
	}
	best := 0
	tie := false
	for i := 1; i < len(p.Tally); i++ {
		if p.Tally[i] > p.Tally[best] {
			best = i
			tie = false
		} else if p.Tally[i] == p.Tally[best] {
			tie = true
		}
	}
	if tie {
		return "", false
	}
	return p.Options[best], true
}

func (b *Booth) GetPoll(id string) (*Poll, bool) {
	p, ok := b.polls[id]
	return p, ok
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

var booth = NewBooth("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")

func Tick(height int64) {
	booth.Tick(height)
}

func CreatePoll(creator, question string, options []string, durationBlocks int64, oneVoteOnly bool) string {
	id, ok := booth.CreatePoll(creator, question, options, durationBlocks, oneVoteOnly)
	if !ok {
		return ""
	}
	return id
}

func Vote(voter, pollID string, optionIdx int) bool {
	return booth.Vote(voter, pollID, optionIdx)
}

func ClosePoll(caller, pollID string) bool {
	return booth.ClosePoll(caller, pollID)
}

func Winner(pollID string) string {
	w, ok := booth.Winner(pollID)
	if !ok {
		return "no winner"
	}
	return w
}

func Render(path string) string {
	if path == "" {
		return "VotingBooth realm — use CreatePoll, Vote, ClosePoll, Winner"
	}
	p, ok := booth.GetPoll(path)
	if !ok {
		return "poll not found: " + path
	}
	return p.Question
}
