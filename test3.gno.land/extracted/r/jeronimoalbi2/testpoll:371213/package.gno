package testpoll

import (
	"std"
	"strconv"
	"strings"

	"gno.land/p/demo/ufmt"
)

const (
	ChoiceNone             Choice = 0x0
	ChoiceSinceInception   Choice = 0x1
	ChoiceOneOrTwoYearsAgo Choice = 0x2
	ChoiceThisYear         Choice = 0x4
	ChoiceThisMonth        Choice = 0x8
)

var answerLabels = map[Choice]string{
	ChoiceThisMonth:        "This month",
	ChoiceThisYear:         "This year",
	ChoiceOneOrTwoYearsAgo: "1-2 years ago",
	ChoiceSinceInception:   "Since its inception",
}

var (
	realmURL string
	admin    std.Address
	poll     = Poll{
		Question:  "When did you first learn about Gno.land?",
		VotingURL: "https://gno.studio/connect/gno.land/r/gnoyourdate/poll?network=test3&tab=functions#Vote",
		Answers: []Answer{
			{Choice: ChoiceThisMonth},
			{Choice: ChoiceThisYear},
			{Choice: ChoiceOneOrTwoYearsAgo},
			{Choice: ChoiceSinceInception},
		},
	}
)

func init() {
	realmURL = "https://test3.gno.land" + strings.TrimPrefix(std.CurrentRealmPath(), "gno.land")
	admin = std.GetOrigCaller()
}

type (
	// Choice defines a type for poll choices.
	Choice byte

	// Poll tracks the number of votes for a set of pre defined answers.
	Poll struct {
		Question     string
		VotingURL    string
		Answers      []Answer
		Participants []std.Address // TODO: Use AVL tree for better search performance?
		Ended        bool
	}

	// Answer contains the number of votes for a poll choice.
	Answer struct {
		Choice Choice
		Count  uint
	}
)

// String returns the choice as a string.
func (c Choice) String() string {
	return strconv.Itoa(int(c))
}

// GetCount returns the number of votes submitted for a poll choice.
func (p Poll) GetCount(c Choice) uint {
	for _, a := range p.Answers {
		if a.Choice == c {
			return a.Count
		}
	}
	return 0
}

// HasVoted checks if an address already submitted a vote.
func (p Poll) HasVoted(addr std.Address) bool {
	for _, a := range p.Participants {
		if a == addr {
			return true
		}
	}
	return false
}

// Vote submits a vote for one of the poll choices.
//
// Only one of the choices should be selected to consider the vote as valid.
// The answer you choose should be selected as True (Yes) making sure that all other options are selected as False (No).
//
// When did you first learn about Gno.land?
// - This month
// - This year
// - 1-2 years ago
// - Since its inception
func Vote(thisMonth, thisYear, oneOrTwoYearsAgo, sinceInception bool) string {
	assertPollIsActive()

	choice := mustCreateChoiceFromVoteArgs(thisMonth, thisYear, oneOrTwoYearsAgo, sinceInception)
	caller := std.GetOrigCaller()
	assertFirstVote(caller)

	for i, a := range poll.Answers {
		if a.Choice == choice {
			poll.Answers[i].Count++
			poll.Participants = append(poll.Participants, caller)
			break
		}
	}

	return ufmt.Sprintf(
		`You have successfully voted yes on "%s" you can check out the result at %s`,
		answerLabels[choice],
		realmURL,
	)
}

// Render returns a Markdown string with the poll details.
func Render(string) string {
	var buf strings.Builder

	buf.WriteString(ufmt.Sprintf("## Poll: %s\n", poll.Question))

	if poll.Ended {
		buf.WriteString("The poll has ended\n")
	} else {
		buf.WriteString(
			ufmt.Sprintf("You can participate in the poll by [submitting your vote](%s)\n", poll.VotingURL),
		)
	}

	buf.WriteString("### Answers:\n")
	for _, c := range [4]Choice{ChoiceThisMonth, ChoiceThisYear, ChoiceOneOrTwoYearsAgo, ChoiceSinceInception} {
		buf.WriteString(
			ufmt.Sprintf("- %s: %d vote(s)\n", answerLabels[c], poll.GetCount(c)),
		)
	}

	buf.WriteString(
		ufmt.Sprintf("\nThe total number of answers is **%d**", len(poll.Participants)),
	)

	return buf.String()
}

// EndPoll ends the poll to stop receiving new votes.
func EndPoll() string {
	assertCallerIsAdmin()
	assertPollIsActive()

	poll.Ended = true
	return "Poll ended successfully"
}

// GetAdmin returns the address of the Realm admin account.
func GetAdmin() string {
	return admin.String()
}

func mustCreateChoiceFromVoteArgs(voteArgs ...bool) Choice {
	var c Choice
	for _, arg := range voteArgs {
		c <<= 1 // shift left
		if arg {
			c |= 1 // last bit on
		}
	}

	switch c {
	case ChoiceThisMonth, ChoiceThisYear, ChoiceOneOrTwoYearsAgo, ChoiceSinceInception:
		return c
	case ChoiceNone:
		panic(
			"No choice has been selected, you should submit a vote for one of the answers.\n" +
				"Only one of the choices should be selected to consider the vote as valid.",
		)
	default:
		panic(
			"Multiple choices has been selected, you should submit a vote for only one answer.\n" +
				"The answer you choose should be selected as True (Yes) making sure that all other options are selected as False (No).",
		)
	}
}

func assertPollIsActive() {
	if poll.Ended {
		panic("Poll has ended")
	}
}

func assertFirstVote(addr std.Address) {
	for _, a := range poll.Participants {
		if a == addr {
			panic("This address already voted")
		}
	}
}

func assertCallerIsAdmin() {
	if admin != std.GetOrigCaller() {
		panic("Forbidden")
	}
}