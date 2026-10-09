package arena

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"

	"gno.land/p/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/arena/payout/v0"
)

// An arena is created off chain, by the game server, at a player's request.
// It is described by a spec, a string of fields separated by "|":
//
//	v1|mode|stake|minSeats|maxSeats|lives|seconds|killTarget|creator|created|nonce
//
//	v1|deathmatch|10000000|2|8|3|900|5|g1abc...|1760000000|k3x9
//
// and known by its id, the first 24 hex characters of the SHA-256 of the
// spec. The first player to pay for an arena hands the realm its spec; the
// realm checks it and stores the arena under the id it computes. Nobody can
// change the stake or the rules of an id: a different spec is a different
// id.
//
// created is the server's clock when the arena was proposed. An arena takes
// entries for an hour from then, and its lobby can be closed by anyone after
// that, see ExpireLobby.

// Bounds of a spec, the same as the game server's.
const (
	specVersion = "v1"
	idLen       = 24

	minStake      = 1000000    // ugnot, 1 GNOT
	maxStake      = 1000000000 // ugnot, 1000 GNOT
	minSeconds    = 300        // 5 minutes
	maxSeconds    = 1800       // 30 minutes
	entryWindow   = 3600       // seconds an arena takes entries after it was created
	clockSkew     = 300        // seconds a server clock may run ahead of the chain
	maxNonceLen   = 16
	maxSpecLength = 160

	// feeBps is the house's share of every settled game, for the treasury.
	feeBps = 500
)

// spec is a parsed arena spec.
type spec struct {
	mode       string
	stake      int64
	minSeats   int64
	maxSeats   int64
	lives      int64
	seconds    int64
	killTarget int64
	creator    address
	created    int64
	nonce      string
}

// idOf returns the id of a spec string.
func idOf(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])[:idLen]
}

// parseSpec reads and checks a spec string. It panics on anything the realm
// would not play.
func parseSpec(s string) spec {
	if len(s) > maxSpecLength {
		panic(errInvalidSpec)
	}
	f := strings.Split(s, "|")
	if len(f) != 11 || f[0] != specVersion {
		panic(errInvalidSpec)
	}
	num := func(i int) int64 {
		n, ok := digits(f[i])
		if !ok {
			panic(errInvalidSpec)
		}
		return n
	}
	sp := spec{
		mode:       f[1],
		stake:      num(2),
		minSeats:   num(3),
		maxSeats:   num(4),
		lives:      num(5),
		seconds:    num(6),
		killTarget: num(7),
		creator:    address(f[8]),
		created:    num(9),
		nonce:      f[10],
	}
	if payout.Lookup(sp.mode) == nil {
		panic(errInvalidMode)
	}
	if sp.stake < minStake || sp.stake > maxStake {
		panic(errInvalidStake)
	}
	if sp.minSeats < payout.MinPlayers || sp.minSeats > sp.maxSeats || sp.maxSeats > payout.MaxPlayers {
		panic(errInvalidSeats)
	}
	if sp.lives < payout.MinLives || sp.lives > payout.MaxLives {
		panic(errInvalidLives)
	}
	if sp.seconds < minSeconds || sp.seconds > maxSeconds {
		panic(errInvalidSeconds)
	}
	if sp.killTarget > payout.MaxKillTarget {
		panic(errInvalidKillTarget)
	}
	// A battle royale is won by staying in the air: a kill target would end
	// it before that.
	if sp.mode == payout.ModeBattleRoyale && sp.killTarget != 0 {
		panic(errRoyaleTarget)
	}
	if !validAddress(sp.creator) {
		panic(errInvalidAddress)
	}
	if !validNonce(sp.nonce) {
		panic(errInvalidSpec)
	}
	return sp
}

// validNonce reports whether s is 1 to 16 characters of [a-z0-9].
func validNonce(s string) bool {
	if len(s) == 0 || len(s) > maxNonceLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

// validID reports whether s can be an arena id: 24 lowercase hex characters.
func validID(s string) bool {
	if len(s) != idLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
