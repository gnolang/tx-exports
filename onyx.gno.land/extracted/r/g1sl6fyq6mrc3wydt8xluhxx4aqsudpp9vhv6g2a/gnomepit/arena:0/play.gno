package arena

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1sl6fyq6mrc3wydt8xluhxx4aqsudpp9vhv6g2a/gnomepit/engine"
)

// Accept answers open challenge id as clan, with deck and the round-1 plan in plain
// text. When the challenge names an opponent, only that address may accept.
func Accept(cur realm, id, clan, deck, plan string) {
	rules := engine.ProofOfConcept()
	n, m := find(rules, id)
	now := time.Now().Unix()
	if m.phase != phaseOpen {
		panic("wrong phase")
	}
	if m.expired(now) {
		panic("challenge expired")
	}
	caller := cur.Previous().Address()
	if m.opponent != "" && caller != m.opponent {
		panic("not the named opponent")
	}
	c := clanNumber(rules, clan)
	if c == 0 {
		panic("unknown clan")
	}
	bits := deckBits(rules, rules.Clans[c-1], deck)
	b := planOf(rules, plan)
	if !legal(rules, stateOf(rules, m), engine.SideB, bits, b) {
		panic("illegal plan")
	}

	m.acceptor = caller
	m.opponent = ""
	join(cur.Previous().IsUser(), caller, n)
	m.clans[1] = c
	m.decks[1] = bits
	m.plans[1] = withPlan(m.plans[1], 1, b)
	m.phase = phaseReveal
	m.deadline = now + moveWindow
	saveMatch(rules, n, m)
	openRemove(n)
	tell("Turn", m.challenger, caller, n, clan+" accepted your challenge. Your move within 24 hours.")
}

// Reveal opens the challenger's sealed plan for the round being played, and on the
// first reveal the sealed deck, then resolves the round. A match that goes on needs
// nextSeal and nextBox for the challenger's next plan; one that ends takes neither.
func Reveal(cur realm, id, deck, deckSalt, plan, planSalt, nextSeal, nextBox string) {
	rules := engine.ProofOfConcept()
	n, m := find(rules, id)
	now := time.Now().Unix()
	caller := cur.Previous().Address()
	guard(cur.Previous().IsUser(), caller, m, n)
	m.checkMove(caller, phaseReveal, m.challenger, now)

	s := stateOf(rules, m)
	first := s.Round == 1
	bits := m.decks[0]
	if first {
		if deck == "" {
			panic("deck required")
		}
		checkSeal(m.deckSeal, deckSalt, deck)
		bits = deckBits(rules, rules.Clans[m.clans[0]-1], deck)
	} else if deck != "" || deckSalt != "" {
		panic("deck already revealed")
	}
	checkSeal(m.seal, planSalt, plan)
	a := planOf(rules, plan)
	if !legal(rules, s, engine.SideA, bits, a) {
		panic("illegal plan")
	}
	o := rules.Resolve(s, a, planAt(m.plans[1], s.Round))
	var box string
	if o.Result == engine.Ongoing {
		if nextSeal == "" {
			panic("next seal required")
		}
		if !validSeal(nextSeal) {
			panic("invalid seal")
		}
		box = boxBytes(nextBox)
	} else if nextSeal != "" || nextBox != "" {
		panic("unexpected next seal")
	}

	if first {
		m.decks[0] = bits
		m.deckSeal = ""
	}
	m.plans[0] = withPlan(m.plans[0], s.Round, a)
	for side, g := range o.State.Gnomes {
		m.hp[s.Round-1][side] = g.HP
		m.carried[side] = engine.Vitals{Vulnerable: g.Vulnerable, Strength: g.Strength}
	}
	m.seal, m.box = nextSeal, box
	if o.Result != engine.Ongoing {
		m.end(resultName(o.Result), reasonOf(o.State))
		saveMatch(rules, n, m)
		rate(rules, m)
		tellEnded(m, n, caller)
		return
	}
	m.phase = phasePlay
	m.deadline = now + moveWindow
	saveMatch(rules, n, m)
	hp := m.hp[s.Round-1]
	tell("Turn", m.acceptor, caller, n, "Round "+strconv.Itoa(s.Round)+" is over: you "+strconv.Itoa(hp[1])+
		" HP, them "+strconv.Itoa(hp[0])+". Your move within 24 hours.")
}

// Play records the acceptor's plan for the round being played.
func Play(cur realm, id, plan string) {
	rules := engine.ProofOfConcept()
	n, m := find(rules, id)
	now := time.Now().Unix()
	caller := cur.Previous().Address()
	guard(cur.Previous().IsUser(), caller, m, n)
	m.checkMove(caller, phasePlay, m.acceptor, now)
	s := stateOf(rules, m)
	b := planOf(rules, plan)
	if !legal(rules, s, engine.SideB, m.decks[1], b) {
		panic("illegal plan")
	}
	m.plans[1] = withPlan(m.plans[1], s.Round, b)
	m.phase = phaseReveal
	m.deadline = now + moveWindow
	saveMatch(rules, n, m)
	tell("Turn", m.challenger, caller, n, clanName(rules, m.clans[1])+" played round "+strconv.Itoa(s.Round)+". Your move within 24 hours.")
}

// Resign withdraws the caller's open challenge, expired or not, deleting it, or concedes
// a running match.
func Resign(cur realm, id string) {
	rules := engine.ProofOfConcept()
	n, m := find(rules, id)
	caller := cur.Previous().Address()
	guard(cur.Previous().IsUser(), caller, m, n)
	switch m.phase {
	case phaseOpen:
		if caller != m.challenger {
			panic("not your challenge")
		}
		openRemove(n)
		forget(n, m.challenger)
	case phaseReveal, phasePlay:
		switch caller {
		case m.challenger:
			m.end("b", "resign")
		case m.acceptor:
			m.end("a", "resign")
		default:
			panic("not a player")
		}
		saveMatch(rules, n, m)
		rate(rules, m)
		tellEnded(m, n, caller)
	default:
		panic("wrong phase")
	}
}

// ClaimForfeit ends a running match whose deadline has passed: the player who had to
// move loses. Any wallet may claim it; a session may claim only a match its wallet plays.
func ClaimForfeit(cur realm, id string) {
	rules := engine.ProofOfConcept()
	n, m := find(rules, id)
	caller := cur.Previous().Address()
	guard(cur.Previous().IsUser(), caller, m, n)
	var result string
	switch m.phase {
	case phaseReveal:
		result = "b"
	case phasePlay:
		result = "a"
	default:
		panic("wrong phase")
	}
	if time.Now().Unix() <= m.deadline {
		panic("deadline not passed")
	}
	m.end(result, "forfeit")
	saveMatch(rules, n, m)
	rate(rules, m)
	tellEnded(m, n, caller)
}

func find(rules *engine.Ruleset, id string) (int, record) {
	n, m, ok := lookup(rules, id)
	if !ok {
		panic("unknown match")
	}
	return n, m
}

// lookup returns the match id names, false when there is none. Only an id's own decimal
// text names it, never "01" or "+1".
func lookup(rules *engine.Ruleset, id string) (int, record, bool) {
	if len(id) == 0 || len(id) > idDigits {
		return 0, record{}, false
	}
	n, err := strconv.Atoi(id)
	if err != nil || strconv.Itoa(n) != id {
		return 0, record{}, false
	}
	m, ok := loadMatch(rules, n)
	return n, m, ok
}

func (m record) checkMove(caller address, phase string, mover address, now int64) {
	if m.phase != phase {
		panic("wrong phase")
	}
	if caller != mover {
		panic("not your move")
	}
	if now > m.deadline {
		panic("deadline passed")
	}
}

func (m *record) end(result, reason string) {
	m.phase = phaseEnded
	m.result = result
	m.reason = reason
	m.deckSeal, m.seal, m.box = "", "", ""
}

// stateOf rebuilds the engine state the next round of m starts from. A round is resolved
// once the challenger's plan for it is stored; the specials of resolved rounds are spent.
func stateOf(rules *engine.Ruleset, m record) engine.State {
	resolved := plansMade(m.plans[0])
	s := rules.Start()
	s.Round = resolved + 1
	for side := range s.Gnomes {
		g := &s.Gnomes[side]
		if resolved > 0 {
			g.HP = m.hp[resolved-1][side]
		}
		g.Vulnerable = m.carried[side].Vulnerable
		g.Strength = m.carried[side].Strength
		for round := 1; round <= resolved; round++ {
			for _, id := range planAt(m.plans[side], round) {
				if rules.Cards[id].Special {
					g.Spent |= uint64(1) << uint(id)
				}
			}
		}
	}
	return s
}

// checkSeal panics unless seal is the sha256 of salt's bytes followed by text.
func checkSeal(seal, salt, text string) {
	if !validSeal(salt) {
		panic("invalid salt")
	}
	b, _ := hex.DecodeString(salt)
	sum := sha256.Sum256(append(b, text...))
	if hex.EncodeToString(sum[:]) != seal {
		panic("seal mismatch")
	}
}

// clanNumber is clan's index in rules plus one, as a record stores it, or 0 when no clan
// has that name.
func clanNumber(rules *engine.Ruleset, clan string) int {
	for i, c := range rules.Clans {
		if c.Name == clan {
			return i + 1
		}
	}
	return 0
}

// clanName is the name of the clan a record stores as n, "" for none.
func clanName(rules *engine.Ruleset, n int) string {
	if n == 0 {
		return ""
	}
	return rules.Clans[n-1].Name
}

// planOf maps comma-separated card names to the engine's ids.
func planOf(rules *engine.Ruleset, text string) engine.Plan {
	p, ok := rules.PlanOf(strings.Split(text, ",")...)
	if !ok {
		panic("unknown card")
	}
	return p
}

// deckBits returns deck as the engine's bit set, panicking unless it is legal for c. A
// card named twice is illegal, so a legal deck text holds exactly the deck's names.
func deckBits(rules *engine.Ruleset, c engine.Clan, deck string) uint64 {
	var bits uint64
	for _, id := range planOf(rules, deck) {
		bit := uint64(1) << uint(id)
		if bits&bit != 0 {
			panic("illegal deck")
		}
		bits |= bit
	}
	if !rules.LegalDeck(c, bits) {
		panic("illegal deck")
	}
	return bits
}

func legal(rules *engine.Ruleset, s engine.State, side engine.Side, deck uint64, p engine.Plan) bool {
	for _, q := range rules.LegalPlans(s, side, deck) {
		if samePlan(p, q) {
			return true
		}
	}
	return false
}

func samePlan(p, q engine.Plan) bool {
	if len(p) != len(q) {
		return false
	}
	for i := range p {
		if p[i] != q[i] {
			return false
		}
	}
	return true
}

func resultName(r engine.Result) string {
	switch r {
	case engine.AWins:
		return "a"
	case engine.BWins:
		return "b"
	case engine.Draw:
		return "draw"
	}
	return ""
}

// reasonOf says why a finished match ended: a gnome at 0 HP or less is a knockout.
func reasonOf(s engine.State) string {
	if s.Gnomes[0].HP <= 0 || s.Gnomes[1].HP <= 0 {
		return "knockout"
	}
	return "hp"
}
