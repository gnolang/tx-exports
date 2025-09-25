package gnome

import (
	"fmt"
	"testing"
	"time"

	gnome "gno.land/p/gnome/dao"
)

func TestGeneralStrategy(t *testing.T) {
	// Arrange
	name := StrategyNameGeneral
	quorum := 0.51
	votingPeriod := time.Hour * 24 * 2
	choices := fmt.Sprintf("%v", []gnome.VoteChoice{
		gnome.ChoiceYes,
		gnome.ChoiceNo,
	})

	// Act
	s := newGeneralStrategy()

	// Assert
	if got := s.Name(); got != name {
		t.Fatalf("expected strategy name: '%s', got: '%s'", name, got)
	}

	if got := s.Quorum(); got != quorum {
		t.Fatalf("expected strategy quorum: %.2f, got: %.2f", quorum, got)
	}

	if got := s.VotingPeriod(); got != votingPeriod {
		t.Fatalf("expected strategy voting period: %d, got: %d", votingPeriod, got)
	}

	if got := fmt.Sprintf("%v", s.VoteChoices()); got != choices {
		t.Fatalf("expected strategy vote choices: %s, got: %s", choices, got)
	}
}

func TestGeneralStrategyCheckVote(t *testing.T) {
	cases := []struct {
		name        string
		choice      gnome.VoteChoice
		reason, err string
	}{
		{
			name:   "yes",
			choice: gnome.ChoiceYes,
		},
		{
			name:   "yes with reason",
			choice: gnome.ChoiceYes,
			reason: "foo bar",
		},
		{
			name:   "no with reason",
			choice: gnome.ChoiceNo,
			reason: "foo bar",
		},
		{
			name:   "no with invalid reason",
			choice: gnome.ChoiceNo,
			err:    "reason is required when voting NO in standard proposals",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			s := newGeneralStrategy()

			// Act
			err := s.CheckVote("", tc.choice, tc.reason)

			// Assert
			if tc.err != "" {
				assertError(t, tc.err, err)
			} else {
				assertNoError(t, err)
			}
		})
	}
}

func TestGeneralStrategyTally(t *testing.T) {
	dao := gnome.MustNew("test", "Test", gnome.WithMembers(
		newTestMember(t, "member1"),
		newTestMember(t, "member2"),
		newTestMember(t, "member3"),
		newTestMember(t, "member4"),
	))
	cases := []struct {
		name   string
		votes  []gnome.Vote
		choice gnome.VoteChoice
	}{
		{
			name: "majority",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceYes,
		},
		{
			name: "majority with abstentions",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceNo,
		},
		{
			name: "no quorum",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceNone,
		},
		{
			name: "no quorum with abstentions",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceYes},
			},
			choice: gnome.ChoiceNone,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			record := gnome.NewVotingRecord()
			for _, v := range tc.votes {
				record.Add(v)
			}

			s := newGeneralStrategy()

			// Act
			choice := s.Tally(dao, *record)

			// Assert
			if choice != tc.choice {
				t.Fatalf("expected tally result choice: '%v', got: '%v'", tc.choice, choice)
			}
		})
	}
}

func assertError(t *testing.T, expected interface{}, actual error) {
	t.Helper()

	want, ok := expected.(string)
	if !ok {
		if err, ok := expected.(error); ok {
			want = err.Error()
		}
	}

	if actual == nil {
		t.Fatalf("expected error: '%s', got no error", want)
	}

	if want != actual.Error() {
		t.Fatalf("expected error: '%s', got: '%s'", want, actual.Error())
	}
}

func assertNoError(t *testing.T, err interface{}) {
	t.Helper()

	if err == nil {
		return
	}

	actual, ok := err.(string)
	if !ok {
		if e, ok := err.(error); ok {
			actual = e.Error()
		}
	}

	if actual != "" {
		t.Fatalf("expected no error, got: '%s'", actual)
	}
}
