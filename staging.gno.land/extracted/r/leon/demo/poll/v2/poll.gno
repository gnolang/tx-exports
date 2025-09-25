package poll

import (
	"errors"
	"std"

	"gno.land/p/demo/ufmt"
	ppkg "gno.land/p/leon/demo/poll"
)

// gno.land/r/leon/demo/poll

type PollWithID struct {
	poll *ppkg.Poll
	id   uint
}

var (
	polls        = make([]*PollWithID, 0)
	pollIdCunter uint
)

func NewPoll(title, description string, deadline int) string {
	pollInstanace, err := ppkg.NewPoll(title, description, int64(deadline))
	if err != nil {
		return err.Error()
	}

	p := &PollWithID{
		poll: pollInstanace,
		id:   pollIdCunter,
	}

	polls = append(polls, p)
	pollIdCunter++

	return "successfully created poll: " + p.poll.Title()
}

func Vote(id uint, vote int) error {
	caller := std.PrevRealm().Addr()
	var pid *PollWithID

	for _, p := range polls {
		if p.id == id {
			pid = p
			break
		}
	}

	if pid == nil {
		return errors.New("poll with specified id not found")
	}

	if err := pid.poll.Vote(caller, vote); err != nil {
		return err
	}

	return nil
}

func (p PollWithID) String() string {
	return ufmt.Sprintf("%s\n\n%s\n\n%d\n\n", p.poll.Title(), p.poll.Description(), int(p.poll.Deadline()))
}

func Render(_ string) string {
	out := "# Polls App\n\n"

	for _, poll := range polls {
		out += poll.String()
	}

	return out
}
