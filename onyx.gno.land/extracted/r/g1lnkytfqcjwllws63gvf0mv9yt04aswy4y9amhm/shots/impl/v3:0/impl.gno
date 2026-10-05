// Package impl is the third rules engine for gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shots:
// impl/v2 with a chain that plays well, a pot that must be won by two goals,
// and a share of it for the game's creator.
//
// It owns the game state machine and pot rules; the state itself, and the
// coins, stay in the shots realm, reached through shots.Store.
//
// THE CHAIN'S PLAY. impl/v1 and v2 read the chain's keeper plan and kick as
// uniform draws from the seed, which a player who has learnt the best shot
// and keeper plan beats about 97% of the time. Here the seed's first two bytes
// pick the chain's move from equilibrium mixes, worked out with the physics
// engine for the default constants (chainKeeper, chainKicks): against them
// no shot scores more than about 79%, and no keeper plan concedes less than
// about 77%, roughly the conversion rate of real penalties. Games with other
// constants use the same mixes, kicks scaled to their goal and plans kept in
// their mode (see keeperFor and kickFor), so they are only near equilibrium;
// a game may therefore change only four constants, a little (see
// checkConstants).
//
// THE POT. Each game's creator chooses how much a challenger must win by
// (winBy in the config string, 1..3, DefaultWinBy if left out; WinBy reads
// it). Win by 1 is a normal shootout: five kicks each, ending as soon as one
// side cannot be caught, then sudden death. Win by 2 or 3 is five kicks each
// at most with no sudden death, won only by that many goals, ending as soon as
// that is certain either way. Against the chain above, a player who plays the
// best moves wins about 47%, 11% or 2.3% of shootouts, one who plays at
// random about 9.5%, 1.5% or 0.2%: the larger the margin, the longer a pot
// grows before it is won. The winner is paid all of it but CreatorPercent,
// which goes to the game's creator for having put up the seed pot. Games
// created before this implementation keep the rules they were made with: win
// by 1.
//
// SETTLING. Every kick is recorded in the session while it is played (its ten
// inputs, seed and result: about 3 KB, paid for by the player's storage
// deposit). When the shootout ends (won, lost or forfeited) the session is
// rewritten without its kicks, keeping player, entry fee, score, status and
// heights, and a won game keeps its pot (the prize it paid) and winner. The
// deposit for the bytes freed goes back to the account that made the final
// move: on the deciding kick, the player (on a chain whose ugnot is
// transfer-restricted, the storage fee collector instead). Each kick remains
// in the transaction that played it, as that call's return value and Kick
// event, so it can still be re-run from the chain's history; shots'
// VerifySession has nothing left to re-run for a settled shootout.
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
	"strings"
	"time"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/physics/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shootout/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shots"
)

const (
	RegulationKicks = 5 // kicks each side takes before sudden death (win by 1), or at most
	DefaultWinBy    = 2 // goals a challenger must win by, unless the creator chose 1 or 3
	MaxWinBy        = 3
	CreatorPercent  = 20 // of the pot, paid to the game's creator when it is won

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
	return "impl/v3: Spot Kick physics (penalty/physics/v0, bit-identical to the browser engine), seed = SHA-256 of the block time; " +
		"the chain plays equilibrium mixes; each game's pot is won by 1, 2 or 3 goals (its creator's choice), " + itoa(CreatorPercent) +
		"% of it to the creator; an ended shootout keeps only its score"
}

func (e *engine) SimulateShot(shot penalty.ShotParams, plan penalty.KeeperPlan, cfg penalty.Config) penalty.Result {
	return physics.SimulateShot(shot, plan, cfg)
}

// ---------------------------------------------------------------- games

func (e *engine) CreateGame(_ int, rlm realm, creator address, deposit, entryFee, timeoutBlocks int64, config string) uint64 {
	winBy, config := takeWinBy(config)
	cfg, err := penalty.ParseConfig(config)
	if err != nil {
		panic(err)
	}
	if msg := checkConstants(cfg); msg != "" {
		panic("shots: " + msg)
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
	setWinBy(cross(rlm), g.ID, winBy)
	chain.Emit("GameCreated", "game", u64(g.ID), "creator", string(creator), "pot", itoa(deposit),
		"entryFee", itoa(entryFee), "config", cfg.String(), "winBy", strconv.Itoa(winBy))
	return g.ID
}

// winBys holds each game's margin (the shots realm's Game has no field for
// it, and its type cannot change); a later implementation reads it through
// WinBy.
var winBys = avl.NewTree() // game id -> int

// WinBy is how many goals a challenger must win game gameID by: as chosen at
// creation, or 1 for a game created before this implementation.
func WinBy(gameID uint64) int {
	if v := winBys.Get(u64(gameID)); v != nil {
		return v.(int)
	}
	return 1
}

// setWinBy records a new game's margin. It crosses into this realm: the
// engine's methods run as the shots realm, which may not write this realm's
// table.
func setWinBy(cur realm, gameID uint64, winBy int) {
	winBys.Set(u64(gameID), winBy)
}

// takeWinBy removes "winBy=N" from a config string, returning N (DefaultWinBy
// if absent) and the rest for penalty.ParseConfig.
func takeWinBy(config string) (int, string) {
	winBy := DefaultWinBy
	rest := []string{}
	for _, kv := range strings.Split(config, ",") {
		k := strings.TrimSpace(kv)
		if !strings.HasPrefix(k, "winBy=") {
			if k != "" {
				rest = append(rest, k)
			}
			continue
		}
		n, err := strconv.Atoi(strings.TrimSpace(k[len("winBy="):]))
		if err != nil || n < 1 || n > MaxWinBy {
			panic("shots: winBy must be 1, 2 or 3")
		}
		winBy = n
	}
	return winBy, strings.Join(rest, ",")
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
		// The player shoots; the seed picks the chain's keeper plan and is
		// the mishit.
		k.Shot = shot.WithMishit(seed.Mishit())
		k.Plan = keeperFor(seed, g.Config)
	} else {
		// The player keeps; the seed picks the chain's kick and its mishit.
		k.Shot = kickFor(seed, g.Config).WithMishit(seed.Mishit())
		k.Plan = plan
	}
	k.Result = e.SimulateShot(k.Shot, k.Plan, g.Config)
	s.Kicks = append(s.Kicks, k)
	// Scored here rather than with penalty.Shootout.Record, whose rules (a
	// win by one, sudden death) would call some win-by-2 or 3 shootouts over
	// that are not.
	if kicker == penalty.SidePlayer {
		s.Score.PlayerKicks++
		if k.Result.Outcome.Scored() {
			s.Score.PlayerGoals++
		}
	} else {
		s.Score.ChainKicks++
		if k.Result.Outcome.Scored() {
			s.Score.ChainGoals++
		}
	}
	s.LastActionHeight = h
	chain.Emit("Kick", "game", u64(g.ID), "session", strconv.Itoa(s.No), "round", strconv.Itoa(k.Round),
		"kicker", kicker.String(), "outcome", k.Result.Outcome.String(), "seed", seed.Hex())

	switch decided(s.Score, WinBy(g.ID)) {
	case penalty.SidePlayer:
		// The pot is paid out, CreatorPercent of it to the creator, and kept
		// on the closed game as the prize it paid (see SETTLING).
		prize := g.Pot
		cut := prize * CreatorPercent / 100
		s.Status = shootout.SessionWon
		s.EndHeight = h
		g.Status = shootout.GameWon
		g.Winner = s.Player
		g.ClosedHeight = h
		st.PutGame(g)
		st.PutSession(settled(s))
		st.Pay(s.Player, prize-cut)
		st.Pay(g.Creator, cut)
		chain.Emit("PotWon", "game", u64(g.ID), "session", strconv.Itoa(s.No), "player", string(s.Player),
			"prize", itoa(prize), "winnerShare", itoa(prize-cut), "creator", string(g.Creator), "creatorShare", itoa(cut))
		return k
	case penalty.SideChain:
		s.Status = shootout.SessionLost
		s.EndHeight = h
		g.Status = shootout.GameOpen
		st.PutGame(g)
		st.PutSession(settled(s))
		chain.Emit("SessionLost", "game", u64(g.ID), "session", strconv.Itoa(s.No), "player", string(s.Player),
			"pot", itoa(g.Pot))
		return k
	}
	st.PutGame(g)
	st.PutSession(s)
	return k
}

// checkConstants allows a game four small changes from the default
// constants, and nothing else: the chain's mixes are the equilibrium of the
// default game, and every change opens a gap a skilled player can use. Within
// these ranges a player who plays the best moves wins 11-14% of shootouts
// (against 11% under the defaults); outside them up to 40%, which no pot
// survives. The ranges, as the web client offers them:
//
//	goal width     goalWidth 6400..7000 mm
//	keeper size    keeperScale 1117..1235 (95..105% of 1176)
//	keeper agility diveMin and diveMax at 90..105% of 2600 and 5200, together
//	               (diveMax = 2 x diveMin)
//	shot speed     ballMaxSpeed 34000..37400 mm/s (100..110%)
//
// It returns why cfg is refused, or "".
func checkConstants(cfg penalty.Config) string {
	def := penalty.DefaultConfig()
	if cfg.GoalWidth < 6400 || cfg.GoalWidth > 7000 {
		return "goal width must be 6400..7000 mm"
	}
	if cfg.KeeperScale < 1117 || cfg.KeeperScale > 1235 {
		return "keeper size must be 1117..1235 (95..105%)"
	}
	if cfg.DiveMax < 4680 || cfg.DiveMax > 5460 || cfg.DiveMin*2 != cfg.DiveMax {
		return "keeper agility: diveMax must be 4680..5460 mm/s and diveMin half of it"
	}
	if cfg.BallMaxSpeed < 34000 || cfg.BallMaxSpeed > 37400 {
		return "shot speed: ballMaxSpeed must be 34000..37400 mm/s"
	}
	rest := cfg
	rest.GoalWidth, rest.KeeperScale, rest.DiveMin, rest.DiveMax, rest.BallMaxSpeed =
		def.GoalWidth, def.KeeperScale, def.DiveMin, def.DiveMax, def.BallMaxSpeed
	if rest != def {
		return "only goal width, keeper size, keeper agility and shot speed may differ from the defaults (" + def.String() + ")"
	}
	return ""
}

// decided says whether a shootout is over, and who won it. Win by 1 is a
// normal shootout (penalty.Shootout's rules, sudden death included). For a
// larger margin it is SidePlayer once the player is sure to finish winBy goals
// ahead after RegulationKicks each, SideChain once they no longer can, and 0
// while it is open.
func decided(sc penalty.Shootout, winBy int) penalty.Side {
	if winBy <= 1 {
		return sc.Winner()
	}
	playerLeft := RegulationKicks - sc.PlayerKicks
	chainLeft := RegulationKicks - sc.ChainKicks
	if sc.PlayerGoals-(sc.ChainGoals+chainLeft) >= winBy {
		return penalty.SidePlayer
	}
	if sc.PlayerGoals+playerLeft-sc.ChainGoals < winBy {
		return penalty.SideChain
	}
	return 0
}

// settled is an ended session as it stays on chain: everything but its
// kicks (see SETTLING).
func settled(s shootout.Session) shootout.Session {
	s.Kicks = nil
	return s
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
	st.PutSession(settled(s))
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

// ---------------------------------------------------------------- the chain's play

// chainPlan is a keeper plan of the chain's mix: cum is the cumulative weight
// out of 65536 (the seed's first two bytes pick the first entry above them),
// the rest the plan's four uint16 under the default constants.
type chainPlan struct {
	cum                              uint32
	direction, speed, jump, reaction uint16
}

// chainKick is a kick of the chain's mix, in the realm's units for the
// default goal: aim mm, contact milli-radii, power per-mille.
type chainKick struct {
	cum                                   uint32
	aimX, aimY, contactX, contactY, power int64
}

// The equilibrium mixes for the default constants (a double-oracle solution
// of the shooter-keeper game on the physics engine; the value is a 78.5%
// conversion rate). Plans: a third wait and read the shot; the rest dive
// fast across the goal, mid-height or low. Kicks: low and hard 2.2 m out, top
// corners, high down the middle.
var chainKeeper = []chainPlan{
	{22080, 32768, 11796, 32768, 0},     // 33.7% wait and read
	{35198, 31457, 58650, 32768, 19661}, // 20.0%
	{48315, 34078, 58650, 32768, 19661}, // 20.0%
	{56642, 31457, 65530, 0, 0},         // 12.7%
	{64968, 34078, 65530, 0, 0},         // 12.7%
	{65252, 31457, 65530, 32768, 32768}, // 0.4%
	{65536, 34078, 65530, 32768, 32768}, // 0.4%
}

var chainKicks = []chainKick{
	{13504, 2200, 150, 0, -100, 1000},     // 20.6%
	{27008, -2200, 150, 0, -100, 1000},    // 20.6%
	{33589, 3200, 2250, 250, -100, 850},   // 10.0%
	{40169, -3200, 2250, -250, -100, 850}, // 10.0%
	{46362, 3300, 2150, 250, -100, 850},   // 9.4%
	{52554, -3300, 2150, -250, -100, 850}, // 9.4%
	{58145, 100, 2250, 0, 50, 1000},       // 8.5%
	{63737, -100, 2250, 0, 50, 1000},      // 8.5%
	{64636, 2100, 1450, 0, -100, 1000},    // 1.4%
	{65536, -2100, 1450, 0, -100, 1000},   // 1.4%
}

// pick is the index of the first entry whose cumulative weight is above u.
func pick(u uint32, cum func(i int) uint32, n int) int {
	for i := 0; i < n; i++ {
		if u < cum(i) {
			return i
		}
	}
	return n - 1
}

func seedU16(s penalty.Seed) uint32 { return uint32(s[0])<<8 | uint32(s[1]) }

// keeperFor is the chain's keeper plan for a kick. Under constants with other
// mode bands (StarShare, ReadShare) a plan keeps its mode: a read stays a
// read, and a dive keeps its place within the dive band.
func keeperFor(seed penalty.Seed, c penalty.Config) penalty.KeeperPlan {
	p := chainKeeper[pick(seedU16(seed), func(i int) uint32 { return chainKeeper[i].cum }, len(chainKeeper))]
	speed := p.speed
	if c.StarShare != 60 || c.ReadShare != 240 {
		const defRead = 19660 // 30% of 65535: the default read band ends here
		star := uint32(c.StarShare) * 65535 / 1000
		read := uint32(c.StarShare+c.ReadShare) * 65535 / 1000
		if p.speed < defRead {
			speed = uint16((star + read) / 2)
		} else {
			speed = uint16(read + (uint32(p.speed)-defRead)*(65535-read)/(65535-defRead))
		}
	}
	return penalty.KeeperPlan{Direction: p.direction, Speed: speed, Jump: p.jump, Reaction: p.reaction}
}

// kickFor is the chain's kick, its aim scaled to the game's goal and its
// contact kept inside the game's selectable disc.
func kickFor(seed penalty.Seed, c penalty.Config) penalty.ShotInput {
	k := chainKicks[pick(seedU16(seed), func(i int) uint32 { return chainKicks[i].cum }, len(chainKicks))]
	in := penalty.ShotInput{
		AimX:     k.aimX * c.GoalWidth / 6555,
		AimY:     k.aimY * c.GoalHeight / 2424,
		ContactX: k.contactX,
		ContactY: k.contactY,
		Power:    k.power,
	}
	if r2 := in.ContactX*in.ContactX + in.ContactY*in.ContactY; r2 > c.MaxContact*c.MaxContact {
		r := isqrt(r2)
		in.ContactX = in.ContactX * c.MaxContact / r
		in.ContactY = in.ContactY * c.MaxContact / r
	}
	return in
}

func isqrt(n int64) int64 {
	if n <= 0 {
		return 0
	}
	x := n
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}
