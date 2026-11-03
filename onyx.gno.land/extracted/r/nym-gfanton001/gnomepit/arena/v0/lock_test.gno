package arena

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	keyOne   = testutils.TestAddress("key one")
	keyTwo   = testutils.TestAddress("key two")
	keyThree = testutils.TestAddress("key three")
)

// showLocks lists locks as key:match:expiry, naming the test keys.
func showLocks(locks []sessionLock) string {
	names := map[address]string{keyOne: "one", keyTwo: "two", keyThree: "three"}
	var out []string
	for _, l := range locks {
		out = append(out, names[l.session]+":"+strconv.Itoa(l.id)+":"+strconv.FormatInt(l.expires, 10))
	}
	return strings.Join(out, " ")
}

func TestUnlockedSessionLocks(t *testing.T) {
	for _, opening := range []bool{true, false} {
		locks, changed, refusal := lockSession(nil, keyOne, 2000, 3, opening, 1000)
		uassert.Equal(t, "", refusal)
		uassert.True(t, changed)
		uassert.Equal(t, "one:3:2000", showLocks(locks))
	}
	locks, changed, refusal := lockSession([]sessionLock{{keyTwo, 4, 2000}}, keyOne, 2000, 3, false, 1000)
	uassert.Equal(t, "", refusal)
	uassert.True(t, changed)
	uassert.Equal(t, "two:4:2000 one:3:2000", showLocks(locks))
}

func TestLockedSessionRefusedElsewhere(t *testing.T) {
	locked := []sessionLock{{keyOne, 3, 2000}}
	_, _, refusal := lockSession(locked, keyOne, 2000, 5, false, 1000)
	uassert.Equal(t, "session locked to match 3", refusal)

	locks, changed, refusal := lockSession(locked, keyOne, 2000, 3, false, 1000)
	uassert.Equal(t, "", refusal)
	uassert.False(t, changed)
	uassert.Equal(t, "one:3:2000", showLocks(locks))
}

func TestLockedSessionCannotOpen(t *testing.T) {
	locked := []sessionLock{{keyOne, 3, 2000}}
	// Match 3 itself is refused too: a session cannot accept the challenge it posted.
	for _, id := range []int{3, 7} {
		_, _, refusal := lockSession(locked, keyOne, 2000, id, true, 1000)
		uassert.Equal(t, "session locked to match 3", refusal, strconv.Itoa(id))
	}
}

func TestExpiredLockDropped(t *testing.T) {
	locks := []sessionLock{{keyOne, 3, 1000}, {keyTwo, 4, 1001}}
	got, changed, refusal := lockSession(locks, keyThree, 2000, 5, true, 1000)
	uassert.Equal(t, "", refusal)
	// One lock dropped and one added keep the count, and still change the list.
	uassert.True(t, changed)
	uassert.Equal(t, "two:4:1001 three:5:2000", showLocks(got))

	got, changed, refusal = lockSession(locks, keyTwo, 1001, 4, false, 1000)
	uassert.Equal(t, "", refusal)
	uassert.True(t, changed)
	uassert.Equal(t, "two:4:1001", showLocks(got))
}

func TestLockWithoutExpiry(t *testing.T) {
	const later = int64(2_000_000_000)
	locks := []sessionLock{{keyOne, 3, 0}}
	got, _, refusal := lockSession(locks, keyTwo, 0, 4, true, later)
	uassert.Equal(t, "", refusal)
	uassert.Equal(t, "one:3:0 two:4:0", showLocks(got))

	_, _, refusal = lockSession(got, keyOne, 0, 5, false, later)
	uassert.Equal(t, "session locked to match 3", refusal)
}

func TestReusedKeyStartsUnlocked(t *testing.T) {
	locks := []sessionLock{{keyOne, 3, 2000}, {keyTwo, 4, 2000}}
	got, changed, refusal := lockSession(locks, keyOne, 2500, 5, true, 1000)
	uassert.Equal(t, "", refusal)
	uassert.True(t, changed)
	uassert.Equal(t, "two:4:2000 one:5:2500", showLocks(got))
}

// This pins the flag guard saves the player record on: a move in the session's own match
// changes nothing, so it writes nothing.
func TestLockReportsNoChangeInOwnMatch(t *testing.T) {
	p := playerRecord{ids: []int{3, 4}, locks: []sessionLock{{keyOne, 3, 2000}, {keyTwo, 4, 2000}}}
	uassert.False(t, p.lock(keyOne, 2000, 3, false, 1000))
	uassert.Equal(t, "one:3:2000 two:4:2000", showLocks(p.locks))

	uassert.True(t, p.lock(keyThree, 2000, 5, true, 1000))
	uassert.Equal(t, "one:3:2000 two:4:2000 three:5:2000", showLocks(p.locks))

	uassert.PanicsWithMessage(t, nil, "session locked to match 3", func() { p.lock(keyOne, 2000, 4, false, 1000) })
}

func TestLocksQuery(cur realm, t *testing.T) {
	reset()
	p := loadPlayer(alice)
	p.add(3)
	p.locks = []sessionLock{{keyOne, 3, 2000}, {keyTwo, 12, 0}}
	savePlayer(alice, p)

	got := Locks(alice)
	urequire.Equal(t, 2, len(got))
	uassert.Equal(t, keyOne.String(), got[0].Session)
	uassert.Equal(t, "3", got[0].Match)
	uassert.Equal(t, int64(2000), got[0].Expires)
	uassert.Equal(t, keyTwo.String(), got[1].Session)
	uassert.Equal(t, "12", got[1].Match)
	uassert.Equal(t, int64(0), got[1].Expires)
	uassert.Equal(t, 0, len(Locks(bob)))
}
