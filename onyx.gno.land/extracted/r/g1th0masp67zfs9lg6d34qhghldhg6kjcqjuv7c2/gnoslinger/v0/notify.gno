package gnoslinger

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/engine/v0"
	gnotif "gno.land/r/nym-gfanton001/gnotif/v1"
)

// Browser notifications, through gnotif (https://gnotif.xyz). At the
// moments a player may have the game closed, the realm emits one event per
// player concerned, naming it in the "to" attribute (PlanDue, RevealDue,
// ShowdownOver), and declares in the gnotif registry one trigger per
// event, which gives the notification its title, body and link. A gnotif
// server (gnotif.xyz on Onyx; make notif runs one on gnodev) reads the
// chain's events and pushes the notification to every browser opted in
// with that address; the client opts in from the lobby
// (game/notifications.ts). A deadline passing emits nothing, so a timeout
// is never notified.

// notifTriggers are the realm's triggers, by name. Title and body are
// templates, {key} standing for the event's attribute: every event names
// the player's character (char) and the others' (vs), and the game; the
// link opens the game in the client (game/route.ts).
var notifTriggers = []struct {
	name string
	t    gnotif.Trigger
}{
	{"move", gnotif.Trigger{Event: "PlanDue", Param: "to", Title: "Gnoslinger · Your move", Body: "{char} vs {vs}, game {id}, turn {turn} of {turns}: {left} to send your plan.", Link: "/#game/{id}"}},
	{"reveal", gnotif.Trigger{Event: "RevealDue", Param: "to", Title: "Gnoslinger · Reveal your plan", Body: "{char} vs {vs}, game {id}, turn {turn} of {turns}: every plan is in, yours waits to be revealed.", Link: "/#game/{id}"}},
	{"over", gnotif.Trigger{Event: "ShowdownOver", Param: "to", Title: "Gnoslinger · Showdown over", Body: "{char} vs {vs}, game {id}: {outcome}.", Link: "/#game/{id}"}},
}

// notif is the realm's handle on its triggers in the registry, kept so that
// DeclareTriggers can set them again: a changed title, body or link keeps
// the trigger's id, and so the browsers opted in.
var notif *gnotif.Handle

// DeclareTriggers sets the realm's triggers in the gnotif registry. Admin
// only, and the first call has what the registry's Open requires: the
// namespace owner's own key (not a session), in a call sent straight to
// the realm; so the deployer sends it once the realm is deployed (on
// gnodev, the make notif script sends it as test1). The triggers keep
// their ids from one call to the next. Every call makes the registry emit
// each trigger again (TriggerDeclared), which is what a gnotif server
// reads them from: the registry emits nothing for a trigger set as it
// already is, so each is first set with a nudged body, then as it should
// be. That is for gnodev, whose reload puts the earlier call in the
// genesis, where no indexer serves its events: the script calls again
// after each reload and the triggers reach gnotifd anew.
func DeclareTriggers(cur realm) {
	assertNoSend()
	assertAdmin(cur)
	me := cur.Sub(gnotif.Subpath)
	if notif == nil {
		notif = gnotif.Open(cross(me))
	}
	for _, nt := range notifTriggers {
		nudged := nt.t
		nudged.Body += " "
		notif.Set(cross(me), nt.name, nudged)
		notif.Set(cross(me), nt.name, nt.t)
	}
}

// notifyPlanDue tells every player with a plan to send that the turn
// started: its character in the fight, not committed, with time points to
// play (one passed automatically has nothing to send).
func (g *Game) notifyPlanDue() {
	if g.Phase != PhasePlanning {
		return
	}
	left := formatTimeout(g.Timeout)
	for p, pl := range g.Players {
		if g.State.Chars[p].Status == engine.Alive && !g.committed(p) && g.State.Budget(p) > 0 {
			emit("PlanDue", "id", g.ID, "turn", strconv.Itoa(g.Turn), "turns", strconv.Itoa(g.MaxTurns), "to", pl.Addr.String(), "char", charName(pl.Char), "vs", g.others(p), "left", left)
		}
	}
}

// notifyRevealDue tells every player whose committed plan is not revealed
// yet that the reveals started.
func (g *Game) notifyRevealDue() {
	for p, pl := range g.Players {
		if g.State.Chars[p].Status == engine.Alive && !g.Revealed[p] {
			emit("RevealDue", "id", g.ID, "turn", strconv.Itoa(g.Turn), "turns", strconv.Itoa(g.MaxTurns), "to", pl.Addr.String(), "char", charName(pl.Char), "vs", g.others(p))
		}
	}
}

// notifyOver tells every player how the finished showdown ended for it.
func (g *Game) notifyOver() {
	for p, pl := range g.Players {
		outcome := "a draw"
		switch {
		case g.Winner == p:
			outcome = "you won"
		case g.Winner >= 0:
			outcome = "you lost"
		}
		emit("ShowdownOver", "id", g.ID, "to", pl.Addr.String(), "char", charName(pl.Char), "vs", g.others(p), "outcome", outcome)
	}
}

// notifyCancelled tells the players who had joined a showdown that its
// creator cancelled it (the creator knows).
func (g *Game) notifyCancelled(creator address) {
	for p, pl := range g.Players {
		if pl.Addr != "" && pl.Addr != creator {
			emit("ShowdownOver", "id", g.ID, "to", pl.Addr.String(), "char", charName(pl.Char), "vs", g.others(p), "outcome", "cancelled by its creator, every stake given back")
		}
	}
}

// others names the characters of the other seated players, in seat
// order, comma-separated: "The Kid, Reb".
func (g *Game) others(seat int) string {
	var names []string
	for p, pl := range g.Players {
		if p != seat && pl.Addr != "" {
			names = append(names, charName(pl.Char))
		}
	}
	return strings.Join(names, ", ")
}

// charName spells a character key as the client does: "the_kid" is "The
// Kid".
func charName(key string) string {
	words := strings.Split(key, "_")
	for i, w := range words {
		if w != "" {
			words[i] = strings.ToUpper(w[:1]) + w[1:]
		}
	}
	return strings.Join(words, " ")
}

// formatTimeout spells the time a turn gives: whole days, else whole hours,
// else minutes.
func formatTimeout(d time.Duration) string {
	n, unit := int64(d/time.Minute), "minute"
	switch {
	case d%(24*time.Hour) == 0:
		n, unit = int64(d/(24*time.Hour)), "day"
	case d%time.Hour == 0:
		n, unit = int64(d/time.Hour), "hour"
	}
	if n != 1 {
		unit += "s"
	}
	return strconv.FormatInt(n, 10) + " " + unit
}
