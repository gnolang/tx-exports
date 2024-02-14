package polllll

import (
	"bytes"
	"std"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/ufmt"
)

// Main struct
type Poll struct {
	title       string
	description string
	deadline    int64     // block height
	voters      *avl.Tree // addr -> yes/no (bool)
}

// Getters
func (p Poll) Title() string {
	return p.title
}

func (p Poll) Description() string {
	return p.description
}

func (p Poll) Deadline() int64 {
	return p.deadline
}

func (p Poll) Voters() *avl.Tree {
	return p.voters
}

// Poll instance constructor
func NewPoll(title, description string, deadline int64) *Poll {
	return &Poll{
		title:       title,
		description: description,
		deadline:    deadline,
		voters:      avl.NewTree(),
	}
}

// Vote records a vote for a user
func (p *Poll) Vote(voter std.Address, vote bool) {
	p.voters.Set(string(voter), vote)
}

// HasVoted checks if a user has voted and returns the vote: yes - true, no - false
func (p *Poll) HasVoted(address std.Address) (bool, bool) {
	vote, exists := p.voters.Get(string(address))
	if exists {
		return true, vote.(bool)
	}
	return false, false
}

// VoteCount returns the number of yay & nay votes
func (p Poll) VoteCount() (int, int) {
	var yay int

	p.voters.Iterate("", "", func(key string, value interface{}) bool {
		vote := value.(bool)
		if vote {
			yay++
		}
		return false
	})
	return yay, p.voters.Size() - yay
}

// State variables
var (
	polls         *avl.Tree // id -> Poll
	pollIDCounter int
)

func init() {
	polls = avl.NewTree()
	pollIDCounter = 0
}

// NewPoll creates a new Poll instance
func NewPoll(title, description string, deadline int64) string {
	// get block height
	if deadline <= std.GetHeight() {
		return "Error: Deadline has to be in the future."
	}

	// convert int ID to string used in AVL tree
	id := ufmt.Sprintf("%d", pollIDCounter)
	p := NewPoll(title, description, deadline)

	// add new poll in avl tree
	polls.Set(id, p)

	// increment ID counter
	pollIDCounter++

	return ufmt.Sprintf("Successfully created poll #%s!", id)
}

// Vote allows voting for a specific Poll (yes - true, no - false)
func Vote(pollID int, vote bool) string {
	// get txSender
	txSender := std.GetOrigCaller()

	id := ufmt.Sprintf("%d", pollID)
	// get specific Poll from AVL tree
	pollRaw, exists := polls.Get(id)

	if !exists {
		return "Error: Poll with specified ID doesn't exist."
	}

	// cast Poll into proper format
	poll, _ := pollRaw.(*Poll)

	voted, _ := poll.HasVoted(txSender)
	if voted {
		return "Error: You've already voted!"
	}

	if poll.Deadline() <= std.GetHeight() {
		return "Error: Voting for this poll is closed."
	}

	// record vote
	poll.Vote(txSender, vote)

	// update Poll in tree
	polls.Set(id, poll)

	if vote {
		return ufmt.Sprintf("Successfully voted YAY for poll #%s!", id)
	}
	return ufmt.Sprintf("Successfully voted NAY for poll #%s!", id)
}

// Render renders the current state of polls
func Render(path string) string {
	var b bytes.Buffer

	b.WriteString("# Polls!\n\n")

	if polls.Size() == 0 {
		b.WriteString("### No active polls currently!")
		return b.String()
	}
	polls.Iterate("", "", func(key string, value interface{}) bool {

		// cast raw data from tree into Poll struct
		p := value.(*Poll)
		yay, nay := p.VoteCount()
		yayPercent := 0
		nayPercent := 0

		if totalVotes := yay + nay; totalVotes != 0 {
			yayPercent = yay * 100 / totalVotes
			nayPercent = nay * 100 / totalVotes
		}

		b.WriteString(
			ufmt.Sprintf(
				"## Poll #%s: %s\n",
				key, // poll ID
				p.Title(),
			),
		)

		dropdown := "<details>\n<summary>Poll details</summary><br>"
		b.WriteString(dropdown + "Description: " + p.Description())
		b.WriteString(
			ufmt.Sprintf("<br>Voting until block: %d<br>Current vote count: %d",
				p.Deadline(),
				p.Voters().Size()),
		)
		b.WriteString(
			ufmt.Sprintf("<br>YAY votes: %d (%d%%)", yay, yayPercent),
		)
		b.WriteString(
			ufmt.Sprintf("<br>NAY votes: %d (%d%%)</details>", nay, nayPercent),
		)

		dropdown = "<br><details>\n<summary>Vote details</summary>"
		b.WriteString(dropdown)

		p.Voters().Iterate("", "", func(key string, value interface{}) bool {
			voter := key
			vote := value.(bool)

			if vote {
				b.WriteString(
					ufmt.Sprintf("<br>%s voted YAY!", voter),
				)
			} else {
				b.WriteString(
					ufmt.Sprintf("<br>%s voted NAY!", voter),
				)
			}
			return false
		})

		b.WriteString("</details>\n\n")
		return false
	})
	return b.String()
}
