package gnoslinger

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/engine/v0"
	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"
	profiles "gno.land/r/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/profiles/v0"
)

// CreateGame opens a showdown of seats players (engine.MinPlayers to
// engine.MaxPlayers) with the caller in seat 0, playing the showdown's
// first character (engine.Setups: the marshal), standing in startHex, one
// of the hexes assigned to that character, facing f (0=N 1=NE 2=SE 3=S
// 4=SW 5=NW); it returns the game id. The other seats take the next
// characters in the order the players join. maxTurns is the game length,
// from MinMaxTurns to MaxMaxTurns; timeoutMinutes is the time each turn
// gives the players, past which anyone may claim it with ClaimTimeout, 0
// meaning DefaultTimeout (2 days). The game stays open until its seats fill
// up or its creator cancels it: the turn clock starts with the last join.
// The ugnot sent with the call are the showdown's stake, which every
// joiner must send too; none, a free showdown (stakes.gno).
func CreateGame(cur realm, seats int, maxTurns int, timeoutMinutes int, startHex string, facing int) string {
	caller := cur.Previous().Address()
	stake := sentStake(cur)
	if seats < engine.MinPlayers || seats > engine.MaxPlayers {
		panic("gnoslinger: seats must be between " + strconv.Itoa(engine.MinPlayers) + " and " + strconv.Itoa(engine.MaxPlayers))
	}
	if maxTurns < MinMaxTurns || maxTurns > MaxMaxTurns {
		panic("gnoslinger: maxTurns must be between " + strconv.Itoa(MinMaxTurns) + " and " + strconv.Itoa(MaxMaxTurns))
	}
	timeout := DefaultTimeout
	if timeoutMinutes != 0 {
		timeout = time.Duration(timeoutMinutes) * time.Minute
	}
	if timeout < MinTimeout || timeout > MaxTimeout {
		panic("gnoslinger: timeoutMinutes must be between " + strconv.Itoa(int(MinTimeout/time.Minute)) + " and " + strconv.Itoa(int(MaxTimeout/time.Minute)))
	}
	charKey := engine.SeatChar(0)
	assertSetUp(charKey, startHex, facing)
	id := gameSeq.Next().String()
	g := &Game{
		ID:        id,
		Players:   make([]Player, seats),
		State:     engine.NewState(seats),
		Turn:      1,
		MaxTurns:  maxTurns,
		Timeout:   timeout,
		Phase:     PhaseWaiting,
		Missed:    make([]int, seats),
		Winner:    -1,
		VP:        make([]int, seats),
		Stake:     stake,
		Pot:       stake,
		CreatedAt: time.Now(),
	}
	g.clearTurn()
	g.Players[0] = Player{Addr: caller, Char: charKey}
	g.State.SetUp(0, startHex, hex.Dir(facing))
	openGames.Set(id, g)
	index(caller, id)
	profiles.Ensure(cross(cur), caller)
	save(g)
	emit("GameCreated", "id", id, "creator", caller.String(), "char", charKey, "seats", strconv.Itoa(seats),
		"maxTurns", strconv.Itoa(maxTurns), "timeoutMinutes", strconv.Itoa(int(timeout/time.Minute)), "hex", startHex, "facing", strconv.Itoa(facing),
		"stake", strconv.FormatInt(stake, 10))
	return id
}

// JoinGame seats the caller in the first free seat of a waiting game,
// playing that seat's character (the kid, then the reb, then the yankee),
// standing in startHex, one of that character's hexes, facing f; the game
// starts collecting the commits of turn 1 once its last seat is taken.
// The call must send the showdown's stake, no more, no less.
func JoinGame(cur realm, id string, startHex string, facing int) {
	caller := cur.Previous().Address()
	stake := sentStake(cur)
	g := getGame(id)
	if g.Phase != PhaseWaiting {
		panic("gnoslinger: game is not open")
	}
	switch g.seat(caller) {
	case 0:
		panic("gnoslinger: you cannot join your own game")
	case -1:
	default:
		panic("gnoslinger: you are already in this game")
	}
	seat := g.freeSeat()
	if seat < 0 {
		panic("gnoslinger: every seat is taken")
	}
	charKey := engine.SeatChar(seat)
	assertSetUp(charKey, startHex, facing)
	if stake != g.Stake {
		panic("gnoslinger: this showdown's stake is " + strconv.FormatInt(g.Stake, 10) + Denom + ", sent " + strconv.FormatInt(stake, 10) + Denom)
	}
	g.Pot += stake
	g.Players[seat] = Player{Addr: caller, Char: charKey}
	g.State.SetUp(seat, startHex, hex.Dir(facing))
	index(caller, id)
	if g.freeSeat() < 0 {
		// The game starts: it counts as played for every seat.
		g.Phase = PhasePlanning
		g.startTurn()
		g.notifyPlanDue()
		openGames.Remove(id)
		for _, p := range g.Players {
			profiles.AddGamePlayed(cross(cur), p.Addr)
		}
	} else {
		profiles.Ensure(cross(cur), caller)
	}
	save(g)
	emit("PlayerJoined", "id", id, "player", caller.String(), "seat", strconv.Itoa(seat), "char", charKey, "hex", startHex, "facing", strconv.Itoa(facing))
}

// assertSetUp refuses a character that is not in the showdown, a hex it
// may not set up in, or no such facing.
func assertSetUp(charKey, startHex string, facing int) {
	setup := engine.SetupOf(charKey)
	if setup == nil {
		panic("gnoslinger: " + charKey + " is not in this showdown: play " + strings.Join(engine.ShowdownChars(), " or "))
	}
	if !engine.CanSetUp(charKey, startHex) {
		panic("gnoslinger: " + charKey + " sets up in " + strings.Join(setup.Hexes, ", ") + ", not in " + startHex)
	}
	if !hex.Dir(facing).Valid() {
		panic("gnoslinger: facing must be between 0 (N) and 5 (NW)")
	}
}

// CancelGame withdraws a game whose seats are not all taken yet. Creator
// only. The game is deleted, not kept as finished, so the creator gets back
// the storage deposit CreateGame paid; the players who had joined are
// unindexed with it, and every stake paid goes back.
func CancelGame(cur realm, id string) {
	assertNoSend()
	caller := cur.Previous().Address()
	g := getGame(id)
	if g.Phase != PhaseWaiting {
		panic("gnoslinger: only a game waiting for players can be cancelled")
	}
	if g.Players[0].Addr != caller {
		panic("gnoslinger: only the creator can cancel the game")
	}
	g.refundStakes(cur)
	openGames.Remove(id)
	games.Remove(id)
	for _, p := range g.Players {
		if p.Addr != "" {
			unindex(p.Addr, id)
		}
	}
	emit("GameEnded", "id", id, "reason", "cancelled", "winner", "")
	g.notifyCancelled(caller)
}
