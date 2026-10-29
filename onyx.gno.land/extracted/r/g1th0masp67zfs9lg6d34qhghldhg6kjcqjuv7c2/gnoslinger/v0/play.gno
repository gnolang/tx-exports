package gnoslinger

import (
	"chain/runtime"
	enchex "encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/cards/v0"
	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/engine/v0"
	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"
)

// Commit seals the caller's plan for the given turn, the one in progress,
// and returns the game revision (a commit meant for another turn, say one
// still on its way when time was called, is refused: its hash, which covers
// the turn, could never be revealed in this one, and it would take the
// seat's commit). hash is PlanHash of a salt and the plan, which a Reveal shows
// once every character still in the fight committed; locked is the salt
// and plan timelocked to the turn's LockRound (at most MaxLocked bytes,
// required: encrypting needs no drand node), which anyone can open and
// reveal from then if the player does not. When this commit is the last one the turn waits for, the game
// moves on to the reveals.
func Commit(cur realm, id string, turn int, hash string, locked string) int {
	assertNoSend()
	caller := cur.Previous().Address()
	g := getGame(id)
	if turn != g.Turn {
		panic("gnoslinger: turn " + strconv.Itoa(turn) + " is not the turn in progress")
	}
	if g.Phase != PhasePlanning {
		panic("gnoslinger: game is not accepting plans")
	}
	g.assertInTime()
	p := g.mustSeat(caller)
	if g.State.Chars[p].Status != engine.Alive {
		panic("gnoslinger: your character is out of the fight")
	}
	if g.committed(p) {
		panic("gnoslinger: plan already submitted for this turn")
	}
	if !isHex(hash, 64, 64) {
		panic("gnoslinger: the hash must be 64 hex characters")
	}
	if locked == "" {
		panic("gnoslinger: a commit needs its timelocked plan")
	}
	if len(locked) > MaxLocked {
		panic("gnoslinger: the timelocked plan is over " + strconv.Itoa(MaxLocked) + " bytes")
	}
	g.Commits[p] = Sealed{Hash: hash, Locked: locked}
	emit("PlanCommitted", "id", id, "turn", strconv.Itoa(g.Turn), "player", caller.String(), "seat", strconv.Itoa(p))
	progress(cur, g)
	save(g)
	return g.Rev
}

// Reveal puts a seat's salt and plan for the given turn on chain and
// returns the game revision. Anyone may send it while the game collects the
// reveals: the salt and plan must match the seat's commit (PlanHash). The
// last seat to commit may also reveal straight away, without committing:
// the others' plans are already fixed by their hashes, so its plan in clear
// helps nobody; that is only accepted from the seat itself, before the
// deadline, once every other character still in the fight committed (a
// refused transaction still shows its plan). The plan is a comma-separated
// list of "<card><f|b>[:<choice>]" entries, e.g. "1f:ahead_left,2f:ahead,3f";
// an empty string passes. The reveal that completes the turn resolves it in
// this same transaction and the next turn starts.
func Reveal(cur realm, id string, turn int, seat int, salt string, plan string) int {
	assertNoSend()
	caller := cur.Previous().Address()
	g := getGame(id)
	if turn != g.Turn {
		panic("gnoslinger: turn " + strconv.Itoa(turn) + " is not the turn in progress")
	}
	if seat < 0 || seat >= g.seats() {
		panic("gnoslinger: there is no seat " + strconv.Itoa(seat) + " in this game")
	}
	switch g.Phase {
	case PhaseRevealing:
		if g.Revealed[seat] {
			panic("gnoslinger: that plan is already revealed")
		}
		revealSeat(g, seat, salt, plan, caller)
	case PhasePlanning:
		// The last commit, in clear.
		g.assertInTime()
		if g.mustSeat(caller) != seat {
			panic("gnoslinger: only its player may reveal a plan before every plan is committed")
		}
		if g.State.Chars[seat].Status != engine.Alive {
			panic("gnoslinger: your character is out of the fight")
		}
		if g.committed(seat) {
			panic("gnoslinger: plan already submitted for this turn")
		}
		for p := range g.Players {
			if p != seat && g.State.Chars[p].Status == engine.Alive && !g.committed(p) {
				panic("gnoslinger: only the last plan to commit may be revealed at once")
			}
		}
		storePlan(g, seat, salt, plan, caller)
	default:
		panic("gnoslinger: game is not accepting plans")
	}
	progress(cur, g)
	save(g)
	return g.Rev
}

// RevealMany reveals several seats of the given turn in one transaction,
// as Reveal does each, in the order given: what an opener of the
// timelocked plans sends. seats, salts and plans are lists separated by
// ";", of the same length (a plan string never holds a ";", an empty plan
// is an empty field). A seat already revealed is skipped (its player's own
// reveal landed first), and so is one whose salt and plan do not match its
// commit or whose plan is not valid (event PlanUnopened): the opener
// cannot check that before opening, and one bad timelocked plan must not
// keep the others back; that seat stays unrevealed, for the claim.
func RevealMany(cur realm, id string, turn int, seats string, salts string, plans string) int {
	assertNoSend()
	caller := cur.Previous().Address()
	g := getGame(id)
	if turn != g.Turn {
		panic("gnoslinger: turn " + strconv.Itoa(turn) + " is not the turn in progress")
	}
	if g.Phase != PhaseRevealing {
		panic("gnoslinger: game is not collecting the reveals")
	}
	ss, sa, pl := strings.Split(seats, ";"), strings.Split(salts, ";"), strings.Split(plans, ";")
	if len(sa) != len(ss) || len(pl) != len(ss) {
		panic("gnoslinger: seats, salts and plans must list as many entries")
	}
	for i, s := range ss {
		seat, err := strconv.Atoi(s)
		if err != nil || seat < 0 || seat >= g.seats() {
			panic("gnoslinger: there is no seat " + s + " in this game")
		}
		if g.Revealed[seat] {
			continue
		}
		if why := checkReveal(g, seat, sa[i], pl[i]); why != "" {
			emit("PlanUnopened", "id", g.ID, "turn", strconv.Itoa(g.Turn), "seat", s, "reason", why)
			continue
		}
		revealSeat(g, seat, sa[i], pl[i], caller)
	}
	progress(cur, g)
	save(g)
	return g.Rev
}

// revealSeat checks a committed seat's salt and plan against its hash and
// stores them, clearing the commit.
func revealSeat(g *Game, seat int, salt, plan string, by address) {
	if why := checkReveal(g, seat, salt, plan); why != "" {
		panic("gnoslinger: " + why)
	}
	storePlan(g, seat, salt, plan, by)
}

// checkReveal tells why a committed seat's salt and plan cannot be
// revealed, "" if they can.
func checkReveal(g *Game, seat int, salt, plan string) string {
	if g.Commits[seat].Hash == "" {
		return "seat " + strconv.Itoa(seat) + " has no plan committed"
	}
	if PlanHash(g.ID, g.Turn, seat, salt, plan) != g.Commits[seat].Hash {
		return "the salt and plan do not match seat " + strconv.Itoa(seat) + "'s commit"
	}
	if _, why := checkPlan(g, seat, salt, plan); why != "" {
		return why
	}
	return ""
}

// checkPlan parses and validates a seat's salt and plan; why is "" when
// they are fine.
func checkPlan(g *Game, seat int, salt, plan string) (pl engine.Plan, why string) {
	if !isHex(salt, 1, MaxSalt) {
		return nil, "the salt must be 1 to " + strconv.Itoa(MaxSalt) + " hex characters"
	}
	pl, err := engine.ParsePlan(plan)
	if err != nil {
		return nil, err.Error()
	}
	if err := pl.Validate(g.State.Chars[seat]); err != nil {
		return nil, err.Error()
	}
	for _, a := range pl {
		if a.Ground > 0 && !groundExists(g.State, a.Ground) {
			return nil, "there is no such weapon on the ground"
		}
		if a.Target >= g.seats() {
			return nil, "there is no character @" + strconv.Itoa(a.Target) + " in this game"
		}
		if a.Target == seat {
			return nil, "you cannot " + a.Opt + " at your own character"
		}
	}
	return pl, ""
}

// storePlan validates a seat's plan and records it as revealed, clearing
// its commit (whose storage deposit goes back to the caller).
func storePlan(g *Game, seat int, salt, plan string, by address) {
	pl, why := checkPlan(g, seat, salt, plan)
	if why != "" {
		panic("gnoslinger: " + why)
	}
	// Target-status flags for this turn, set whether or not the actions
	// end up executing ([H12]).
	g.State.Chars[seat].PlayedFoot = pl.PlayedFoot()
	g.State.Chars[seat].PlayedRun = pl.Has(cards.Run)
	g.Plans[seat] = pl.String()
	g.Salts[seat] = salt
	g.Revealed[seat] = true
	g.Missed[seat] = 0
	g.Commits[seat] = Sealed{}
	emit("PlanRevealed", "id", g.ID, "turn", strconv.Itoa(g.Turn), "seat", strconv.Itoa(seat), "by", by.String())
}

// isHex reports whether s is min to max lowercase hex characters.
func isHex(s string, min, max int) bool {
	if len(s) < min || len(s) > max {
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

// progress moves the turn on as far as it can: it passes the players who
// cannot play anything (a carried delay of 5 or more leaves no time
// points, rule 7.3: there is nothing to wait for from them), goes on to
// the reveals once every character in the fight committed, and resolves
// the turn once every plan is in; when nobody is left to wait for in the
// next turn either, that turn resolves at once, and so on.
func progress(cur realm, g *Game) {
	for {
		if g.Phase == PhasePlanning {
			for p := range g.Players {
				c := &g.State.Chars[p]
				if c.Status != engine.Alive || g.committed(p) || g.State.Budget(p) > 0 {
					continue
				}
				c.PlayedFoot = false
				c.PlayedRun = false
				g.Plans[p] = ""
				g.Revealed[p] = true
				emit("PlanPassed", "id", g.ID, "turn", strconv.Itoa(g.Turn), "seat", strconv.Itoa(p))
			}
			if !g.allCommitted() {
				return
			}
			g.Phase = PhaseRevealing
			emit("AllCommitted", "id", g.ID, "turn", strconv.Itoa(g.Turn))
			g.notifyRevealDue()
		}
		if g.Phase != PhaseRevealing || !g.allRevealed() {
			return
		}
		turn := g.Turn
		seed := resolveTurn(cur, g)
		emit("TurnResolved", "id", g.ID, "turn", strconv.Itoa(turn), "rev", strconv.Itoa(g.Rev+1), "seed", seed)
		g.notifyPlanDue()
	}
}

// resolveTurn plays the seats' plans with the result deck shuffled from
// this turn's seed, stores the result and advances the game. It returns the
// seed in hex.
func resolveTurn(cur realm, g *Game) string {
	n := g.seats()
	// The salts make the seed unknown to every player when it commits, the
	// block keeps the outcome unknown to the last one to reveal.
	parts := append([]string{realmPath, g.ID, strconv.Itoa(g.Turn)}, g.Salts...)
	parts = append(parts, g.Plans...)
	parts = append(parts, strconv.FormatInt(runtime.ChainHeight(), 10), strconv.FormatInt(time.Now().UnixNano(), 10))
	seed := engine.Seed(parts...)
	plans := make([]engine.Plan, n)
	for i, s := range g.Plans {
		pl, err := engine.ParsePlan(s)
		if err != nil {
			panic("gnoslinger: stored plan is invalid: " + err.Error())
		}
		plans[i] = pl
	}
	// From a copy: the live state may share the characters with what the
	// engine returns (see engine.CloneChars).
	start := engine.CloneChars(g.State.Chars)
	ground := engine.EncodeGround(g.State.Ground)
	deck := engine.NewDeck(seed)
	st, evs := engine.Resolve(hex.A, g.State, plans, deck)
	st, endEvs := engine.EndTurn(st)
	evs = append(evs, endEvs...)
	if g.Turn >= g.MaxTurns && engine.AliveCount(st) > 1 { // the end-of-showdown SERIOUS wound check (14.5)
		st, endEvs = engine.EndShowdown(st, deck)
		evs = append(evs, endEvs...)
	}
	// Victory points close the turn: what it did, then, when the showdown
	// ends with it, the end of the showdown (rule 15).
	over := engine.AliveCount(st) <= 1 || g.Turn >= g.MaxTurns
	awards := engine.TurnVictoryPoints(engine.State{Chars: start}, st)
	if over {
		awards = append(awards, engine.EndVictoryPoints(st)...)
	}
	evs = append(evs, engine.VPEvents(awards)...)
	seedHex := enchex.EncodeToString(seed[:])
	g.Turns = append(g.Turns, newTurnResult(g.Turn, start, ground, g.Plans, seedHex, deck.Drawn(), evs))
	g.State = st
	g.award(cur, awards)
	g.clearTurn()
	switch {
	case engine.AliveCount(g.State) == 0:
		g.finish(cur, "all_down")
	case engine.AliveCount(g.State) == 1:
		g.finish(cur, "last_standing")
	case g.Turn >= g.MaxTurns:
		g.finish(cur, "max_turns")
	default:
		g.Turn++
		g.Phase = PhasePlanning
		g.startTurn()
	}
	return seedHex
}

// groundExists reports whether a gun with that ground id lies somewhere on
// the board; whether it is in the character's hex is checked when the
// action executes, since the character may walk to it first.
func groundExists(st engine.State, id int) bool {
	for _, gg := range st.Ground {
		if gg.ID == id {
			return true
		}
	}
	return false
}

// Surrender gives up the showdown (rule 15.4: at the start of a turn, that
// is while the plans are committed; once they are revealed, surrendering
// after reading the others' would be the abort the hidden plans remove).
// The character is Out: nobody can shoot it and it plays no more. With one
// character left in the fight the game ends and is scored, the surrendered
// losing the "Surrender" points and, an enemy holding the field, being
// captured; with more, the showdown goes on without it (its commit is
// dropped), and goes on to the reveals if the others' plans are committed.
func Surrender(cur realm, id string) {
	assertNoSend()
	caller := cur.Previous().Address()
	g := getGame(id)
	switch g.Phase {
	case PhasePlanning:
	case PhaseRevealing:
		panic("gnoslinger: the plans are being revealed: surrender at the start of a turn")
	default:
		panic("gnoslinger: game is not in progress")
	}
	p := g.mustSeat(caller)
	if g.State.Chars[p].Status != engine.Alive {
		panic("gnoslinger: your character is out of the fight")
	}
	g.State.Chars[p].Status = engine.Out
	emit("PlayerSurrendered", "id", id, "turn", strconv.Itoa(g.Turn), "player", caller.String(), "seat", strconv.Itoa(p))
	if engine.AliveCount(g.State) <= 1 {
		g.award(cur, engine.EndVictoryPoints(g.State))
		g.finish(cur, "surrender")
	} else {
		g.Commits[p] = Sealed{}
		g.Plans[p] = ""
		g.Salts[p] = ""
		g.Revealed[p] = false
		progress(cur, g)
	}
	save(g)
}

// ClaimTimeout ends the wait of a turn past its deadline. Anyone may call
// it. A game waiting for players has no timeout (its creator may cancel
// it). While the plans are committed, past the deadline: each player who
// did not commit misses the turn: it is passed for them, unless that makes
// MaxMissed in a row, which puts the character out of the fight (out of
// time counts as surrendering); the game then goes on to the reveals, and
// with nobody's plan in, the turn resolves empty. A showdown nobody plays
// any more so ends after MaxMissed claims, everyone out of the fight (its
// stakes given back, stakes.gno). While they are
// revealed, RevealGrace past the deadline (the timelocked plans had time
// to be opened, which is how a vanished player's plan normally comes in):
// every character whose plan is still not in misses the turn the same way.
// The realm cannot tell a copy nobody could open from one nobody tried to
// open, so it does not punish more than a missed turn. With one character
// left the game ends and is scored, with more the turn resolves with the
// plans in and the showdown goes on.
func ClaimTimeout(cur realm, id string) {
	assertNoSend()
	g := getGame(id)
	switch g.Phase {
	case PhaseFinished:
		panic("gnoslinger: game is finished")
	case PhaseWaiting:
		panic("gnoslinger: the game is waiting for players: it has no timeout")
	}
	if time.Now().Before(g.timeoutAt()) {
		if g.Phase == PhaseRevealing {
			panic("gnoslinger: the plans can still be revealed")
		}
		panic("gnoslinger: the game has not timed out yet")
	}
	for p := range g.Players {
		late := !g.committed(p) // planning: no commit
		if g.Phase == PhaseRevealing {
			late = !g.Revealed[p] // revealing: no plan in
		}
		if g.State.Chars[p].Status == engine.Alive && late {
			missTurn(g, p)
		}
	}
	if engine.AliveCount(g.State) <= 1 {
		g.award(cur, engine.EndVictoryPoints(g.State))
		g.finish(cur, "timeout")
	} else {
		progress(cur, g)
	}
	save(g)
}

// missTurn passes the turn for a seat whose plan is not in at the claim
// (its commit, if any, dropped), or puts the character out of the fight
// at its MaxMissed-th miss in a row; only a revealed plan resets the count.
func missTurn(g *Game, p int) {
	c := &g.State.Chars[p]
	g.Missed[p]++
	g.Commits[p] = Sealed{}
	emit("PlanMissed", "id", g.ID, "turn", strconv.Itoa(g.Turn), "seat", strconv.Itoa(p), "missed", strconv.Itoa(g.Missed[p]))
	if g.Missed[p] >= MaxMissed {
		c.Status = engine.Out
		return
	}
	c.PlayedFoot = false
	c.PlayedRun = false
	g.Plans[p] = ""
	g.Revealed[p] = true
}
