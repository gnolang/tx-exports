package gnome

import (
	"std"

	"gno.land/p/demo/avl"
)

// VotingRecordIterFn defines the a callback to iterate voting choices.
type VotingRecordIterFn func(_ VoteChoice, voteCount uint) bool

// NewVotingRecord creates a new voting record.
func NewVotingRecord() *VotingRecord {
	return &VotingRecord{}
}

// VotingRecord mamages votes and vote count.
type VotingRecord struct {
	votes   []Vote
	counter avl.Tree // VoteChoice -> count (uint)
}

// Votes return the list of votes.
func (r VotingRecord) Votes() []Vote {
	return r.votes
}

// VoteCount returns the number of votes.
func (r VotingRecord) VoteCount() int {
	return len(r.votes)
}

// Get returns the number of votes for vote choice.
func (r VotingRecord) Get(c VoteChoice) uint {
	key := string(c)
	if v, ok := r.counter.Get(key); ok {
		return v.(uint)
	}
	return 0
}

// Add adds a vote to the record.
func (r *VotingRecord) Add(v Vote) {
	r.votes = append(r.votes, v)
	key := string(v.Choice)
	r.counter.Set(key, r.Get(v.Choice)+1)
}

// Remove removes a vote from the record.
func (r *VotingRecord) Remove(addr std.Address) bool {
	for i, v := range r.votes {
		if v.Address == addr {
			r.votes = append(r.votes[:i], r.votes[i+1:]...)
			key := string(v.Choice)
			r.counter.Set(key, r.Get(v.Choice)-1)

			return true
		}
	}
	return false
}

// Iterate iterates all vote choices.
func (r VotingRecord) Iterate(fn VotingRecordIterFn) bool {
	return r.counter.Iterate("", "", func(key string, value interface{}) bool {
		choice := VoteChoice(key)
		return fn(choice, value.(uint))
	})
}

// SelectChoiceByMajority select the vote choice by majority.
// Vote choice is a majority when chosen by more than half of the votes.
// Majority type is defined by the caller depending on the vote records and abstentions, it would be
// absolute majority if abstentions are considered, otherwise it would potentially be simple majority.
func SelectChoiceByMajority(r VotingRecord, abstentions int) (VoteChoice, bool) {
	votesCount := r.VoteCount() + abstentions
	choice := getMajorityChoice(r)
	isMajority := r.Get(choice) > uint(votesCount/2)
	return choice, isMajority
}

// SelectChoiceBySuperMajority select the vote choice by super majority using a 2/3s threshold.
// Abstentions are not considered when calculating the super majority choice.
func SelectChoiceBySuperMajority(r VotingRecord) (VoteChoice, bool) {
	choice := getMajorityChoice(r)
	isMajority := r.Get(choice) > uint((2*r.VoteCount())/3) // TODO: Allow threshold customization
	return choice, isMajority
}

// getMajorityChoice returns the choice voted by the majority.
// The result is only valid when there is a majority.
// Caller must validate that the returned choice represents a majority.
func getMajorityChoice(r VotingRecord) VoteChoice {
	var (
		choice       VoteChoice
		currentCount uint
	)

	r.Iterate(func(c VoteChoice, count uint) bool {
		if currentCount < count {
			choice = c
			currentCount = count
		}
		return false
	})

	return choice
}
