// Package arena holds Gnomehall's online matches. A challenger posts a sealed deck and
// round-1 plan; an acceptor answers face up; the challenger reveals each round with the
// seal of the next, and the shared duel engine checks and resolves every move. A session
// key is bound to the match of the first call it signs: it then acts in no other match and
// posts or accepts nothing more. Calls the wallet signs are never bound.
package arena

import (
	"encoding/base64"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1sl6fyq6mrc3wydt8xluhxx4aqsudpp9vhv6g2a/gnomehall/engine"
)

const (
	moveWindow = 24 * 60 * 60     // seconds a player has for each move
	openWindow = 7 * 24 * 60 * 60 // seconds an open challenge stays on the board
	maxBox     = 104              // bytes
	maxPage    = 50
	maxCleared = 8 // expired challenges one Challenge deletes at most
	idDigits   = 10
)

const (
	phaseOpen    = "open"
	phaseReveal  = "reveal"
	phasePlay    = "play"
	phaseEnded   = "ended"
	phaseExpired = "expired" // reported for an open match past its expiry, never stored
)

var lastID int

// OpenChallenge is an open challenge as the board lists it.
type OpenChallenge struct {
	ID, Challenger, Clan, Opponent string
	Posted, Expires                int64
}

// Challenge posts a challenge for clan with the seals of the challenger's deck and
// round-1 plan, the box holding both, and an opponent who alone may accept, or none.
// It returns the new match's id. It first deletes up to 8 expired challenges, whoever
// posted them.
func Challenge(cur realm, clan, deckSeal, planSeal, box string, opponent address) string {
	rules := engine.ProofOfConcept()
	c := clanNumber(rules, clan)
	if c == 0 {
		panic("unknown clan")
	}
	if !validSeal(deckSeal) || !validSeal(planSeal) {
		panic("invalid seal")
	}
	raw := boxBytes(box)
	if opponent != "" && !canonical(opponent) {
		panic("invalid opponent")
	}
	now := time.Now().Unix()
	for _, id := range openClear(now, maxCleared) {
		if m, ok := loadMatch(rules, id); ok {
			forget(id, m.challenger)
		}
	}

	lastID++
	m := record{
		phase:      phaseOpen,
		deadline:   now + openWindow,
		challenger: cur.Previous().Address(),
		opponent:   opponent,
		deckSeal:   deckSeal,
		seal:       planSeal,
		box:        raw,
	}
	m.clans[0] = c
	join(cur.Previous().IsUser(), m.challenger, lastID)
	saveMatch(rules, lastID, m)
	openAdd(lastID, m.deadline)
	return strconv.Itoa(lastID)
}

// Open lists open, unexpired challenges, newest first: limit of them after skipping
// offset. limit is 1 to 50.
func Open(offset, limit int) []OpenChallenge {
	checkPage(offset, limit)
	rules := engine.ProofOfConcept()
	list := []OpenChallenge{}
	for _, id := range openNewest(time.Now().Unix(), offset, limit) {
		m, ok := loadMatch(rules, id)
		if !ok {
			continue
		}
		list = append(list, OpenChallenge{
			ID:         strconv.Itoa(id),
			Challenger: m.challenger.String(),
			Clan:       clanName(rules, m.clans[0]),
			Opponent:   m.opponent.String(),
			Posted:     m.deadline - openWindow,
			Expires:    m.deadline,
		})
	}
	return list
}

// forget deletes open challenge id and its place among its challenger's matches. Its
// entry on the open list is the caller's to remove.
func forget(id int, challenger address) {
	dropMatch(id)
	p := loadPlayer(challenger)
	p.remove(id)
	savePlayer(challenger, p)
}

func (m record) expired(now int64) bool {
	return m.phase == phaseOpen && now > m.deadline
}

func checkPage(offset, limit int) {
	if offset < 0 {
		panic("offset must not be negative")
	}
	if limit < 1 || limit > maxPage {
		panic("limit must be 1 to 50")
	}
}

// boxBytes decodes a box argument: the standard base64 of 1 to maxBox bytes, in the one
// form that encodes them, so Match returns every box exactly as it was sent.
func boxBytes(text string) string {
	if len(text) == 0 || len(text) > base64.StdEncoding.EncodedLen(maxBox) {
		panic("invalid box")
	}
	raw, err := base64.StdEncoding.DecodeString(text)
	if err != nil || len(raw) > maxBox || base64.StdEncoding.EncodeToString(raw) != text {
		panic("invalid box")
	}
	return string(raw)
}

// canonical accepts a valid address in the lowercase form callers carry. bech32 also
// allows uppercase, which would never equal a caller's address.
func canonical(a address) bool {
	return a.IsValid() && string(a) == strings.ToLower(string(a))
}

// validSeal accepts a sha256 sum in lowercase hex.
func validSeal(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
