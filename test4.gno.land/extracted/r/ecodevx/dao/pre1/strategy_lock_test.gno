package gnome

import (
	"errors"
	"fmt"
	"testing"
	"time"

	gnome "gno.land/p/ecodevx/dao"
)

func TestLockingStrategy(t *testing.T) {
	cases := []struct {
		name, err string
		setup     func() *gnome.DAO
	}{
		{
			name: "ok",
			setup: func() *gnome.DAO {
				return gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil())
			},
		},
		{
			name: "dao is not council",
			setup: func() *gnome.DAO {
				return gnome.MustNew("council", "Council")
			},
			err: "DAO is not the council",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			name := StrategyNameLocking
			quorum := 0.33
			votingPeriod := time.Hour * 24 * 2
			choices := fmt.Sprintf("%v", []gnome.VoteChoice{
				gnome.ChoiceYes,
				gnome.ChoiceNo,
			})
			councilDAO := tc.setup()

			// Act
			var s lockingStrategy
			err := handlePanic(t, func() {
				s = newLockingStrategy(councilDAO, "", nil)
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

func TestLockingStrategyTally(t *testing.T) {
	councilDAO := gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil())
	cases := []struct {
		name   string
		votes  []gnome.Vote
		choice gnome.VoteChoice
	}{
		{
			name: "yes with one vote",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
			},
			choice: gnome.ChoiceYes,
		},
		{
			name: "no with one vote",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceNo,
		},
		{
			name: "yes with multiple votes",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceYes},
			},
			choice: gnome.ChoiceYes,
		},
		{
			name: "no with multiple votes",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceYes},
			},
			choice: gnome.ChoiceNo,
		},
		{
			name: "tie",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceNone,
		},
		{
			name: "tie with multiple votes",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceNone,
		},
		{
			name:   "no votes",
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

			s := newLockingStrategy(councilDAO, "", nil)

			// Act
			choice := s.Tally(nil, *record)

			// Assert
			if choice != tc.choice {
				t.Fatalf("expected tally result choice: '%v', got: '%v'", tc.choice, choice)
			}
		})
	}
}

func TestLockingStrategyValidate(t *testing.T) {
	cases := []struct {
		name  string
		setup func(*gnome.DAO)
		err   string
	}{
		{
			name: "ok",
		},
		{
			name: "locked council DAO",
			setup: func(councilDAO *gnome.DAO) {
				councilDAO.Lock("")
			},
			err: "council DAO is already locked",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			councilDAO := gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil())
			if tc.setup != nil {
				tc.setup(councilDAO)
			}

			s := newLockingStrategy(councilDAO, "", nil)

			// Act
			err := s.Validate(nil)

			// Assert
			if tc.err != "" {
				assertError(t, tc.err, err)
			} else {
				assertNoError(t, err)
			}
		})
	}
}

func TestLockingStrategyExecute(t *testing.T) {
	cases := []struct {
		name, reason, err string
		setup             func(*gnome.DAO)
		preLockErr        error
	}{
		{
			name:   "ok",
			reason: "Lock reason",
		},
		{
			name:       "pre lock function error",
			preLockErr: errors.New("test error"),
			err:        "test error",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			councilDAO := gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil())
			if tc.setup != nil {
				tc.setup(councilDAO)
			}

			var (
				preLockFnCalled bool

				s = newLockingStrategy(councilDAO, tc.reason, func() error {
					preLockFnCalled = true
					return tc.preLockErr
				})
			)

			// Act
			err := s.Execute(nil)

			// Assert
			if tc.err != "" {
				assertError(t, tc.err, err)
				return
			}

			assertNoError(t, err)

			if !preLockFnCalled {
				t.Fatal("expected pre-lock function to be called")
			}

			if !councilDAO.IsLocked() {
				t.Fatal("expected DAO to be locked")
			}

			if got := councilDAO.LockReason(); got != tc.reason {
				t.Fatalf("expected lock reason: '%s', got: '%s'", tc.reason, got)
			}
		})
	}
}
