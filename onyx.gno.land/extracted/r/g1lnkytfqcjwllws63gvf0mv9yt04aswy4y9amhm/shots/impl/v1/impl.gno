// Package impl is the first rules engine for gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shots.
//
// It owns the game state machine and pot rules; the state itself, and the
// coins, stay in the shots realm, reached through shots.Store.
//
// Game:    open --join--> playing --player wins--> won (pot paid out, closed)
//
//	^                 |
//	+----player loses-+ (entry fee stays in the pot)
//	open --creator cancels, nobody played yet--> cancelled (pot refunded)
//
// Session: each round the player shoots, then keeps. Every move is played
// out in the transaction that makes it, from 32 bytes derived from that
// block's timestamp (see entropy).
//
// ENTROPY. The seed is SHA-256 of the block time (unix nanoseconds) and the
// kick's identity (game, session, kick number), so two kicks in one block
// still differ. The block time is not known when the player signs, but it is
// not secret either: the proposer chooses it within consensus bounds, and
// anything else running in the same transaction can read the result. In
// particular a transaction that makes a move and then, in a later message,
// reads the session and fails on a bad outcome reverts the whole kick, so a
// player can retry until they like the result (for the price of gas). Fine
// for play money; a commit-reveal or a VRF is needed before real stakes, and
// an upgraded implementation can switch without touching games or pots.
package impl

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"strconv"
	"time"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/physics/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shootout/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shots"
)

const (
	MinDeposit     = 1000000 // ugnot to seed a pot (1 GNOT)
	MinEntryFee    = 100000  // ugnot (0.1 GNOT)
	DefaultTimeout = 1000    // blocks a challenger may sit idle
	MinTimeout     = 30
	MaxTimeout     = 200000
)

type engine struct{}

var instance = &engine{}

// Instance returns the implementation, for a caller that registers it
// explicitly rather than relying on init.
func Instance() shots.Impl { return instance }

func init(cur realm) {
	shots.Register(cross(cur), instance)
}

func (e *engine) Describe() string {
	return "impl/v1: Spot Kick physics (penalty/physics/v0, bit-identical to the browser engine), seed = SHA-256 of the block time"
}

func (e *engine) SimulateShot(shot penalty.ShotParams, plan penalty.KeeperPlan, cfg penalty.Config) penalty.Result {
	return physics.SimulateShot(shot, plan, cfg)
}

// ---------------------------------------------------------------- games

func (e *engine) CreateGame(_ int, rlm realm, creator address, deposit, entryFee, timeoutBlocks int64, config string) uint64 {
	cfg, err := penalty.ParseConfig(config)
	if err != nil {
		panic(err)
	}
	if deposit < MinDeposit {
		panic("shots: send at least " + itoa(MinDeposit) + "ugnot to seed the pot")
	}
	if entryFee < MinEntryFee {
		panic("shots: the entry fee must be at least " + itoa(MinEntryFee) + "ugnot")
	}
	if timeoutBlocks == 0 {
		timeoutBlocks = DefaultTimeout
	}
	if timeoutBlocks < MinTimeout || timeoutBlocks > MaxTimeout {
		panic("shots: timeoutBlocks must be within " + itoa(MinTimeout) + ".." + itoa(MaxTimeout))
	}
	st := shots.Store(0, rlm)
	g := shootout.Game{
		ID:            st.NewGameID(),
		Creator:       creator,
		Config:        cfg,
		EntryFee:      entryFee,
		TimeoutBlocks: timeoutBlocks,
		Pot:           deposit,
		Status:        shootout.GameOpen,
		CreatedHeight: runtime.ChainHeight(),
	}
	st.PutGame(g)
	chain.Emit("GameCreated", "game", u64(g.ID), "creator", string(creator), "pot", itoa(deposit),
		"entryFee", itoa(entryFee), "config", cfg.String())
	return g.ID
}

func (e *engine) TopUp(_ int, rlm realm, from address, gameID uint64, paid int64) {
	st := shots.Store(0, rlm)
	g := mustGame(st, gameID)
	if g.Status != shootout.GameOpen && g.Status != shootout.GamePlaying {
		panic("shots: game " + u64(gameID) + " is closed")
	}
	if paid <= 0 {
		panic("shots: send ugnot to top up the pot")
	}
	g.Pot += paid
	st.PutGame(g)
	chain.Emit("PotToppedUp", "game", u64(gameID), "from", string(from), "amount", itoa(paid), "pot", itoa(g.Pot))
}

func (e *engine) CancelGame(_ int, rlm realm, caller address, gameID uint64) {
	st := shots.Store(0, rlm)
	g := mustGame(st, gameID)
	if caller != g.Creator {
		panic("shots: only the creator can cancel game " + u64(gameID))
	}
	if g.Status != shootout.GameOpen || g.Sessions > 0 {
		panic("shots: a game can only be cancelled before anyone has played it")
	}
	refund := g.Pot
	g.Pot = 0
	g.Status = shootout.GameCancelled
	g.ClosedHeight = runtime.ChainHeight()
	st.PutGame(g)
	st.Pay(g.Creator, refund)
	chain.Emit("GameCancelled", "game", u64(gameID), "refund", itoa(refund))
}

// ---------------------------------------------------------------- sessions

func (e *engine) JoinGame(_ int, rlm realm, player address, gameID uint64, paid int64) {
	st := shots.Store(0, rlm)
	g := mustGame(st, gameID)
	if g.Status != shootout.GameOpen {
		panic("shots: game " + u64(gameID) + " is not open (" + g.Status.String() + ")")
	}
	if paid != g.EntryFee {
		panic("shots: send exactly the entry fee, " + itoa(g.EntryFee) + "ugnot")
	}
	h := runtime.ChainHeight()
	g.Pot += paid
	g.Sessions++
	g.Status = shootout.GamePlaying
	st.PutGame(g)
	st.PutSession(shootout.Session{
		GameID:           gameID,
		No:               g.Sessions,
		Player:           player,
		Paid:             paid,
		Status:           shootout.SessionPlaying,
		JoinHeight:       h,
		LastActionHeight: h,
	})
	chain.Emit("GameJoined", "game", u64(gameID), "session", strconv.Itoa(g.Sessions), "player", string(player),
		"pot", itoa(g.Pot))
}

func (e *engine) TakeShot(_ int, rlm realm, player address, gameID uint64, shot penalty.ShotInput) shootout.Kick {
	st := shots.Store(0, rlm)
	g, s := mustPlayersSession(st, gameID, player)
	if err := shot.Validate(g.Config); err != nil {
		panic(err)
	}
	return e.kick(st, g, s, penalty.SidePlayer, shot, penalty.KeeperPlan{})
}

func (e *engine) SubmitKeeperPlan(_ int, rlm realm, player address, gameID uint64, plan penalty.KeeperPlan) shootout.Kick {
	st := shots.Store(0, rlm)
	g, s := mustPlayersSession(st, gameID, player)
	return e.kick(st, g, s, penalty.SideChain, penalty.ShotInput{}, plan)
}

// kick plays the player's move against the chain's, both completed by this
// block's seed, records it, and ends the session if the shootout is decided.
func (e *engine) kick(st *shots.StateRef, g shootout.Game, s shootout.Session, kicker penalty.Side,
	shot penalty.ShotInput, plan penalty.KeeperPlan) shootout.Kick {
	if want := s.Score.Next(); want != kicker {
		if want == penalty.SidePlayer {
			panic("shots: it is your turn to shoot (TakeShot)")
		}
		panic("shots: it is your turn to keep (SubmitKeeperPlan)")
	}
	h := runtime.ChainHeight()
	now := time.Now().UnixNano()
	seed := entropy(g, s, now)
	k := shootout.Kick{
		Round:  s.Score.Round(),
		Kicker: kicker,
		Seed:   seed,
		Height: h,
		Time:   now,
	}
	if kicker == penalty.SidePlayer {
		// The player shoots; the seed is the chain's keeper and the mishit.
		k.Shot = shot.WithMishit(seed.Mishit())
		k.Plan = seed.KeeperPlan()
	} else {
		// The player keeps; the seed is the chain's kick and its mishit.
		k.Shot = seed.ChainShot(g.Config).WithMishit(seed.Mishit())
		k.Plan = plan
	}
	k.Result = e.SimulateShot(k.Shot, k.Plan, g.Config)
	s.Kicks = append(s.Kicks, k)
	s.Score.Record(kicker, k.Result.Outcome.Scored())
	s.LastActionHeight = h
	chain.Emit("Kick", "game", u64(g.ID), "session", strconv.Itoa(s.No), "round", strconv.Itoa(k.Round),
		"kicker", kicker.String(), "outcome", k.Result.Outcome.String(), "seed", seed.Hex())

	switch s.Score.Winner() {
	case penalty.SidePlayer:
		prize := g.Pot
		s.Status = shootout.SessionWon
		s.EndHeight = h
		g.Pot = 0
		g.Status = shootout.GameWon
		g.Winner = s.Player
		g.ClosedHeight = h
		st.PutGame(g)
		st.PutSession(s)
		st.Pay(s.Player, prize)
		chain.Emit("PotWon", "game", u64(g.ID), "session", strconv.Itoa(s.No), "player", string(s.Player),
			"prize", itoa(prize))
		return k
	case penalty.SideChain:
		s.Status = shootout.SessionLost
		s.EndHeight = h
		g.Status = shootout.GameOpen
		chain.Emit("SessionLost", "game", u64(g.ID), "session", strconv.Itoa(s.No), "player", string(s.Player),
			"pot", itoa(g.Pot))
	}
	st.PutGame(g)
	st.PutSession(s)
	return k
}

func (e *engine) Forfeit(_ int, rlm realm, caller address, gameID uint64) {
	st := shots.Store(0, rlm)
	g := mustGame(st, gameID)
	if g.Status != shootout.GamePlaying {
		panic("shots: nobody is playing game " + u64(gameID))
	}
	s, _ := session(st, gameID, g.Sessions)
	h := runtime.ChainHeight()
	if caller != s.Player && h-s.LastActionHeight <= g.TimeoutBlocks {
		panic("shots: the player has " + itoa(g.TimeoutBlocks-(h-s.LastActionHeight)+1) +
			" more blocks before they can be forfeited")
	}
	s.Status = shootout.SessionForfeited
	s.EndHeight = h
	g.Status = shootout.GameOpen
	st.PutGame(g)
	st.PutSession(s)
	chain.Emit("SessionForfeited", "game", u64(gameID), "session", strconv.Itoa(s.No),
		"player", string(s.Player), "by", string(caller), "pot", itoa(g.Pot))
}

// entropy is the kick's 32-byte seed: SHA-256 of the block time and the
// kick's identity (see the package comment for what that does and does not
// guarantee).
func entropy(g shootout.Game, s shootout.Session, blockTime int64) penalty.Seed {
	var b [8]byte
	for i := 0; i < 8; i++ {
		b[i] = byte(uint64(blockTime) >> (56 - 8*uint(i)))
	}
	id := "|" + u64(g.ID) + "|" + strconv.Itoa(s.No) + "|" + strconv.Itoa(len(s.Kicks))
	return penalty.Seed(sha256.Sum256(append(b[:], []byte(id)...)))
}

// ---------------------------------------------------------------- helpers

func mustGame(st *shots.StateRef, id uint64) shootout.Game {
	g, ok := st.Game(id)
	if !ok {
		panic("shots: no game " + u64(id))
	}
	return ownGame(g)
}

// session reads the live session of a game as this realm's own copy.
func session(st *shots.StateRef, id uint64, no int) (shootout.Session, bool) {
	s, ok := st.Session(id, no)
	if !ok {
		return s, false
	}
	return ownSession(s), true
}

// ownGame and ownSession rebuild values read through shots.Store in this
// realm. What Store hands back was allocated by the shots realm, and the VM
// refuses writes to another realm's objects (a pointer-method update such as
// Shootout.Record trips its cross-realm check), so the engine only ever
// mutates copies it built itself; PutGame/PutSession copy them back.
func ownGame(g shootout.Game) shootout.Game {
	return shootout.Game{
		ID:            g.ID,
		Creator:       g.Creator,
		Config:        g.Config,
		EntryFee:      g.EntryFee,
		TimeoutBlocks: g.TimeoutBlocks,
		Pot:           g.Pot,
		Status:        g.Status,
		Sessions:      g.Sessions,
		Winner:        g.Winner,
		CreatedHeight: g.CreatedHeight,
		ClosedHeight:  g.ClosedHeight,
	}
}

func ownSession(s shootout.Session) shootout.Session {
	kicks := make([]shootout.Kick, len(s.Kicks))
	for i := range s.Kicks {
		kicks[i] = s.Kicks[i]
	}
	return shootout.Session{
		GameID: s.GameID,
		No:     s.No,
		Player: s.Player,
		Paid:   s.Paid,
		Score: penalty.Shootout{
			PlayerKicks: s.Score.PlayerKicks,
			PlayerGoals: s.Score.PlayerGoals,
			ChainKicks:  s.Score.ChainKicks,
			ChainGoals:  s.Score.ChainGoals,
		},
		Kicks:            kicks,
		Status:           s.Status,
		JoinHeight:       s.JoinHeight,
		LastActionHeight: s.LastActionHeight,
		EndHeight:        s.EndHeight,
	}
}

func mustPlayersSession(st *shots.StateRef, gameID uint64, player address) (shootout.Game, shootout.Session) {
	g := mustGame(st, gameID)
	if g.Status != shootout.GamePlaying {
		panic("shots: nobody is playing game " + u64(gameID) + "; join it first")
	}
	s, ok := session(st, gameID, g.Sessions)
	if !ok || s.Player != player {
		panic("shots: you are not the challenger in game " + u64(gameID))
	}
	if s.Status != shootout.SessionPlaying {
		panic("shots: your shootout in game " + u64(gameID) + " is over")
	}
	return g, s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
func u64(n uint64) string { return strconv.FormatUint(n, 10) }
