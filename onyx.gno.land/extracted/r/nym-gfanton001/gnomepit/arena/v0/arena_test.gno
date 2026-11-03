package arena

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
)

const (
	saltA = "0101010101010101010101010101010101010101010101010101010101010101"
	saltB = "0202020202020202020202020202020202020202020202020202020202020202"
)

// reset empties the realm's state between tests; t.Run shares package globals.
func reset() {
	lastID = 0
	chunks = avl.Tree{}
	players = avl.Tree{}
	openList = ""
	retired = false
}

func sealOf(salt, text string) string {
	b, err := hex.DecodeString(salt)
	if err != nil {
		panic(err)
	}
	sum := sha256.Sum256(append(b, text...))
	return hex.EncodeToString(sum[:])
}

// boxOf is s as a box argument, which the page sends in base64.
func boxOf(s string) string {
	return base64.StdEncoding.EncodeToString([]byte(s))
}

func TestChallengeOpensAMatch(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, "deck"), sealOf(saltB, "plan"), boxOf("box"), "")
	uassert.Equal(t, "1", id)

	list := Open(0, 50)
	urequire.Equal(t, 1, len(list))
	c := list[0]
	uassert.Equal(t, "1", c.ID)
	uassert.Equal(t, alice.String(), c.Challenger)
	uassert.Equal(t, "Pickers", c.Clan)
	uassert.Equal(t, "", c.Opponent)
	uassert.Equal(t, c.Posted+604800, c.Expires)
}

func TestChallengeNamesAnOpponent(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	Challenge(cross(cur), "Ironhide", sealOf(saltA, "deck"), sealOf(saltB, "plan"), boxOf("box"), bob)
	uassert.Equal(t, bob.String(), Open(0, 50)[0].Opponent)
	uassert.Equal(t, bob.String(), Matches(alice, 0, 50)[0].Opponent)
}

func TestChallengeRejects(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	seal := sealOf(saltA, "deck")
	cases := []struct {
		name, clan, deckSeal, planSeal, box string
		opponent                            address
		want                                string
	}{
		{"unknown clan", "Elves", seal, seal, boxOf("box"), "", "unknown clan"},
		{"short seal", "Pickers", seal[1:], seal, boxOf("box"), "", "invalid seal"},
		{"uppercase seal", "Pickers", strings.ToUpper(seal), seal, boxOf("box"), "", "invalid seal"},
		{"non-hex seal", "Pickers", seal, "z" + seal[1:], boxOf("box"), "", "invalid seal"},
		{"empty box", "Pickers", seal, seal, "", "", "invalid box"},
		{"long box", "Pickers", seal, seal, boxOf(strings.Repeat("x", 1025)), "", "invalid box"},
		{"bad opponent", "Pickers", seal, seal, boxOf("box"), address("g1nope"), "invalid opponent"},
		{"uppercase opponent", "Pickers", seal, seal, boxOf("box"), address(strings.ToUpper(bob.String())), "invalid opponent"},
	}
	for _, c := range cases {
		uassert.AbortsWithMessage(t, cur, c.want, func() {
			Challenge(cross(cur), c.clan, c.deckSeal, c.planSeal, c.box, c.opponent)
		}, c.name)
	}
	uassert.Equal(t, 0, len(Open(0, 50)))
}

func TestOpenNewestFirstAndUnexpired(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	seal := sealOf(saltA, "deck")
	Challenge(cross(cur), "Pickers", seal, seal, boxOf("box"), "")
	Challenge(cross(cur), "Pickers", seal, seal, boxOf("box"), "")
	testing.SkipHeights(120000) // 600,000 s
	Challenge(cross(cur), "Ironhide", seal, seal, boxOf("box"), "")

	ids := func(list []OpenChallenge) string {
		var out []string
		for _, c := range list {
			out = append(out, c.ID)
		}
		return strings.Join(out, ",")
	}
	uassert.Equal(t, "3,2,1", ids(Open(0, 50)))
	uassert.Equal(t, "2", ids(Open(1, 1)))

	testing.SkipHeights(1000) // the first two are now 605,000 s old
	uassert.Equal(t, "3", ids(Open(0, 50)))
}

func TestOpenLimit(t *testing.T) {
	uassert.PanicsWithMessage(t, nil, "limit must be 1 to 50", func() { Open(0, 0) })
	uassert.PanicsWithMessage(t, nil, "limit must be 1 to 50", func() { Open(0, 51) })
	uassert.PanicsWithMessage(t, nil, "offset must not be negative", func() { Open(-1, 10) })
}

func TestExpiredChallengeLeavesTheBoardBeforeClearing(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SkipHeights(7 * day)
	uassert.Equal(t, 1, len(Open(0, 50)), "a challenge is open until the end of its expiry second")

	testing.SkipHeights(1)
	uassert.Equal(t, 0, len(Open(0, 50)))
	uassert.Equal(t, phaseExpired, Match(id).Phase)
	list := Matches(alice, 0, 50)
	urequire.Equal(t, 1, len(list))
	uassert.Equal(t, phaseExpired, list[0].Phase)
}

func TestClearingAtMostEight(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	for i := 0; i < 10; i++ {
		Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	}
	testing.SkipHeights(7*day + 1)

	Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	uassert.Equal(t, "11,10,9", summaryIDs(Matches(alice, 0, 50)))
	uassert.Equal(t, "[9 10 11]", showIDs(loadPlayer(alice).ids))
	uassert.PanicsWithMessage(t, nil, "unknown match", func() { Match("8") })
	uassert.Equal(t, phaseExpired, Match("9").Phase)

	Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	uassert.Equal(t, "12,11", summaryIDs(Matches(alice, 0, 50)))
	uassert.Equal(t, "[11 12]", showIDs(loadPlayer(alice).ids))
	uassert.Equal(t, 2, len(Open(0, 50)))
}

// A challenge whose match is gone must not block the clearing, or every later Challenge.
func TestClearingSkipsMissingMatch(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	dropMatch(1)
	testing.SkipHeights(7*day + 1)

	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	entries := openEntries(openList)
	urequire.Equal(t, 1, len(entries))
	uassert.Equal(t, id, strconv.Itoa(entries[0].id))
}

func TestBoxText(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	seal := sealOf(saltA, deckA)
	full := boxOf(strings.Repeat("\x00\xff\x07\x80", 26))
	urequire.Equal(t, 140, len(full))
	cases := []struct{ name, box string }{
		{"over 140 characters", strings.Repeat("A", 144)},
		{"141 characters of 104 bytes", full + "\n"},
		{"140 characters of 105 bytes", strings.Repeat("A", 140)},
		{"unpadded", "box"},
		{"outside the alphabet", "b*x1"},
		{"with a newline", "Ym94\n"},
		{"stray low bits", "YR=="},
	}
	for _, c := range cases {
		uassert.AbortsWithMessage(t, cur, "invalid box", func() {
			Challenge(cross(cur), "Pickers", seal, seal, c.box, "")
		}, c.name)
	}

	for _, box := range []string{boxOf("box"), full} {
		id := Challenge(cross(cur), "Pickers", seal, seal, box, "")
		uassert.Equal(t, box, Match(id).Box)
	}
}
