package standings

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const (
	arenaV0 = "gno.land/r/nym-gfanton001/gnomepit/arena/v0"
	arenaV1 = "gno.land/r/nym-gfanton001/gnomepit/arena/v1"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
	dave  = testutils.TestAddress("dave")
)

// reset empties the standings and the result log; tests share package globals. It leaves
// the writer list alone.
func reset() {
	players = avl.Tree{}
	ladder = nil
	clans = nil
	results = avl.Tree{}
}

// ownedBy makes a the owner: under gno test, init's deployer address is empty.
func ownedBy(a address) {
	owner = ownable.NewWithAddress(a)
}

// resetWriters leaves the arena the only writer, as init does.
func resetWriters() {
	writerPaths = nil
	writers = avl.Tree{}
	addWriter(arenaV0)
}

// TestInitSeedsTheArena reads the writers init set, so it runs before any test changes them.
func TestInitSeedsTheArena(t *testing.T) {
	uassert.Equal(t, strings.Join([]string{arenaV0}, ","), strings.Join(Writers(), ","))
	uassert.True(t, IsWriter(arenaV0))
	uassert.False(t, IsWriter(arenaV1))
}

func TestRecordRefusesNonWriters(cur realm, t *testing.T) {
	resetWriters()
	ownedBy(alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "not a writer", func() {
		Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	})

	testing.SetRealm(testing.NewCodeRealm(arenaV1))
	uassert.AbortsWithMessage(t, cur, "not a writer", func() {
		Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	RemoveWriter(cross(cur), arenaV0)
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	uassert.AbortsWithMessage(t, cur, "not a writer", func() {
		Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	})
	resetWriters()
}

func TestRecordRefusesBadInput(cur realm, t *testing.T) {
	resetWriters()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	long := strings.Repeat("x", 33)
	cases := []struct {
		name                                 string
		challenger, acceptor                 address
		challengerClan, acceptorClan, result string
		want                                 string
	}{
		{"same player", alice, alice, "Pickers", "Ironhide", "a", "same player"},
		{"unknown result", alice, bob, "Pickers", "Ironhide", "x", "unknown result"},
		{"empty clan", alice, bob, "", "Ironhide", "a", "bad clan name"},
		{"long clan", alice, bob, "Pickers", long, "a", "bad clan name"},
	}
	for _, c := range cases {
		uassert.AbortsWithMessage(t, cur, c.want, func() {
			Record(cross(cur), c.challenger, c.acceptor, c.challengerClan, c.acceptorClan, c.result)
		}, c.name)
	}
}

func TestOwnerCalls(cur realm, t *testing.T) {
	resetWriters()
	ownedBy(alice)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "ownable: caller is not owner", func() { AddWriter(cross(cur), arenaV1) })
	uassert.AbortsWithMessage(t, cur, "ownable: caller is not owner", func() { RemoveWriter(cross(cur), arenaV0) })
	uassert.AbortsWithMessage(t, cur, "ownable: caller is not owner", func() { TransferOwnership(cross(cur), bob) })
	uassert.Equal(t, alice, Owner())

	testing.SetRealm(testing.NewUserRealm(alice))
	TransferOwnership(cross(cur), bob)
	uassert.Equal(t, bob, Owner())
}

func TestAddWriterRefuses(cur realm, t *testing.T) {
	resetWriters()
	ownedBy(alice)
	testing.SetRealm(testing.NewUserRealm(alice))

	tooLong := "gno.land/r/" + strings.Repeat("a", 243) + "/v1"
	for _, p := range []string{"gno.land/p/x/v0", "gno.land/r/x", "gno.land/r/x/v", "gno.land/r/x/vA", "gno.land/r/x#y/v1", "gno.land/r/X/v1", tooLong} {
		uassert.AbortsWithMessage(t, cur, "bad writer path", func() { AddWriter(cross(cur), p) }, p)
	}
	uassert.AbortsWithMessage(t, cur, "already a writer", func() { AddWriter(cross(cur), arenaV0) })
	uassert.AbortsWithMessage(t, cur, "not a writer", func() { RemoveWriter(cross(cur), arenaV1) })

	// The arena holds writer number 1, so 254 more paths fill all 255.
	for i := 1; i <= 254; i++ {
		AddWriter(cross(cur), "gno.land/r/x/v"+strconv.Itoa(i))
	}
	uassert.AbortsWithMessage(t, cur, "too many writers", func() { AddWriter(cross(cur), "gno.land/r/x/v255") })
	resetWriters()
}

func TestReaddedWriterKeepsItsNumber(cur realm, t *testing.T) {
	resetWriters()
	ownedBy(alice)
	testing.SetRealm(testing.NewUserRealm(alice))

	AddWriter(cross(cur), arenaV1)
	RemoveWriter(cross(cur), arenaV0)
	uassert.Equal(t, arenaV1, strings.Join(Writers(), ","))
	AddWriter(cross(cur), arenaV0)
	uassert.Equal(t, arenaV0+","+arenaV1, strings.Join(Writers(), ","))
	resetWriters()
}
