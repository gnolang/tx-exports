package poll

import (
	"std"
	"strings"
	"testing"

	"gno.land/p/demo/testutils"

	realm "gno.land/r/jeronimoalbi/testpoll"
)

func TestVote(t *testing.T) {
	cases := []struct {
		name        string
		args        [4]bool
		addr        std.Address
		msg, errMsg string
		hasVoted    bool
		totalVotes  int
		choiceVotes map[realm.Choice]uint
		setup       func(*realm.Poll)
	}{
		{
			name:       "ok",
			args:       [4]bool{false, true, false, false},
			addr:       testutils.TestAddress("test"),
			hasVoted:   true,
			totalVotes: 1,
			msg:        `You have successfully voted yes on "This year" you can check out the result at https://test3.gno.land/r/gnoyourdate/poll`,
			choiceVotes: map[realm.Choice]uint{
				realm.ChoiceThisMonth:        0,
				realm.ChoiceThisYear:         1,
				realm.ChoiceOneOrTwoYearsAgo: 0,
				realm.ChoiceSinceInception:   0,
			},
		},
		{
			name:       "ok with other votes",
			args:       [4]bool{false, false, true, false},
			addr:       testutils.TestAddress("test"),
			hasVoted:   true,
			totalVotes: 3,
			msg:        `You have successfully voted yes on "1-2 years ago" you can check out the result at https://test3.gno.land/r/gnoyourdate/poll`,
			choiceVotes: map[realm.Choice]uint{
				realm.ChoiceThisMonth:        1,
				realm.ChoiceThisYear:         0,
				realm.ChoiceOneOrTwoYearsAgo: 2,
				realm.ChoiceSinceInception:   0,
			},
			setup: func(p *realm.Poll) {
				p.Participants = append(p.Participants, testutils.TestAddress("test2"), testutils.TestAddress("test3"))
				p.Answers[0].Count++
				p.Answers[2].Count++
			},
		},
		{
			name:       "already voted",
			args:       [4]bool{true, false, false, false},
			addr:       testutils.TestAddress("test"),
			hasVoted:   true,
			totalVotes: 1,
			errMsg:     "This address already voted",
			choiceVotes: map[realm.Choice]uint{
				realm.ChoiceThisMonth:        1,
				realm.ChoiceThisYear:         0,
				realm.ChoiceOneOrTwoYearsAgo: 0,
				realm.ChoiceSinceInception:   0,
			},
			setup: func(p *realm.Poll) {
				p.Participants = append(p.Participants, testutils.TestAddress("test"))
				p.Answers[0].Count++
			},
		},
		{
			name: "multiple vote choices",
			args: [4]bool{true, true, false, false},
			addr: testutils.TestAddress("test"),
			errMsg: "Multiple choices has been selected, you should submit a vote for only one answer.\\n" +
				"The answer you choose should be selected as True (Yes) making sure that all other options are selected as False (No).",
			choiceVotes: map[realm.Choice]uint{
				realm.ChoiceThisMonth:        0,
				realm.ChoiceThisYear:         0,
				realm.ChoiceOneOrTwoYearsAgo: 0,
				realm.ChoiceSinceInception:   0,
			},
		},
		{
			name: "no vote choice",
			addr: testutils.TestAddress("test"),
			errMsg: "No choice has been selected, you should submit a vote for one of the answers.\\n" +
				"Only one of the choices should be selected to consider the vote as valid.",
			choiceVotes: map[realm.Choice]uint{
				realm.ChoiceThisMonth:        0,
				realm.ChoiceThisYear:         0,
				realm.ChoiceOneOrTwoYearsAgo: 0,
				realm.ChoiceSinceInception:   0,
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			defer teardown(t)()

			std.TestSetOrigCaller(tc.addr)

			if tc.setup != nil {
				tc.setup(&realm.poll)
			}

			var msg string

			// Act
			errMsg := catchPanic(t, func() {
				msg = realm.Vote(tc.args[0], tc.args[1], tc.args[2], tc.args[3])
			})

			// Assert
			if msg != tc.msg {
				t.Fatalf("expected vote success message: '%s', got: '%s'", tc.msg, msg)
			}

			if got := strings.ReplaceAll(errMsg, "\n", "\\n"); got != tc.errMsg {
				t.Fatalf("expected vote panic: '%s', got: '%s'", tc.errMsg, got)
			}

			if got := realm.poll.HasVoted(tc.addr); got != tc.hasVoted {
				t.Fatalf("expected has voted check: %v, got: %v", tc.hasVoted, got)
			}

			if got := len(realm.poll.Participants); got != tc.totalVotes {
				t.Fatalf("expected total vote count: %d, got: %d", tc.totalVotes, got)
			}

			for choice, count := range tc.choiceVotes {
				if got := realm.poll.GetCount(choice); got != count {
					t.Fatalf("expected vote count for choice %s: %d, got: %d", choice.String(), count, got)
				}
			}
		})
	}
}

func TestRender(t *testing.T) {
	// Arrange
	wantMarkdown := "## Poll: When did you first learn about Gno.land?\\n" +
		"You can participate in the poll by [submitting your vote]" +
		"(https://gno.studio/connect/gno.land/r/gnoyourdate/poll?network=test3&tab=functions#Vote)\\n" +
		"### Answers:\\n" +
		"- This month: 0 vote(s)\\n" +
		"- This year: 0 vote(s)\\n" +
		"- 1-2 years ago: 0 vote(s)\\n" +
		"- Since its inception: 0 vote(s)\\n\\n" +
		"The total number of answers is **0**"

	// Act
	markdown := realm.Render("")

	// Assert
	if got := strings.ReplaceAll(markdown, "\n", "\\n"); got != wantMarkdown {
		t.Fatalf("expected render output: '%s', got: '%s'", wantMarkdown, got)
	}
}

func teardown(t *testing.T) func() {
	t.Helper()

	// Make a copy of the current Poll instance
	poll := realm.poll

	return func() {
		// Cleanup votes
		for i := range poll.Answers {
			poll.Answers[i].Count = 0
		}

		// Restore the global Poll instance
		realm.poll = poll
	}
}

func catchPanic(t *testing.T, fn func()) (reason string) {
	t.Helper()

	defer func() {
		if r := recover(); r != nil {
			if err, _ := r.(error); err != nil {
				reason = err.Error()
			} else {
				reason = r.(string)
			}
		}
	}()

	fn()
	return
}