package gnome

import (
	"fmt"
	"testing"
	"time"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/testutils"

	gnome "gno.land/p/ecodevx/dao"
)

func TestSubDAOCreationStrategy(t *testing.T) {
	cases := []struct {
		name, daoName, title, manifest, err string
		members                             []gnome.Member
	}{
		{
			name:     "ok",
			daoName:  "test",
			title:    "Test",
			manifest: "Test manifest",
			members: []gnome.Member{
				newTestMember(t, "address1"),
				newTestMember(t, "address2"),
				newTestMember(t, "address3"),
			},
		},
		{
			name: "without name",
			err:  "sub DAO name is required",
		},
		{
			name:    "invalid name",
			daoName: "invalid name",
			err:     `invalid sub DAO name, only letters from "a" to "z", numbers, "-" and "_" are allowed`,
		},
		{
			name:    "without title",
			daoName: "test",
			err:     "sub DAO title is required",
		},
		{
			name:    "without manifest",
			daoName: "test",
			title:   "Test",
			err:     "sub DAO manifest is required",
		},
		{
			name:     "less than two DAO members",
			daoName:  "test",
			title:    "Test",
			manifest: "Test manifest",
			err:      "sub DAOs require at least 3 members",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			name := StrategyNameSubDAOCreation
			quorum := 1.0
			votingPeriod := time.Hour * 24 * 7
			choices := fmt.Sprintf("%v", []gnome.VoteChoice{
				gnome.ChoiceYes,
				gnome.ChoiceNo,
			})

			// Act
			var s subDAOCreationStrategy
			err := handlePanic(t, func() {
				s = newSubDAOCreationStrategy(daoIndex{}, tc.daoName, tc.title, tc.manifest, tc.members)
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

func TestSubDAOCreationStrategyTally(t *testing.T) {
	dao := gnome.MustNew("main", "Main", gnome.WithMembers(
		newTestMember(t, "member1"),
		newTestMember(t, "member2"),
		newTestMember(t, "member3"),
	))
	cases := []struct {
		name   string
		votes  []gnome.Vote
		choice gnome.VoteChoice
	}{
		{
			name: "quorum vote yes",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceYes},
			},
			choice: gnome.ChoiceYes,
		},
		{
			name: "quorum vote no",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceNo,
		},
		{
			name: "quorum with different choices",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceYes},
			},
			choice: gnome.ChoiceNo,
		},
		{
			name: "no quorum",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
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

			s := newSubDAOCreationStrategy(daoIndex{}, "name", "Name", "Manifest", []gnome.Member{
				newTestMember(t, "member1"),
				newTestMember(t, "member2"),
				newTestMember(t, "member3"),
			})

			// Act
			choice := s.Tally(dao, *record)

			// Assert
			if choice != tc.choice {
				t.Fatalf("expected tally result choice: '%v', got: '%v'", tc.choice, choice)
			}
		})
	}
}

func TestSubDAOCreationStrategyValidate(t *testing.T) {
	cases := []struct {
		name, daoName string
		setup         func(*daoIndex) *gnome.DAO
		err           string
	}{
		{
			name:    "ok",
			daoName: "child",
			setup: func(*daoIndex) *gnome.DAO {
				return gnome.MustNew("parent", "Parent")
			},
		},
		{
			name:    "existing name",
			daoName: "child",
			setup: func(x *daoIndex) *gnome.DAO {
				child := gnome.MustNew("child", "Child")
				dao := gnome.MustNew("parent", "Parent", gnome.WithSubDAO(child))
				x.IndexByPath(child)
				return dao
			},
			err: "sub DAO path has been taken by another DAO",
		},
		{
			name:    "locked parent",
			daoName: "child",
			setup: func(*daoIndex) *gnome.DAO {
				dao := gnome.MustNew("parent", "Parent")
				dao.Lock("")
				return dao
			},
			err: "parent DAO 'parent' is locked",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			x := daoIndex{}
			dao := tc.setup(&x)
			members := []gnome.Member{
				newTestMember(t, "member1"),
				newTestMember(t, "member2"),
				newTestMember(t, "member3"),
			}
			s := newSubDAOCreationStrategy(x, tc.daoName, "Title", "Manifest", members)
			p, _ := gnome.NewProposal(1, s, members[0].Address, dao, "Title")

			// Act
			err := s.Validate(p)

			// Assert
			if tc.err != "" {
				assertError(t, tc.err, err)
			} else {
				assertNoError(t, err)
			}
		})
	}
}

func TestSubDAOCreationStrategyExecute(t *testing.T) {
	// Arrange
	dao := gnome.MustNew("name", "Name")
	subName := "sub"
	title := "Sub DAO"
	manifest := "Test manifest"

	s := newSubDAOCreationStrategy(daoIndex{}, subName, title, manifest, []gnome.Member{
		newTestMember(t, "member1"),
		newTestMember(t, "member2"),
		newTestMember(t, "member3"),
	})
	members := fmt.Sprintf("%v", s.members)

	// Act
	err := s.Execute(dao)

	// Assert
	assertNoError(t, err)

	subDAOs := dao.SubDAOs()
	if c := len(subDAOs); c != 1 {
		t.Fatalf("expected one sub DAO, got: %d", c)
	}

	subDAO := subDAOs[0]
	if got := subDAO.Name(); got != subName {
		t.Fatalf("expected sub DAO name: '%s', got: '%s'", subName, got)
	}

	if got := subDAO.Title(); got != title {
		t.Fatalf("expected sub DAO title: '%s', got: '%s'", title, got)
	}

	if got := subDAO.Manifest(); got != manifest {
		t.Fatalf("expected sub DAO manifest: '%s', got: '%d'", manifest, got)
	}

	if got := fmt.Sprintf("%v", subDAO.Members()); got != members {
		t.Fatalf("expected sub DAO members: '%s', got: '%s'", members, got)
	}
}

func TestModifyDAOMembersStrategy(t *testing.T) {
	cases := []struct {
		name                      string
		newMembers, removeMembers []gnome.Member
		err                       string
	}{
		{
			name: "new and remove members",
			newMembers: []gnome.Member{
				newTestMember(t, "address1"),
			},
			removeMembers: []gnome.Member{
				newTestMember(t, "address2"),
			},
		},
		{
			name: "new members only",
			newMembers: []gnome.Member{
				newTestMember(t, "address1"),
			},
		},
		{
			name: "remove members only",
			removeMembers: []gnome.Member{
				newTestMember(t, "address1"),
			},
		},
		{
			name: "no members",
			err:  "members are required",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			name := StrategyNameDAOMembersModification
			quorum := 0.51
			votingPeriod := time.Hour * 24 * 7
			choices := fmt.Sprintf("%v", []gnome.VoteChoice{
				gnome.ChoiceYes,
				gnome.ChoiceNo,
			})

			// Act
			var s daoMembersModificationStrategy
			err := handlePanic(t, func() {
				s = newDAOMembersModificationStrategy(tc.newMembers, tc.removeMembers)
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

func TestModifyDAOMembersStrategyTally(t *testing.T) {
	cases := []struct {
		name   string
		votes  []gnome.Vote
		choice gnome.VoteChoice
	}{
		{
			name: "super majority votes yes",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceYes},
			},
			choice: gnome.ChoiceYes,
		},
		{
			name: "super majority votes no",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceNo,
		},
		{
			name: "no majority",
			votes: []gnome.Vote{
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceYes},
				{Choice: gnome.ChoiceNo},
				{Choice: gnome.ChoiceNo},
			},
			choice: gnome.ChoiceNone,
		},
		{
			name: "no quorum",
			votes: []gnome.Vote{
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

			s := newDAOMembersModificationStrategy(
				[]gnome.Member{newTestMember(t, "member5")},
				[]gnome.Member{newTestMember(t, "member2")},
			)

			// Act
			choice := s.Tally(nil, *record)

			// Assert
			if choice != tc.choice {
				t.Fatalf("expected tally result choice: '%v', got: '%v'", tc.choice, choice)
			}
		})
	}
}

func TestModifyDAOMembersStrategyValidate(t *testing.T) {
	member5 := newTestMember(t, "member5")
	members := []gnome.Member{
		newTestMember(t, "member1"),
		newTestMember(t, "member2"),
		newTestMember(t, "member3"),
		newTestMember(t, "member4"),
	}

	cases := []struct {
		name                      string
		newMembers, removeMembers []gnome.Member
		setup                     func() *gnome.DAO
		err                       string
	}{
		{
			name:       "ok",
			newMembers: []gnome.Member{member5},
			setup: func() *gnome.DAO {
				dao := gnome.MustNew("main", "Main", gnome.WithMembers(members...))
				gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil(), gnome.WithSubDAO(dao))
				return dao
			},
		},
		{
			name:          "less than three members",
			newMembers:    []gnome.Member{member5},
			removeMembers: members[1:],
			setup: func() *gnome.DAO {
				dao := gnome.MustNew("main", "Main", gnome.WithMembers(members...))
				gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil(), gnome.WithSubDAO(dao))
				return dao
			},
			err: "DAO must always have a minimum of 3 members",
		},
		{
			name:       "add existing member",
			newMembers: []gnome.Member{members[0]},
			setup: func() *gnome.DAO {
				dao := gnome.MustNew("main", "Main", gnome.WithMembers(members...))
				gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil(), gnome.WithSubDAO(dao))
				return dao
			},
			err: "address is already a DAO member: " + members[0].String(),
		},
		{
			name:          "remove unexisting member",
			removeMembers: []gnome.Member{member5},
			setup: func() *gnome.DAO {
				dao := gnome.MustNew("main", "Main", gnome.WithMembers(members...))
				gnome.MustNew("council", "Council", gnome.AssignAsSuperCouncil(), gnome.WithSubDAO(dao))
				return dao
			},
			err: "address is not a DAO member: " + member5.String(),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			dao := tc.setup()
			s := newDAOMembersModificationStrategy(tc.newMembers, tc.removeMembers)
			p, _ := gnome.NewProposal(1, s, members[0].Address, dao, "Title")

			// Act
			err := s.Validate(p)

			// Assert
			if tc.err != "" {
				assertError(t, tc.err, err)
			} else {
				assertNoError(t, err)
			}
		})
	}
}

func TestModifyDAOMembersStrategyExecute(t *testing.T) {
	// Arrange
	dao := gnome.MustNew("main", "Main", gnome.WithMembers(
		newTestMember(t, "member1"),
		newTestMember(t, "member2"),
		newTestMember(t, "member3"),
		newTestMember(t, "member4"),
	))
	newMembers := []gnome.Member{
		newTestMember(t, "member5"),
		newTestMember(t, "member6"),
	}
	removeMembers := dao.Members()[1:3]
	s := newDAOMembersModificationStrategy(newMembers, removeMembers)

	// Act
	err := s.Execute(dao)

	// Assert
	assertNoError(t, err)

	if c := len(dao.Members()); c != 4 {
		t.Fatalf("expected DAO to have 4 members, got: %d", c)
	}

	for _, m := range newMembers {
		if !dao.HasMember(m.Address) {
			t.Fatalf("expected member %s to be added to the DAO", m.Address)
		}
	}

	for _, m := range removeMembers {
		if dao.HasMember(m.Address) {
			t.Fatalf("expected member %s to be removed from the DAO", m.Address)
		}
	}
}

func TestSubDAODismissalStrategy(t *testing.T) {
	cases := []struct {
		name string
		dao  *gnome.DAO
		err  string
	}{
		{
			name: "ok",
			dao:  gnome.MustNew("dao", "DAO"),
		},
		{
			name: "no DAO",
			err:  "DAO is required",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			name := StrategyNameSubDAODismissal
			quorum := 0.51
			votingPeriod := time.Hour * 24 * 7
			choices := fmt.Sprintf("%v", []gnome.VoteChoice{
				gnome.ChoiceYes,
				gnome.ChoiceNo,
			})

			// Act
			var s subDAODismissalStrategy
			err := handlePanic(t, func() {
				s = newSubDAODismissalStrategy(tc.dao, proposalIndex{})
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

func TestSubDAODismissalStrategyTally(t *testing.T) {
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
			subDAO := gnome.MustNew("sub", "Sub DAO")
			record := gnome.NewVotingRecord()
			for _, v := range tc.votes {
				record.Add(v)
			}

			s := newSubDAODismissalStrategy(subDAO, proposalIndex{})

			// Act
			choice := s.Tally(nil, *record)

			// Assert
			if choice != tc.choice {
				t.Fatalf("expected tally result choice: '%v', got: '%v'", tc.choice, choice)
			}
		})
	}
}

func TestSubDAODismissalStrategyValidate(t *testing.T) {
	parentDAO := gnome.MustNew("parent", "Parent")
	cases := []struct {
		name  string
		setup func(parent *gnome.DAO) (child *gnome.DAO)
		err   string
	}{
		{
			name: "ok",
			setup: func(dao *gnome.DAO) *gnome.DAO {
				child := gnome.MustNew("child", "Child")
				dao.AddSubDAO(child)
				return child
			},
		},
		{
			name: "dismiss non child DAO",
			setup: func(*gnome.DAO) *gnome.DAO {
				child := gnome.MustNew("child", "Child")
				gnome.MustNew("foo", "Foo", gnome.WithSubDAO(child))
				return child
			},
			err: `the DAO to dismiss must be a first level sub DAO of "` + parentDAO.Name() + `"`,
		},
		{
			name: "parent DAO not found",
			setup: func(*gnome.DAO) *gnome.DAO {
				return gnome.MustNew("child", "Child")
			},
			err: "the DAO to dismiss has no parent DAO",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			childDAO := tc.setup(parentDAO)
			s := newSubDAODismissalStrategy(childDAO, proposalIndex{})
			p, _ := gnome.NewProposal(1, s, testutils.TestAddress("member"), parentDAO, "Dismiss child DAO")

			// Act
			err := s.Validate(p)

			// Assert
			if tc.err != "" {
				assertError(t, tc.err, err)
			} else {
				assertNoError(t, err)
			}
		})
	}
}

func TestSubDAODismissalStrategyExecute(t *testing.T) {
	// Arrange
	var (
		strategy  testStrategy
		proposals proposalIndex
	)

	caller := testutils.TestAddress("caller")

	threeDAO := gnome.MustNew("three", "Three")
	twoDAO := gnome.MustNew("two", "Two")
	oneDAO := gnome.MustNew("one", "One", gnome.WithSubDAO(twoDAO), gnome.WithSubDAO(threeDAO))
	rootDAO := gnome.MustNew("root", "Root", gnome.WithSubDAO(oneDAO))

	p, _ := gnome.NewProposal(1, strategy, caller, rootDAO, "Root")
	proposals.Index(p)

	p, _ = gnome.NewProposal(2, strategy, caller, oneDAO, "One")
	proposals.Index(p)

	p, _ = gnome.NewProposal(3, strategy, caller, twoDAO, "Two")
	proposals.Index(p)

	p, _ = gnome.NewProposal(4, strategy, caller, threeDAO, "Thee")
	proposals.Index(p)

	dismissReason := "Dismissed because of DAO dismissal: " + rootDAO.Name()
	daos := []*gnome.DAO{rootDAO, oneDAO, twoDAO, threeDAO}
	s := newSubDAODismissalStrategy(rootDAO, proposals)

	// Act
	err := s.Execute(nil)

	// Assert
	assertNoError(t, err)

	for _, dao := range daos {
		if !dao.IsLocked() {
			t.Fatalf("expected DAO '%s' to be locked", dao.Title())
		}
	}

	proposals.Iterate(func(p *gnome.Proposal) bool {
		if got := p.Status(); got != gnome.StatusDismissed {
			t.Fatalf("expected proposal '%s' status to be 'dismissed', got: '%s'", p.Title(), got.String())
		}

		if got := p.StatusReason(); got != dismissReason {
			t.Fatalf("expected dismiss reason '%s', got: '%s'", dismissReason, got)
		}
		return false
	})
}

type testStrategy struct{}

func (testStrategy) Name() string                                            { return "test" }
func (testStrategy) Quorum() float64                                         { return 0.51 }
func (testStrategy) VotingPeriod() time.Duration                             { return time.Hour * 24 * 2 }
func (testStrategy) VoteChoices() []gnome.VoteChoice                         { return []gnome.VoteChoice{gnome.ChoiceYes} }
func (s testStrategy) Tally(*gnome.DAO, gnome.VotingRecord) gnome.VoteChoice { return gnome.ChoiceYes }

func newTestMember(t *testing.T, name string) gnome.Member {
	t.Helper()
	return gnome.NewMember(testutils.TestAddress(name))
}
