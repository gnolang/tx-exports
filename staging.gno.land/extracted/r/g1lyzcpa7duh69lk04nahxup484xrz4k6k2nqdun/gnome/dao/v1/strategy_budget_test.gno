package gnome

import (
	"errors"
	"fmt"
	"std"
	"testing"
	"time"

	"gno.land/p/demo/testutils"

	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
)

func TestBudgetStrategy(t *testing.T) {
	cases := []struct {
		name    string
		council *gnome.DAO
		err     string
	}{
		{
			name: "ok",
			council: gnome.MustNew("council", "Council",
				gnome.AssignAsSuperCouncil(),
				gnome.WithSubDAO(
					gnome.MustNew("main", "Main"),
				),
			),
		},
		{
			name: "nil council",
			err:  "council DAO is requried",
		},
		{
			name:    "no super council",
			council: gnome.MustNew("council", "Council"),
			err:     "budget strategy expects DAO to be a super council",
		},
		{
			name:    "council without main DAO",
			council: gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil()),
			err:     "budget strategy expects council DAO to have at least one sub DAO",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			name := "budget"
			quorum := 0.51
			votingPeriod := time.Hour * 24 * 7
			choices := fmt.Sprintf("%v", []gnome.VoteChoice{
				gnome.ChoiceYes,
				gnome.ChoiceNo,
			})

			// Act
			var s budgetStrategy
			err := handlePanic(t, func() {
				s = newBudgetStrategy(tc.council, "1USD")
			})

			// Assert
			if tc.err != "" {
				assertError(t, tc.err, err)
				return
			}

			assertNoError(t, err)

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
		})
	}
}

func TestBudgetStrategyCheckVote(t *testing.T) {
	councilMember := newTestMember(t, "council")
	mainMember := newTestMember(t, "main")
	council := gnome.MustNew(
		"council",
		"Council",
		gnome.AssignAsSuperCouncil(),
		gnome.WithMembers(councilMember),
		gnome.WithSubDAO(
			gnome.MustNew("main", "Main", gnome.WithMembers(mainMember)),
		),
	)

	cases := []struct {
		name    string
		address std.Address
		choice  gnome.VoteChoice
		council *gnome.DAO
		err     string
	}{
		{
			name:    "council DAO vote",
			choice:  gnome.ChoiceYes,
			address: councilMember.Address,
			council: council,
		},
		{
			name:    "main DAO vote",
			choice:  gnome.ChoiceYes,
			address: mainMember.Address,
			council: council,
		},
		{
			name:    "non member vote",
			choice:  gnome.ChoiceNo,
			address: testutils.TestAddress("foo"),
			council: council,
			err:     "only members of the council DAO or main DAO can vote on budget proposals",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			s := newBudgetStrategy(tc.council, "1USD")

			// Act
			err := s.CheckVote(tc.address, tc.choice, "")

			// Assert
			if tc.err != "" {
				assertError(t, tc.err, err)
			} else {
				assertNoError(t, err)
			}
		})
	}
}

func TestBudgetStrategyTally(t *testing.T) {
	council := gnome.MustNew(
		"council",
		"Council",
		gnome.AssignAsSuperCouncil(),
		gnome.WithMembers(
			newTestMember(t, "member1"),
			newTestMember(t, "member2"),
			newTestMember(t, "member3"),
			newTestMember(t, "member4"),
		),
		gnome.WithSubDAO(
			gnome.MustNew("main", "Main"),
		),
	)
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

			s := newBudgetStrategy(council, "1USD")

			// Act
			choice := s.Tally(council, *record)

			// Assert
			if choice != tc.choice {
				t.Fatalf("expected tally result choice: '%v', got: '%v'", tc.choice, choice)
			}
		})
	}
}

func handlePanic(t *testing.T, fn func()) (reason error) {
	t.Helper()

	defer func() {
		if r := recover(); r != nil {
			if err, _ := r.(error); err != nil {
				reason = err
			} else {
				reason = errors.New(fmt.Sprint(r))
			}
		}
	}()

	fn()
	return
}
