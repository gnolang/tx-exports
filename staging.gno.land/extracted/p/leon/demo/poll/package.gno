package poll

import (
	"errors"
	"std"
)

// gno.land/p/demo/poll
// avl tree

type Poll struct {
	title       string
	description string
	deadline    int64               // block number
	voters      map[std.Address]int // address (user) > yes/no // -1 = no, 1 = yes, 0 has not voted
}

// getters

func (p Poll) Title() string {
	return p.title
}

func (p Poll) Description() string {
	return p.description
}

func (p Poll) Deadline() int64 {
	return p.deadline
}

func (p Poll) Voters() map[std.Address]int {
	return p.voters
}

// setters

func (p *Poll) Vote(voter std.Address, vote int) error {
	if !voter.IsValid() {
		return errors.New("voter address is not valid")
	}

	if vote != -1 || vote != 1 {
		return errors.New("invalid vote, needs to be -1 (no) or 1 (yes)")
	}

	if _, exists := p.voters[voter]; exists {
		return errors.New("voter already voted")
	}

	p.voters[voter] = vote

	return nil
}

// constructor

func NewPoll(title, description string, deadline int64) (*Poll, error) {
	if title == "" || description == "" {
		return nil, errors.New("you need to provide both the title and the description to the poll")
	}

	currentBlockNumber := std.GetHeight() // now
	if deadline < currentBlockNumber {
		return nil, errors.New("deadline needs to be in the future")
	}

	return &Poll{
		title:       title,
		description: description,
		deadline:    deadline,
		voters:      make(map[std.Address]int),
	}, nil
}

func (p Poll) VoteCount() (int, int) {
	var yes int

	for _, vote := range p.voters {
		if vote == 1 {
			yes += 1
		}
	}

	totalVotes := len(p.voters)

	return yes, totalVotes - yes
}
