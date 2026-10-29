package poll

import (
	"std"
	"strconv"

	"gno.land/p/avl"
)

type PollID uint64

type Poll struct {
	id        PollID
	title     string
	creator   std.Address
	createdAt std.Time
	closed    bool

	options  *avl.MutTree // optionID -> option(string)
	optionID OptionID

	votes    *avl.MutTree // voter(std.Address) -> optionID
	voteCnts *avl.MutTree // optionID -> voteCount(int)
}

var polls = avl.NewMutTree()
var pollID = PollID(0)

func (pid PollID) String() string {
	return strconv.Itoa(int(pid))
}

func (pid PollID) next() PollID {
	return PollID(pid + 1)
}

func (p *Poll) addOption(value string) OptionID {
	oid := p.optionID.next()
	p.options.Set(oid.String(), value)
	p.optionID = oid
	return oid
}

func (p *Poll) VoteTotal() int {
	return p.votes.Size()
}

func (p *Poll) voteCountByOptionID(id string) uint64 {
	cnt, exists := p.voteCnts.Get(id)
	if !exists {
		return 0
	}
	return cnt.(uint64)
}
