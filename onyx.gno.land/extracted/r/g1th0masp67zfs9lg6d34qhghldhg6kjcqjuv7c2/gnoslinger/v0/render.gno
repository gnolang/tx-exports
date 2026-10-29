package gnoslinger

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/cards/v0"
	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/engine/v0"
	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"
	"gno.land/p/moul/md/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	profiles "gno.land/r/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/profiles/v0"
)

const recentLimit = 20

var router = mux.NewRouter()

func init() {
	router.HandleFunc("", renderHome)
	router.HandleFunc("help", renderHelp)
	router.HandleFunc("game/{id}", renderGame)
	router.HandleFunc("json/game/{id}", func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(GameJSON(req.GetVar("id")))
	})
	router.HandleFunc("json/games/{addr}", func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(GamesJSON(req.GetVar("addr")))
	})
	router.HandleFunc("json/history/{id}/{turn}", func(res *mux.ResponseWriter, req *mux.Request) {
		turn, err := strconv.Atoi(req.GetVar("turn"))
		if err != nil {
			panic("gnoslinger: invalid turn")
		}
		res.Write(TurnJSON(req.GetVar("id"), turn))
	})
	router.HandleFunc("json/plan/{id}/{addr}", func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(PlanJSON(req.GetVar("id"), req.GetVar("addr")))
	})
}

// Render serves the gnoweb pages ("", "help", "game/{id}") and the raw JSON
// views the web client reads ("json/game/{id}", "json/games/{addr}",
// "json/history/{id}/{turn}", "json/plan/{id}/{addr}"); the players' profiles and
// ranking are the profiles realm's (gno.land/r/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/profiles/v0).
func Render(path string) string {
	return router.Render(path)
}

// link is a gnoweb link to a sub-path of this realm.
func link(text, path string) string {
	return md.Link(text, strings.TrimPrefix(realmPath, "gno.land")+":"+path)
}

func renderHome(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write(md.H1("Gnoslinger"))
	res.Write(md.Paragraph("Showdowns of two to four gunfighters on board A, the Corral, each on their own. " +
		"Create a game, wait for the seats to fill up, then submit a plan every turn. " +
		link("How to play", "help") + "."))
	res.Write(md.Paragraph(createLink("Create a game of two as the marshal", 2) + " · " + createLink("of three", 3) + " · " + createLink("of four", 4)))

	res.Write(md.H2("Open games"))
	n := 0
	var b strings.Builder
	b.WriteString("| Game | Creator | Seats | Stake | Created | |\n|---|---|---|---|---|---|\n")
	openGames.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*Game)
		b.WriteString("| " + link(g.ID, "game/"+g.ID) +
			" | " + addr(g.Players[0].Addr) +
			" | " + strconv.Itoa(g.seated()) + "/" + strconv.Itoa(g.seats()) +
			" | " + stakeLabel(g) +
			" | " + when(g.CreatedAt) +
			" | " + joinLink(g) + " |\n")
		n++
		return n >= recentLimit
	})
	if n == 0 {
		res.Write(md.Paragraph("No game is waiting for players."))
	} else {
		res.Write(b.String() + "\n")
	}

	res.Write(md.H2("Recent games"))
	n = 0
	b.Reset()
	b.WriteString("| Game | Players | Turn | Phase |\n|---|---|---|---|\n")
	games.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*Game)
		b.WriteString("| " + link(g.ID, "game/"+g.ID) +
			" | " + seatLabels(g) +
			" | " + strconv.Itoa(g.Turn) + "/" + strconv.Itoa(g.MaxTurns) +
			" | " + phaseLabel(g) + " |\n")
		n++
		return n >= recentLimit
	})
	if n == 0 {
		res.Write(md.Paragraph("No game yet."))
	} else {
		res.Write(b.String() + "\n")
	}
	if house > 0 {
		res.Write(md.Paragraph("The house holds " + gnot(house) + " for events."))
	}
}

func renderGame(res *mux.ResponseWriter, req *mux.Request) {
	g := getGame(req.GetVar("id"))
	res.Write(md.H1("Game " + g.ID))
	res.Write(md.Paragraph("Turn " + strconv.Itoa(g.Turn) + " of " + strconv.Itoa(g.MaxTurns) + " · " + phaseLabel(g)))
	if g.Stake > 0 {
		line := "Stake " + stakeLabel(g) + " · pot " + gnot(g.Pot)
		for i, v := range g.Payouts {
			if v > 0 {
				line += " · " + addr(g.Players[i].Addr) + " got " + gnot(v)
			}
		}
		if g.HouseCut > 0 {
			line += " · the house kept " + gnot(g.HouseCut)
		}
		res.Write(md.Paragraph(line))
	}

	var b strings.Builder
	b.WriteString("| Seat | Player | Character | Hex | Facing | Down | Delay | Status | Plan |\n")
	b.WriteString("|---|---|---|---|---|---|---|---|---|\n")
	for i, p := range g.Players {
		c := g.State.Chars[i]
		plan := "-"
		if g.Phase == PhasePlanning || g.Phase == PhaseRevealing {
			switch {
			case g.Revealed[i]:
				plan = "revealed"
			case g.committed(i):
				plan = "committed"
			default:
				plan = "pending"
			}
		}
		b.WriteString("| " + strconv.Itoa(i) +
			" | " + addr(p.Addr) +
			" | " + sanitize.InlineText(p.Char) +
			" | " + c.Hex +
			" | " + c.Facing.String() +
			" | " + yesNo(c.Down) +
			" | " + strconv.Itoa(c.Delay) +
			" | " + c.Status.String() +
			" | " + plan + " |\n")
	}
	res.Write(b.String() + "\n")

	for _, r := range g.Turns {
		res.Write(md.H3("Turn " + strconv.Itoa(r.Turn)))
		plans := make([]string, len(r.Plans))
		for i, p := range r.Plans {
			plans[i] = md.InlineCode(orPass(p))
		}
		res.Write(md.Paragraph("Plans: " + strings.Join(plans, " vs ")))
		if drawn := r.Cards(); len(drawn) > 0 {
			cards := make([]string, len(drawn))
			for i, n := range drawn {
				cards[i] = strconv.Itoa(n)
			}
			res.Write(md.Paragraph("Result cards drawn: " + strings.Join(cards, ", ")))
		}
		evs := r.Events()
		items := make([]string, 0, len(evs))
		for _, e := range evs {
			items = append(items, describeEvent(g, e))
		}
		if len(items) == 0 {
			items = append(items, "Nothing happened.")
		}
		res.Write(md.BulletList(items) + "\n")
	}

	switch g.Phase {
	case PhaseWaiting:
		res.Write(md.Paragraph(joinLink(g) + " · " + md.Link("Cancel", txlink.Call("CancelGame", "id", g.ID))))
	case PhasePlanning:
		res.Write(md.Paragraph("Plans are hidden: commit " + md.InlineCode("PlanHash(id, turn, seat, salt, plan)") +
			", reveal once every plan is committed. " +
			md.Link("Commit a plan", txlink.Call("Commit", "id", g.ID, "turn", strconv.Itoa(g.Turn), "hash", "", "locked", "")) +
			" · " + md.Link("Surrender", txlink.Call("Surrender", "id", g.ID)) +
			" · " + md.Link("Claim timeout", txlink.Call("ClaimTimeout", "id", g.ID)) +
			" (after " + when(g.timeoutAt()) + ")"))
	case PhaseRevealing:
		res.Write(md.Paragraph(md.Link("Reveal a plan", txlink.Call("Reveal", "id", g.ID, "turn", strconv.Itoa(g.Turn), "seat", "", "salt", "", "plan", "")) +
			" · " + md.Link("Claim timeout", txlink.Call("ClaimTimeout", "id", g.ID)) +
			" (after " + when(g.timeoutAt()) + ")"))
	}
	res.Write(md.Paragraph(link("Back to the lobby", "")))
}

func renderHelp(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write(md.H1("How to play"))
	res.Write(md.Paragraph("Two to four gunfighters, each on their own. Each turn has five segments. Every player secretly picks up to five time points " +
		"of action cards, in the order they will do them, then the turn resolves: an action executes on the " +
		"segment equal to the time points used so far plus its own cost plus the delay points on your sheet. " +
		"Delay you gain during a segment counts from the next one; actions left after segment 5 are cancelled. " +
		"At the end of the turn half of your delay (rounded up) goes away."))
	res.Write(md.H2("Setting up"))
	res.Write(md.Paragraph("The creator picks how many play, two to four, and is the marshal; the others take the next characters " +
		"in the order they join: the kid, then the reb, then the yankee. Each player picks where to stand when calling or joining a showdown, " +
		"among the hexes assigned to its character, inside the corral: " + setupList() + "; each faces any direction (" +
		md.InlineCode("0") + " N, " + md.InlineCode("1") + " NE, " + md.InlineCode("2") + " SE, " + md.InlineCode("3") + " S, " +
		md.InlineCode("4") + " SW, " + md.InlineCode("5") + " NW; the marshal looks south-east, the kid north-west, the reb north and the yankee south unless told otherwise). " +
		"All start upright with a loaded Colt 45 in the holster. Aims and shots name a character by seat (" + md.InlineCode("@1") +
		") or a hex. A character killed or passed out is out of the fight; one may surrender while the plans are collected, and the others fight on."))
	res.Write(md.H2("Plan string"))
	res.Write(md.Paragraph("A plan is a comma-separated list of card sides in play order, each " +
		md.InlineCode("<card><f|b>[:<direction>]") + ". Directions are relative to your facing: " +
		md.InlineCode("ahead_left") + ", " + md.InlineCode("ahead") + ", " + md.InlineCode("ahead_right") + " for forward moves and turns, " +
		md.InlineCode("back_left") + ", " + md.InlineCode("back") + ", " + md.InlineCode("back_right") + " for backward ones. " +
		"An empty plan passes."))
	res.Write(md.Paragraph("Example: " + md.InlineCode("1f:ahead_left,2f:ahead,3f") + " advances ahead-left, runs ahead, then sprints straight."))
	res.Write(md.Paragraph("Rules: one side per card per turn; the total cost must fit in 5 minus your delay; " +
		"Run needs Advance in the same plan; Sprint needs Run."))
	res.Write(md.Paragraph("Aiming and shooting need the target in your aim zone and in sight (rule 31). " +
		"On board A only the horse trough (" + md.InlineCode("A-I11*") + ") gets in the way: it hides two characters " +
		"lying DOWN from each other, and a DOWN character next to it from anyone across it; standing characters see " +
		"over it. An aim at a target out of sight is cancelled and AIM points on it are lost at the end of the " +
		"segment; a shot at it is held, nothing spent, like a shot at a hex nobody stands in when it comes up."))
	res.Write(md.H2("Cards"))
	var b strings.Builder
	b.WriteString("| Card | Front | Back |\n|---|---|---|\n")
	for _, c := range cards.Cards {
		b.WriteString("| " + strconv.Itoa(c.Number) + " | " + sideLabel(c.Front) + " | " + sideLabel(c.Back) + " |\n")
	}
	res.Write(b.String() + "\n")
	res.Write(md.Paragraph("Only foot actions are available for now; the others come with guns and brawling."))
}

// cancelReason is the reason of a cancel event as the log shows it: the
// reason code, except a target out of sight, spelled out with the obstacle
// in the way.
func cancelReason(e engine.Event) string {
	switch e.Reason {
	case engine.ReasonNoLOS:
		return noSight(e)
	case engine.ReasonNotInHand:
		return "the gun is not in hand"
	case engine.ReasonNotBoth:
		return "the gun is not in both hands"
	}
	return e.Reason
}

// noSight words a no_los reason: the event's To names the obstacle in the way.
func noSight(e engine.Event) string {
	if e.To == "" {
		return "no line of sight"
	}
	return "no line of sight, " + e.To + " in the way"
}

func sideLabel(s cards.Side) string {
	l := s.Name + " (" + strconv.Itoa(s.Cost) + ")"
	if !cards.Enabled(s.Code) {
		l += " *"
	}
	return l
}

func describeEvent(g *Game, e engine.Event) string {
	who := sanitize.InlineText(g.Players[e.Player].Char)
	seg := "turn start"
	switch {
	case e.Seg > engine.Segments:
		seg = "end of turn"
	case e.Seg > 0:
		seg = "seg " + strconv.Itoa(e.Seg)
	}
	action := strings.ReplaceAll(string(e.Action), "_", " ")
	var what string
	switch e.Kind {
	case engine.EvMove:
		what = who + " " + action + ": " + e.From + " → " + e.To
		if e.Down {
			what += " (crawling)"
		}
	case engine.EvTurn:
		what = who + " " + action + ": now facing " + hex.Dir(e.Facing).String()
	case engine.EvFlip:
		if e.Down {
			what = who + " goes down"
		} else {
			what = who + " gets up"
		}
	case engine.EvDelay:
		what = who + " gains " + strconv.Itoa(e.N) + " delay (" + e.Reason + "), now " + strconv.Itoa(e.Delay)
		if e.Card > 0 {
			// Every card drawn reads the same: who draws which card and why, then what it does.
			drawn := who + " draws card " + strconv.Itoa(e.Card) + " (" + e.Reason + "): "
			if e.Result != "" {
				what = drawn + strings.ToUpper(strings.ReplaceAll(e.Result, "_", " "))
			} else {
				gain := "no delay"
				if e.N > 0 {
					gain = "gains " + strconv.Itoa(e.N) + " delay"
				}
				what = drawn + gain + ", now " + strconv.Itoa(e.Delay)
				if e.Endurance > 0 {
					what += ", loses " + strconv.Itoa(e.Endurance) + " endurance"
				}
			}
		}
	case engine.EvWildShot:
		what = who + "'s " + e.Gun.Spec().Name + " goes off (wild shot)"
	case engine.EvCock:
		what = who + " cocks the " + e.Gun.Spec().Name
	case engine.EvUncock:
		what = who + " uncocks the " + e.Gun.Spec().Name
	case engine.EvAim:
		what = who + " aims at " + e.To
		if e.Target >= 0 {
			what += " (" + seatLabel(g, e.Target) + ")"
		}
		what += ": " + strconv.Itoa(e.N) + " AIM points"
	case engine.EvLoseAim:
		if e.Reason == engine.ReasonNoLOS {
			what = who + " loses the aim (" + noSight(e) + ")"
		} else if e.Reason == engine.ReasonOwnHex {
			what = who + " loses the aim (the markers cannot move into or out of its own hex)"
		} else {
			what = who + " loses the aim (" + strings.ReplaceAll(e.Reason, "_", " ") + ")"
		}
	case engine.EvNothing:
		hold := " holds fire: "
		if e.Action == cards.Throw {
			hold = " holds the throw: "
		}
		switch e.Reason {
		case engine.ReasonEmptyHex:
			what = who + hold + "nobody in " + e.To
		case engine.ReasonNoLOS:
			what = who + hold + seatLabel(g, e.Target) + " in " + e.To + " is out of sight"
		case engine.ReasonOutOfFight:
			what = who + hold + seatLabel(g, e.Target) + " is out of the fight"
		default:
			what = who + " does nothing (" + action + ")"
		}
	case engine.EvShot:
		at := "at " + e.To
		if e.Target >= 0 {
			at = seatLabel(g, e.Target) + " in " + e.To
		}
		what = who + " shoots " + at + " (card " + strconv.Itoa(e.Card) + ", aim time " + strconv.Itoa(e.N) + ", range " + strconv.Itoa(e.Range) + "): "
		switch {
		case e.Reason == engine.ReasonMisfire:
			what += "misfire"
		case e.Hit == string(engine.Miss):
			what += "miss"
			if e.Reason != "" {
				what += " (" + strings.ReplaceAll(e.Reason, "_", " ") + ")"
			}
		default:
			what += e.Hit + " hit"
		}
	case engine.EvThrow:
		at := "at " + e.To
		if e.Target >= 0 {
			at = "at " + seatLabel(g, e.Target) + " in " + e.To
		}
		what = who + " throws the " + e.Gun.Spec().Name + " " + at + " (card " + strconv.Itoa(e.Card) + ", aim time " + strconv.Itoa(e.N) + ", range " + strconv.Itoa(e.Range) + "): "
		if e.Hit == string(engine.Miss) {
			what += "miss"
			if e.Reason != "" {
				what += " (" + strings.ReplaceAll(e.Reason, "_", " ") + ")"
			}
		} else {
			what += e.Hit + " hit"
		}
	case engine.EvMalfunction:
		what = who + " draws card " + strconv.Itoa(e.Card) + ": MALFUNCTION, " + strings.ReplaceAll(e.Result, "_", " ")
	case engine.EvWound:
		what = who + " suffers " + strings.ToUpper(strings.ReplaceAll(e.Result, "_", " "))
		if e.N > 0 {
			what += " " + strconv.Itoa(e.N)
		}
	case engine.EvDirection:
		what = who + " draws card " + strconv.Itoa(e.Card) + " as a direction: " + strings.ReplaceAll(e.To, "_", " ")
	case engine.EvDropGun:
		what = who + " drops the " + e.Gun.Spec().Name + " in " + e.To
		if e.Reason == engine.ReasonThrow {
			what = who + "'s " + e.Gun.Spec().Name + " lands in " + e.To
		}
	case engine.EvMoveGun:
		what = who + " moves the " + e.Gun.Spec().Name + " from " + strings.ReplaceAll(e.From, "_", " ") + " to the " + strings.ReplaceAll(e.To, "_", " ")
	case engine.EvPassOut:
		what = who + " passes out"
	case engine.EvRunAway:
		what = who + " runs away off the map from " + e.From
	case engine.EvSeriousCheck:
		what = who + " draws card " + strconv.Itoa(e.Card) + " for the SERIOUS wounds: " + strconv.Itoa(e.N) + " points"
	case engine.EvVP:
		pts := strconv.Itoa(e.N)
		if e.N > 0 {
			pts = "+" + pts
		}
		what = who + ": " + pts + " VP, " + strings.ReplaceAll(e.Reason, "_", " ")
	case engine.EvDraw:
		to := "to the " + strings.ReplaceAll(e.To, "_", " ")
		if e.To == engine.BothHands.String() {
			to = "into both hands"
		}
		cocks := " and cocks it"
		if e.Result == engine.DrawJammed {
			cocks = " (jammed: not cocked)"
		}
		switch e.From {
		case "ground":
			what = who + " picks up the " + e.Gun.Spec().Name + " from the ground " + to + cocks
		case engine.Holstered.String():
			what = who + " draws the " + e.Gun.Spec().Name + " " + to + cocks
		default:
			what = who + " moves the " + e.Gun.Spec().Name + " " + to + cocks
		}
	case engine.EvLoad:
		what = who + " loads a shell in the " + e.Gun.Spec().Name + " (" + strconv.Itoa(e.N) + " now)"
		if e.Result == engine.LoadUnjammed {
			what += ": no longer jammed"
		}
	case engine.EvCancel:
		what = who + ": " + action + " is cancelled (" + cancelReason(e) + ")"
	default:
		what = who + " " + e.Kind
	}
	return seg + ": " + what
}

func seatLabel(g *Game, i int) string {
	if i < 0 || i >= g.seats() || g.Players[i].Addr == "" {
		return "?"
	}
	return sanitize.InlineText(g.Players[i].Char)
}

// seatLabels names every seat, "marshal vs the_kid vs ?".
func seatLabels(g *Game) string {
	labels := make([]string, g.seats())
	for i := range g.Players {
		labels[i] = seatLabel(g, i)
	}
	return strings.Join(labels, " vs ")
}

// createLink is a transaction link to call a showdown of seats players,
// standing in the middle of the marshal's hexes, facing its way.
func createLink(text string, seats int) string {
	setup := engine.Setups[0]
	return md.Link(text, txlink.Call("CreateGame", "seats", strconv.Itoa(seats), "maxTurns", "20", "timeoutMinutes", "0",
		"startHex", setup.Hexes[len(setup.Hexes)/2], "facing", strconv.Itoa(int(setup.Facing))))
}

// joinLink is a transaction link to take the next free seat of a waiting
// game, standing in the middle of its character's hexes.
func joinLink(g *Game) string {
	seat := g.freeSeat()
	if seat < 0 {
		return ""
	}
	setup := engine.SetupOf(engine.SeatChar(seat))
	tx := txlink.NewLink("JoinGame").AddArgs("id", g.ID, "startHex", setup.Hexes[len(setup.Hexes)/2], "facing", strconv.Itoa(int(setup.Facing)))
	if g.Stake > 0 {
		tx = tx.SetSend(strconv.FormatInt(g.Stake, 10) + Denom)
	}
	return md.Link("Join as "+strings.ReplaceAll(setup.Char, "_", " "), tx.URL())
}

// gnot words an amount of ugnot in GNOT: "5 GNOT", "9.5 GNOT".
func gnot(ugnot int64) string {
	s := strconv.FormatInt(ugnot/1_000_000, 10)
	if frac := ugnot % 1_000_000; frac != 0 {
		f := strconv.FormatInt(1_000_000+frac, 10)[1:]
		s += "." + strings.TrimRight(f, "0")
	}
	return s + " GNOT"
}

// stakeLabel words a showdown's stake: "free", or "5 GNOT each".
func stakeLabel(g *Game) string {
	if g.Stake == 0 {
		return "free"
	}
	return gnot(g.Stake) + " each"
}

// setupList words where each character sets up: "the marshal in A-G5 to A-G9, ...".
func setupList() string {
	parts := make([]string, len(engine.Setups))
	for i, s := range engine.Setups {
		parts[i] = strings.ReplaceAll(s.Char, "_", " ") + " in " + md.InlineCode(s.Hexes[0]) + " to " + md.InlineCode(s.Hexes[len(s.Hexes)-1])
	}
	return strings.Join(parts, ", ")
}

func phaseLabel(g *Game) string {
	if g.Phase != PhaseFinished {
		return g.Phase.String()
	}
	l := "finished (" + g.EndReason + ")"
	if len(g.Awards) > 0 {
		vp := make([]string, len(g.VP))
		for i, v := range g.VP {
			vp[i] = strconv.Itoa(v)
		}
		l += ", " + strings.Join(vp, " to ") + " VP"
	}
	if g.Winner >= 0 {
		l += ", winner: " + seatLabel(g, g.Winner)
	}
	return l
}

// addr shows an address by its registered name when it has one.
func addr(a address) string {
	if name := profiles.Name(a); name != "" {
		return md.Bold(sanitize.InlineText(name))
	}
	return md.InlineCode(sanitize.InlineText(a.String()))
}

func when(t time.Time) string {
	return t.UTC().Format("2006-01-02 15:04") + " UTC"
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func orPass(plan string) string {
	if plan == "" {
		return "(pass)"
	}
	return plan
}
