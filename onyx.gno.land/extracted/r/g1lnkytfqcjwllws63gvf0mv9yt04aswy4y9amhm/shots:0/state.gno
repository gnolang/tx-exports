package shots

import (
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shootout/v0"
	"gno.land/p/nt/avl/v0"
)

// The game state lives here, at the permanent path, so accepting a new
// implementation changes the rules engine without moving a single pot.
//
// Implementations never hold references into it. They read copies through
// StateRef and write whole values back, so every mutation is performed by
// code declared in this realm and persists here.

var (
	games    = avl.NewTree() // gameKey(id) -> *shootout.Game
	sessions = avl.NewTree() // sessionKey(id, no) -> *shootout.Session
	lastID   uint64
)

func gameKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func sessionKey(id uint64, no int) string {
	s := strconv.Itoa(no)
	for len(s) < 10 {
		s = "0" + s
	}
	return gameKey(id) + "/" + s
}

func getGame(id uint64) (shootout.Game, bool) {
	v := games.Get(gameKey(id))
	if v == nil {
		return shootout.Game{}, false
	}
	return *(v.(*shootout.Game)), true
}

func getSession(id uint64, no int) (shootout.Session, bool) {
	v := sessions.Get(sessionKey(id, no))
	if v == nil {
		return shootout.Session{}, false
	}
	s := *(v.(*shootout.Session))
	s.Kicks = append([]shootout.Kick(nil), s.Kicks...)
	return s, true
}

// StateRef is a permission to read and write the game state, handed to code
// running on this realm's cur. It carries the caller's realm value and
// re-checks it on every operation, so it cannot be stashed (the VM refuses to
// persist a realm value) or replayed after its frame returns.
type StateRef struct {
	rlm realm
}

// Store hands a StateRef to the live implementation, or to a registered
// extension. Any other realm presents its own cur and is refused.
func Store(_ int, rlm realm) *StateRef {
	assertStateAccess(0, rlm)
	return &StateRef{rlm: rlm}
}

// NewGameID allocates the next game id.
func (r *StateRef) NewGameID() uint64 {
	assertStateAccess(0, r.rlm)
	lastID++
	return lastID
}

// Game returns a copy of game id.
func (r *StateRef) Game(id uint64) (shootout.Game, bool) {
	assertStateAccess(0, r.rlm)
	return getGame(id)
}

// PutGame stores g (by value) under g.ID.
func (r *StateRef) PutGame(g shootout.Game) {
	assertStateAccess(0, r.rlm)
	if g.ID == 0 || g.ID > lastID {
		panic("shots: PutGame with an id that was never allocated")
	}
	c := g
	games.Set(gameKey(g.ID), &c)
}

// Session returns a copy of session no of game id, kicks included.
func (r *StateRef) Session(id uint64, no int) (shootout.Session, bool) {
	assertStateAccess(0, r.rlm)
	return getSession(id, no)
}

// PutSession stores s (by value, kicks copied).
func (r *StateRef) PutSession(s shootout.Session) {
	assertStateAccess(0, r.rlm)
	if _, ok := getGame(s.GameID); !ok || s.No <= 0 {
		panic("shots: PutSession for a game or session that does not exist")
	}
	c := s
	c.Kicks = append([]shootout.Kick(nil), s.Kicks...)
	sessions.Set(sessionKey(s.GameID, s.No), &c)
}

// Pay sends amount ugnot from this realm's balance to to.
func (r *StateRef) Pay(to address, amount int64) {
	assertStateAccess(0, r.rlm)
	if amount <= 0 {
		return
	}
	if !to.IsValid() {
		panic("shots: invalid payee address")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, r.rlm)
	bk.SendCoins(r.rlm.Address(), to, chain.NewCoins(chain.NewCoin(Denom, amount)))
}

// assertStateAccess panics unless rlm is a live cur belonging to this realm
// or to a registered extension.
func assertStateAccess(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("shots: realm value is not the caller's live cur")
	}
	if c := rlm.PkgPath(); c != selfPath && !proxy.IsExtension(c) {
		panic("shots: state is reachable only through " + selfPath +
			" or a registered extension, not from " + c)
	}
}
