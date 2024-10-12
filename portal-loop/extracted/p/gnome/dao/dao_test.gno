package dao

import (
	"std"
	"testing"

	"gno.land/p/demo/testutils"

	gnome "gno.land/p/gnome/dao"
)

func TestMember(t *testing.T) {
	cases := []struct {
		name    string
		address std.Address
		roles   []gnome.Role
		output  string
	}{
		{
			name:    "without roles",
			address: std.Address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
			output:  "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",
		},
		{
			name:    "with one role",
			address: std.Address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
			roles:   []gnome.Role{"foo"},
			output:  "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 foo",
		},
		{
			name:    "with two roles",
			address: std.Address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
			roles:   []gnome.Role{"foo", "bar"},
			output:  "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 foo, bar",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			m := gnome.NewMember(tc.address, tc.roles...)

			// Assert
			if got := m.Address; got != tc.address {
				t.Fatalf("expected address %s, got: %s", tc.address, got)
			}

			for i, r := range m.Roles {
				if r != tc.roles[i] {
					t.Fatalf("expected role %s, got: %s", tc.roles[i], r)
				}
			}

			if got := m.String(); got != tc.output {
				t.Fatalf("expected member string output '%s', got: '%s'", tc.output, got)
			}
		})
	}
}

// TODO: Add test cases to check different DAO options
func TestDAO(t *testing.T) {
	// Arrange
	name := "test"
	title := "Test DAO"
	manifest := "This is a test"
	addresses := []std.Address{
		testutils.TestAddress("member1"),
		testutils.TestAddress("member2"),
	}

	// Act
	dao := gnome.MustNew(name, title, gnome.WithManifest(manifest), gnome.WithMembers(
		gnome.NewMember(addresses[0]),
		gnome.NewMember(addresses[1]),
	))

	// Assert
	if got := dao.Name(); got != name {
		t.Fatalf("expected name: %d, got: %d", name, got)
	}

	if got := dao.CreatedAt(); got.IsZero() {
		t.Fatalf("expected a valid creation time, got: '%s'", got.String())
	}

	if got := dao.Title(); got != title {
		t.Fatalf("expected title: '%s', got: '%s'", title, got)
	}

	if got := dao.Manifest(); got != manifest {
		t.Fatalf("expected manifest: '%s', got: '%s'", manifest, got)
	}

	if got := dao.Parent(); got != nil {
		t.Fatalf("expected no parent DAO, got: '%s'", got.Name())
	}

	if c := len(dao.SubDAOs()); c != 0 {
		t.Fatalf("expected no sub DAO nodes, got %d node(s)", c)
	}

	if dao.IsSuperCouncil() {
		t.Fatal("expected DAO not to be a super council")
	}

	if c := len(dao.Members()); c != len(addresses) {
		t.Fatalf("expected %d DAO members, got %d", len(addresses), c)
	}

	for _, addr := range addresses {
		if !dao.HasMember(addr) {
			t.Fatalf("expected member %s to be a member of DAO", addr)
		}

		m, found := dao.GetMember(addr)
		if !found {
			t.Fatalf("expected member %s to be found", addr)
		}

		if m.Address != addr {
			t.Fatalf("expected member to have address %s, got: %s", addr, m.Address)
		}
	}
}

func TestDAOAddMember(t *testing.T) {
	cases := []struct {
		name         string
		member       gnome.Member
		membersCount int
		shouldExist  bool
		setup        func(*gnome.DAO)
	}{
		{
			name:         "ok",
			member:       newTestMember(t, "member"),
			membersCount: 1,
			shouldExist:  true,
		},
		{
			name:         "existing",
			member:       newTestMember(t, "member"),
			membersCount: 2,
			shouldExist:  true,
			setup: func(dao *gnome.DAO) {
				dao.AddMember(newTestMember(t, "member2"))
			},
		},
		{
			name:         "duplicate",
			member:       newTestMember(t, "member"),
			membersCount: 2,
			shouldExist:  true,
			setup: func(dao *gnome.DAO) {
				dao.AddMember(newTestMember(t, "member"))
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			dao := gnome.MustNew("test", "Test")

			if tc.setup != nil {
				tc.setup(dao)
			}

			// Act
			dao.AddMember(tc.member)

			// Assert
			if got := dao.HasMember(tc.member.Address); got != tc.shouldExist {
				t.Fatalf("expected has member call to return %v, got: %v", tc.shouldExist, got)
			}

			m, found := dao.GetMember(tc.member.Address)
			if found != tc.shouldExist {
				t.Fatalf("expected member getter to return %v, got: %v", tc.shouldExist, found)
			}

			if tc.shouldExist && m.Address != tc.member.Address {
				t.Fatalf("expected added member to have adderss %s, got: %s", tc.member, m)
			}

			members := dao.Members()
			if c := len(members); c != tc.membersCount {
				t.Fatalf("expected %d member(s), got: %d", tc.membersCount, c)
			}

			if len(members) > 0 {
				m = members[len(members)-1]
				if m.Address != tc.member.Address {
					t.Fatalf("expected last added member address: %s, got: %s", tc.member.Address, m.Address)
				}
			}
		})
	}
}

func TestDAORemoveMember(t *testing.T) {
	cases := []struct {
		name   string
		member gnome.Member
		setup  func(*gnome.DAO)
		result bool
	}{
		{
			name:   "ok",
			member: newTestMember(t, "member"),
			result: true,
			setup: func(dao *gnome.DAO) {
				dao.AddMember(newTestMember(t, "member"))
			},
		},
		{
			name:   "missing",
			member: newTestMember(t, "member"),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			dao := gnome.MustNew("test", "Test")

			if tc.setup != nil {
				tc.setup(dao)
			}

			// Act
			result := dao.RemoveMember(tc.member.Address)

			// Assert
			if result != tc.result {
				t.Fatalf("expected result to be %v, got: %v", tc.result, result)
			}

			if dao.HasMember(tc.member.Address) {
				t.Fatal("member shouldn't exist")
			}

			if _, found := dao.GetMember(tc.member.Address); found {
				t.Fatal("expected member getter to return false")
			}

			if c := len(dao.Members()); c != 0 {
				t.Fatalf("expected no DAO members, got: %d", c)
			}
		})
	}
}

func TestDAOAddSubDAO(t *testing.T) {
	cases := []struct {
		name, path  string
		children    int
		dao, subDAO *gnome.DAO
		result      bool
		setup       func(*gnome.DAO)
	}{
		{
			name:     "ok",
			dao:      gnome.MustNew("main", "Main"),
			subDAO:   gnome.MustNew("foo", "Foo"),
			children: 1,
			path:     "main/foo",
			result:   true,
		},
		{
			name: "with children",
			dao: gnome.MustNew(
				"main",
				"Main",
				gnome.WithSubDAO(gnome.MustNew("bar", "Bar")),
			),
			subDAO:   gnome.MustNew("foo", "Foo"),
			children: 2,
			path:     "main/foo",
			result:   true,
		},
		{
			name: "duplicate",
			dao: gnome.MustNew(
				"main",
				"Main",
				gnome.WithSubDAO(gnome.MustNew("foo", "Foo")),
			),
			subDAO: gnome.MustNew("foo", "Foo"),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			result := tc.dao.AddSubDAO(tc.subDAO)

			// Assert
			if result != tc.result {
				t.Fatalf("expected result to be %v, got: %v", tc.result, result)
			}

			if result {
				if got := tc.subDAO.Path(); got != tc.path {
					t.Fatalf("expected path to be '%s', got: '%s'", tc.path, got)
				}

				if c := len(tc.dao.SubDAOs()); c != tc.children {
					t.Fatalf("expected %d sub DAO node(s), got %d node(s)", tc.children, c)
				}
			}
		})
	}
}

func TestDAORemoveSubDAO(t *testing.T) {
	cases := []struct {
		name, subName string
		children      int
		subDAO        *gnome.DAO
		result        bool
	}{
		{
			name: "ok",
			subDAO: gnome.MustNew(
				"main",
				"Main",
				gnome.WithSubDAO(gnome.MustNew("foo", "Foo")),
			),
			subName: "foo",
			result:  true,
		},
		{
			name: "with children",
			subDAO: gnome.MustNew(
				"main",
				"Main",
				gnome.WithSubDAO(gnome.MustNew("foo", "Foo")),
				gnome.WithSubDAO(gnome.MustNew("bar", "Bar")),
			),
			subName:  "foo",
			children: 1,
			result:   true,
		},
		{
			name:    "missing",
			subName: "foo",
			subDAO:  gnome.MustNew("main", "Main"),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			result := tc.subDAO.RemoveSubDAO(tc.subName)

			// Assert
			if result != tc.result {
				t.Fatalf("expected result to be %v, got: %v", tc.result, result)
			}

			if result {
				if c := len(tc.subDAO.SubDAOs()); c != tc.children {
					t.Fatalf("expected %d sub DAO node(s), got %d node(s)", tc.children, c)
				}
			}
		})
	}
}

func TestDAOTree(t *testing.T) {
	daoA1 := gnome.MustNew("a1", "A1")
	daoA2 := gnome.MustNew("a2", "A2")
	daoA := gnome.MustNew("a", "A", gnome.WithSubDAO(daoA1), gnome.WithSubDAO(daoA2))
	daoB1 := gnome.MustNew("b1", "B1")
	daoB := gnome.MustNew("b", "B", gnome.WithSubDAO(daoB1))
	dao := gnome.MustNew("main", "Main", gnome.WithSubDAO(daoA), gnome.WithSubDAO(daoB))

	cases := []struct {
		name, path string
		dao        *gnome.DAO
	}{
		{
			name: "root",
			path: "main",
			dao:  dao,
		},
		{
			name: "path a",
			path: "main/a",
			dao:  daoA,
		},
		{
			name: "path a1",
			path: "main/a/a1",
			dao:  daoA1,
		},
		{
			name: "path a2",
			path: "main/a/a2",
			dao:  daoA2,
		},
		{
			name: "path b",
			path: "main/b",
			dao:  daoB,
		},
		{
			name: "path b1",
			path: "main/b/b1",
			dao:  daoB1,
		},
		{
			name: "invalid",
			path: "foo",
		},
		{
			name: "invalid sub path",
			path: "foo/bar",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			subDAO, found := dao.GetDAO(tc.path)

			// Assert
			if subDAO != tc.dao {
				if !found {
					t.Fatalf("DAO for path '%s' not found", tc.path)
				} else {
					t.Fatalf("unexpected DAO for path '%s': '%s'", tc.path, subDAO.Name())
				}
			}

			if found && subDAO.Path() != tc.path {
				t.Fatalf("expected DAO to return path '%s': got '%s'", tc.path, subDAO.Path())
			}
		})
	}
}

func newTestMember(t *testing.T, name string) gnome.Member {
	t.Helper()
	return gnome.NewMember(testutils.TestAddress(name))
}
