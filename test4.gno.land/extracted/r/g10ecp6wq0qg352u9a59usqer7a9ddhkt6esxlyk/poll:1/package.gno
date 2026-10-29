package poll

import (
	"bytes"
	"std"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/poll"
	"gno.land/p/demo/seqid"
	"gno.land/p/demo/ufmt"
)

// state variables
var (
	polls         *avl.Tree // id -> Poll
	pollIDCounter seqid.ID
)

func init() {
	polls = avl.NewTree()
}

// NewPoll - Creates a new Poll instance
func NewPoll(title, description string, deadline int64) string {
	// get block height
	if deadline <= std.GetHeight() {
		panic("deadline has to be in the future")
	}

	// Generate int
	id := pollIDCounter.Next().String()
	p := poll.NewPoll(title, description, deadline)

	// add new poll in avl tree
	polls.Set(id, p)

	return ufmt.Sprintf("Successfully created poll #%s!", id)
}

// Vote - vote for a specific Poll
// yes - true, no - false
func Vote(id string, vote bool) string {
	// get txSender
	txSender := std.GetOrigCaller()

	// get specific Poll from AVL tree
	pollRaw, exists := polls.Get(id)

	if !exists {
		panic("poll with specified doesn't exist")
	}

	// cast Poll into proper format
	poll, _ := pollRaw.(*poll.Poll)

	voted, _ := poll.HasVoted(txSender)
	if voted {
		panic("you've already voted!")
	}

	if poll.Deadline() <= std.GetHeight() {
		panic("voting for this poll is closed")
	}

	// record vote
	poll.Vote(txSender, vote)

	// update Poll in tree
	polls.Set(id, poll)

	if vote == true {
		return ufmt.Sprintf("Successfully voted YAY for poll #%s!", id)
	}
	return ufmt.Sprintf("Successfully voted NAY for poll #%s!", id)
}

func Render(path string) string {
	var b bytes.Buffer

	b.WriteString("# Polls!\n\n")

	if polls.Size() == 0 {
		b.WriteString("### No active polls currently!")
		return b.String()
	}
	polls.Iterate("", "", func(key string, value interface{}) bool {

		// cast raw data from tree into Poll struct
		p := value.(*poll.Poll)
		ddl := p.Deadline()

		yay, nay := p.VoteCount()
		yayPercent := 0
		nayPercent := 0

		if yay+nay != 0 {
			yayPercent = yay * 100 / (yay + nay)
			nayPercent = nay * 100 / (yay + nay)
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

			if vote == true {
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

// How-to: Write Simple Dapp