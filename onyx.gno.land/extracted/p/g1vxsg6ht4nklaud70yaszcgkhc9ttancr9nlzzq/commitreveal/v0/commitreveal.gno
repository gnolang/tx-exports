// Package commitreveal runs the commit-reveal lifecycle for any sealed choice: a commit window
// in which participants submit only a hash, then a reveal window in which they open it with the
// value and salt. Games with secret picks, sealed-bid auctions and private votes can import it
// instead of writing window checks, hashing and reveal tracking by hand.
//
// A Session holds no coins and no global state. The importing realm stores the session (for
// example inside its own round struct), passes the block time to every call, and decides what
// the revealed values mean: who wins, who pays, who forfeits.
//
//	s := commitreveal.New(now, 3600, 3600)
//	err := s.Commit(now, caller, hash)          // hash = commitreveal.Hash(value, salt), made off-chain
//	err = s.Reveal(now, caller, value, salt)    // in the reveal window
//	for _, o := range s.Revealed() { ... }      // opened values, in commit order
//	late := s.Unrevealed()                      // committed but never opened
package commitreveal

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"

	"gno.land/p/nt/avl/v0"
)

// Phase of a session at a point in time.
type Phase int

const (
	CommitPhase Phase = iota // commits are accepted
	RevealPhase              // reveals are accepted
	ClosedPhase              // both windows are over
)

var (
	ErrCommitClosed     = errors.New("commit window closed")
	ErrBadHash          = errors.New("commit must be 64 hex chars")
	ErrAlreadyCommitted = errors.New("already committed")
	ErrNotRevealWindow  = errors.New("not in reveal window")
	ErrNotCommitted     = errors.New("not a player in this session")
	ErrAlreadyRevealed  = errors.New("already revealed")
	ErrMismatch         = errors.New("reveal does not match commit")
)

// Hash returns hex(sha256("<value>:<salt>")), the value a participant commits.
// Clients compute it off-chain so the value never appears on chain before the reveal.
func Hash(value, salt string) string {
	sum := sha256.Sum256([]byte(value + ":" + salt))
	return hex.EncodeToString(sum[:])
}

// Verify reports whether value and salt open the given commit hash.
func Verify(hash, value, salt string) bool {
	return Hash(value, salt) == hash
}

// Opened is one revealed value.
type Opened struct {
	Who   address
	Value string
}

type entry struct {
	hash     string
	revealed bool
	value    string
}

// Session is one commit-reveal run. Times are Unix seconds (use the block time).
type Session struct {
	CommitEnd int64 // commits are accepted while now < CommitEnd
	RevealEnd int64 // reveals are accepted while CommitEnd <= now < RevealEnd

	order   []address // commit order
	entries *avl.Tree // address -> *entry
}

// New starts a session at now with a commit window and then a reveal window, in seconds.
func New(now, commitSecs, revealSecs int64) *Session {
	if commitSecs <= 0 || revealSecs <= 0 {
		panic("commitreveal: windows must be positive")
	}
	return &Session{
		CommitEnd: now + commitSecs,
		RevealEnd: now + commitSecs + revealSecs,
		entries:   avl.NewTree(),
	}
}

// Phase returns the session's phase at time now.
func (s *Session) Phase(now int64) Phase {
	switch {
	case now < s.CommitEnd:
		return CommitPhase
	case now < s.RevealEnd:
		return RevealPhase
	default:
		return ClosedPhase
	}
}

// Commit records who's hash during the commit window. Each address commits once.
func (s *Session) Commit(now int64, who address, hash string) error {
	if now >= s.CommitEnd {
		return ErrCommitClosed
	}
	if !isHex64(hash) {
		return ErrBadHash
	}
	if s.entries.Has(who.String()) {
		return ErrAlreadyCommitted
	}
	s.entries.Set(who.String(), &entry{hash: hash})
	s.order = append(s.order, who)
	return nil
}

// Reveal opens who's commit with value and salt during the reveal window.
func (s *Session) Reveal(now int64, who address, value, salt string) error {
	if now < s.CommitEnd || now >= s.RevealEnd {
		return ErrNotRevealWindow
	}
	e := s.get(who)
	if e == nil {
		return ErrNotCommitted
	}
	if e.revealed {
		return ErrAlreadyRevealed
	}
	if !Verify(e.hash, value, salt) {
		return ErrMismatch
	}
	e.revealed = true
	e.value = value
	return nil
}

// Has reports whether who has committed.
func (s *Session) Has(who address) bool { return s.entries.Has(who.String()) }

// Count is the number of commits.
func (s *Session) Count() int { return len(s.order) }

// IsRevealed reports whether who has opened their commit.
func (s *Session) IsRevealed(who address) bool {
	e := s.get(who)
	return e != nil && e.revealed
}

// Value returns who's revealed value; ok is false until they reveal.
func (s *Session) Value(who address) (value string, ok bool) {
	e := s.get(who)
	if e == nil || !e.revealed {
		return "", false
	}
	return e.value, true
}

// Players returns every committed address in commit order (a copy).
func (s *Session) Players() []address {
	out := make([]address, len(s.order))
	copy(out, s.order)
	return out
}

// Revealed returns the opened values in commit order.
func (s *Session) Revealed() []Opened {
	var out []Opened
	for _, who := range s.order {
		if e := s.get(who); e.revealed {
			out = append(out, Opened{Who: who, Value: e.value})
		}
	}
	return out
}

// Unrevealed returns the addresses that committed but have not revealed, in commit order.
// After the reveal window these are the participants who forfeited their reveal.
func (s *Session) Unrevealed() []address {
	var out []address
	for _, who := range s.order {
		if !s.get(who).revealed {
			out = append(out, who)
		}
	}
	return out
}

func (s *Session) get(who address) *entry {
	v := s.entries.Get(who.String())
	if v == nil {
		return nil
	}
	return v.(*entry)
}

func isHex64(h string) bool {
	if len(h) != 64 {
		return false
	}
	for _, c := range h {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}
