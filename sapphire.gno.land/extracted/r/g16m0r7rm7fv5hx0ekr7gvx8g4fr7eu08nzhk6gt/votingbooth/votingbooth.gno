package votingbooth

import (
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Poll is a simple single-choice, multi-option poll. One vote per address.
type Poll struct {
	ID        int64
	Creator   address
	Question  string
	Options   []string
	VoteCount []int64
	Voters    *avl.Tree // addr -> int64 (option index chosen)
	ClosesAt  int64
	Closed    bool
}

var (
	polls  *avl.Tree // id (string) -> *Poll
	nextID int64
)

func init() {
	polls = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("votingbooth: must be a direct user call")
	}
	return cur.Previous().Address()
}

func idKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

func getPoll(id int64) *Poll {
	key := idKey(id)
	if !polls.Has(key) {
		panic("votingbooth: poll not found")
	}
	raw := polls.Get(key)
	return raw.(*Poll)
}

// CreatePoll opens a new poll with the given options, open for durationBlocks.
func CreatePoll(cur realm, question string, opt0 string, opt1 string, opt2 string, opt3 string, durationBlocks int64) int64 {
	caller := assertUserCall(cur)
	if question == "" {
		panic("votingbooth: question required")
	}
	if durationBlocks <= 0 {
		panic("votingbooth: durationBlocks must be positive")
	}

	options := []string{}
	for _, o := range []string{opt0, opt1, opt2, opt3} {
		if o != "" {
			options = append(options, o)
		}
	}
	if len(options) < 2 {
		panic("votingbooth: at least 2 non-empty options required")
	}

	id := nextID
	nextID++

	polls.Set(idKey(id), &Poll{
		ID:        id,
		Creator:   caller,
		Question:  question,
		Options:   options,
		VoteCount: make([]int64, len(options)),
		Voters:    avl.NewTree(),
		ClosesAt:  runtime.ChainHeight() + durationBlocks,
		Closed:    false,
	})
	return id
}

// Vote casts a single vote for optionIdx. One vote per address, no changing.
func Vote(cur realm, id int64, optionIdx int64) {
	caller := assertUserCall(cur)
	p := getPoll(id)
	if p.Closed {
		panic("votingbooth: poll is closed")
	}
	if runtime.ChainHeight() > p.ClosesAt {
		panic("votingbooth: voting period has ended, call ClosePoll")
	}
	if optionIdx < 0 || int(optionIdx) >= len(p.Options) {
		panic("votingbooth: invalid option index")
	}
	if p.Voters.Has(string(caller)) {
		panic("votingbooth: already voted")
	}

	p.Voters.Set(string(caller), optionIdx)
	p.VoteCount[optionIdx]++
}

// ClosePoll marks a poll as closed once its duration has elapsed.
func ClosePoll(cur realm, id int64) {
	assertUserCall(cur)
	p := getPoll(id)
	if p.Closed {
		panic("votingbooth: poll already closed")
	}
	if runtime.ChainHeight() <= p.ClosesAt {
		panic("votingbooth: voting period has not ended yet")
	}
	p.Closed = true
}

// Winner returns the index of the option with the most votes.
// Panics if the poll is still open or if there's a tie.
func Winner(id int64) int64 {
	p := getPoll(id)
	if !p.Closed {
		panic("votingbooth: poll is still open")
	}
	best := int64(0)
	bestIdx := int64(-1)
	tie := false
	for i, c := range p.VoteCount {
		if c > best {
			best = c
			bestIdx = int64(i)
			tie = false
		} else if c == best && best > 0 {
			tie = true
		}
	}
	if tie {
		panic("votingbooth: poll ended in a tie")
	}
	if bestIdx < 0 {
		panic("votingbooth: no votes cast")
	}
	return bestIdx
}

func Render(path string) string {
	out := "# Voting Booth\n\n"
	out += ufmt.Sprintf("Total polls: %d\n\n", polls.Size())
	polls.Iterate("", "", func(key string, value interface{}) bool {
		p := value.(*Poll)
		out += ufmt.Sprintf("## #%d: %s\n", p.ID, p.Question)
		status := "open"
		if p.Closed {
			status = "closed"
		}
		out += ufmt.Sprintf("Status: %s\n", status)
		for i, opt := range p.Options {
			out += ufmt.Sprintf("- %s: %d votes\n", opt, p.VoteCount[i])
		}
		out += "\n"
		return false
	})
	return out
}
