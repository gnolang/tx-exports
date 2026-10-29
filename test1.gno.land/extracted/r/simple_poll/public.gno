package poll

import (
	"std"

	"gno.land/p/avl"
)

func CreatePoll(title string) PollID {
	std.AssertOriginCall()

	caller := std.GetOrigCaller()
	pollID = pollID.next()

	p := &Poll{
		id:        pollID,
		title:     title,
		creator:   caller,
		createdAt: std.GetTimestamp(),

		options:  avl.NewMutTree(),
		votes:    avl.NewMutTree(),
		voteCnts: avl.NewMutTree(),

		optionID: OptionID(0),
	}

	polls.Set(pollID.String(), p)
	return p.id
}

func AddPollOption(pollID PollID, value string) OptionID {
	std.AssertOriginCall()

	p, exists := polls.Get(pollID.String())
	if !exists {
		panic("no poll")
	}

	poll := p.(*Poll)

	caller := std.GetOrigCaller()
	if poll.creator != caller {
		panic("you are not owner of this poll")
	}

	id := poll.addOption(value)
	return id
}

func Vote(pollID PollID, optionID OptionID) {
	std.AssertOriginCall()

	p, exists := polls.Get(pollID.String())
	if !exists {
		panic("no poll")
	}

	poll := p.(*Poll)

	exists = poll.options.Has(optionID.String())
	if !exists {
		panic("error: option id is wrong")
	}

	addr := std.GetOrigCaller()
	voted := poll.votes.Has(addr.String())
	if voted {
		panic("already voted!")
	}

	var voteCnt uint64
	vc, exists := poll.voteCnts.Get(optionID.String())
	if exists {
		voteCnt = vc.(uint64) + 1
	} else {
		voteCnt = 1
	}

	poll.voteCnts.Set(optionID.String(), voteCnt)
	poll.votes.Set(std.GetOrigCaller().String(), optionID)

}
