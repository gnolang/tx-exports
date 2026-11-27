package flag

import (
	"errors"
	"strings"
)

// ErrNoPlayer is returned when a caller cannot be tied to a player.
var ErrNoPlayer = errors.New("flag: deploy your solution under gno.land/r/<your-g1-address>/ so the hall knows who you are")

// Caller is the part of a realm value Player needs. Pass cur.Previous().
type Caller interface {
	Address() address
	PkgPath() string
}

// Player returns the player credited for a call made by caller, which must
// be the previous realm of the challenge's crossing function
// (cur.Previous()).
//
// A user calling directly is credited as themselves. A realm is credited
// to the owner of its namespace, so a solution deployed at
// gno.land/r/<g1address>/... earns points for <g1address>. Namespaces are
// enforced by the chain, so nobody can deploy under your address.
func Player(caller Caller) (address, error) {
	path := caller.PkgPath()
	if path == "" {
		return caller.Address(), nil
	}
	return namespaceOwner(path)
}

// namespaceOwner extracts the address from "<domain>/<r|e>/<g1...>/...".
func namespaceOwner(path string) (address, error) {
	parts := strings.Split(path, "/")
	if len(parts) < 4 || (parts[1] != "r" && parts[1] != "e") {
		return "", ErrNoPlayer
	}
	addr := address(parts[2])
	if !addr.IsValid() {
		return "", ErrNoPlayer
	}
	return addr, nil
}

// MustPlayer is Player that panics with ErrNoPlayer.
func MustPlayer(caller Caller) address {
	p, err := Player(caller)
	if err != nil {
		panic(err)
	}
	return p
}
