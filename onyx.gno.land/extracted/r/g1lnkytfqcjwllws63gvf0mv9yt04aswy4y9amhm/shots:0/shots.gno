// Package shots is a pay-to-play penalty shootout against the chain.
//
// A creator opens a game by choosing its keeper and ball constants and
// seeding the pot. A challenger joins an open game by paying its entry fee
// into the pot, then plays a shootout: in every round they take a kick
// (TakeShot) and then keep against the chain's kick (SubmitKeeperPlan). Five
// kicks each, finishing early when one side cannot be caught, then sudden
// death. Win, and the whole pot is paid out; lose, and the entry fee stays in
// the pot for the next challenger.
//
// Every kick is played out in the transaction that makes it: the player's
// choices are completed by 32 bytes derived from the block's timestamp (the
// chain's move and the mishit), and the outcome is penalty.SimulateShot of the
// ten inputs, recorded so anyone can re-run it. See impl/v1 for what that
// entropy does and does not guarantee.
//
// This realm's path and entry points are permanent. The rules engine is an
// implementation realm behind an upgradeable proxy
// (gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0); the games and their pots live here
// and survive every upgrade.
package shots

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shootout/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0"
)

// Impl is the rules engine. Declared here so every version agrees on one
// type identity. The methods are non-crossing: this realm threads its own cur
// in, so an implementation reaching Store is seen as this realm.
//
// The caller's address and the coins received are established by the entry
// points below and passed in; an implementation cannot be invoked with forged
// ones from elsewhere, because without this realm's live cur it cannot reach
// the state at all.
type Impl interface {
	CreateGame(_ int, rlm realm, creator address, deposit, entryFee, timeoutBlocks int64, config string) uint64
	JoinGame(_ int, rlm realm, player address, gameID uint64, paid int64)
	TopUp(_ int, rlm realm, from address, gameID uint64, paid int64)
	TakeShot(_ int, rlm realm, player address, gameID uint64, shot penalty.ShotInput) shootout.Kick
	SubmitKeeperPlan(_ int, rlm realm, player address, gameID uint64, plan penalty.KeeperPlan) shootout.Kick
	Forfeit(_ int, rlm realm, caller address, gameID uint64)
	CancelGame(_ int, rlm realm, caller address, gameID uint64)

	// SimulateShot is the pure outcome function: six taker inputs (in shot,
	// mishit seed included) and four keeper inputs, under cfg.
	SimulateShot(shot penalty.ShotParams, plan penalty.KeeperPlan, cfg penalty.Config) penalty.Result

	// Describe names the implementation for Render.
	Describe() string
}

// Denom is the coin pots are held in.
const Denom = "ugnot"

// Admin may accept, roll back or freeze an implementation. The value is the
// standard test1 account so the tests run unedited; set your own address
// before deploying (TransferAuthority moves it afterwards).
const Admin = address("g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm")

var (
	proxy    *upgradeable.Proxy
	selfPath string
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	proxy = upgradeable.New(upgradeable.NewAddrAuthority(Admin))
}

// ---------------------------------------------------------------- playing

// CreateGame opens a game. Send the initial pot with the call (ugnot).
// config overrides the default constants as "key=value,..." ("" for the
// defaults; see penalty.ParseConfig). timeoutBlocks 0 picks the default.
// Returns the game id.
func CreateGame(cur realm, entryFee, timeoutBlocks int64, config string) uint64 {
	paid := receivePayment(0, cur)
	return live().CreateGame(0, cur, cur.Previous().Address(), paid, entryFee, timeoutBlocks, config)
}

// JoinGame starts a shootout in an open game. Send exactly its entry fee.
func JoinGame(cur realm, gameID uint64) {
	paid := receivePayment(0, cur)
	live().JoinGame(0, cur, cur.Previous().Address(), gameID, paid)
}

// TopUp adds the coins sent to a game's pot.
func TopUp(cur realm, gameID uint64) {
	paid := receivePayment(0, cur)
	live().TopUp(0, cur, cur.Previous().Address(), gameID, paid)
}

// TakeShot plays the player's kick for the current round against the chain's
// keeper: aim point on the goal plane (mm), contact offset on the ball
// (milli-radii) and power (per-mille). Returns the kick as JSON.
func TakeShot(cur realm, gameID uint64, aimX, aimY, contactX, contactY, power int64) string {
	assertFreeDirectCall(0, cur)
	shot := penalty.ShotInput{AimX: aimX, AimY: aimY, ContactX: contactX, ContactY: contactY, Power: power}
	return kickJSON(live().TakeShot(0, cur, cur.Previous().Address(), gameID, shot))
}

// SubmitKeeperPlan plays the player's keeper plan against the chain's kick
// for the current round: four uint16 (see penalty.DecodePlan). Returns the
// kick as JSON.
func SubmitKeeperPlan(cur realm, gameID uint64, direction, speed, jump, reaction uint16) string {
	assertFreeDirectCall(0, cur)
	plan := penalty.KeeperPlan{Direction: direction, Speed: speed, Jump: jump, Reaction: reaction}
	return kickJSON(live().SubmitKeeperPlan(0, cur, cur.Previous().Address(), gameID, plan))
}

// Forfeit ends the current shootout as a loss: the player may resign at any
// time, anyone else once the player has been idle for the game's timeout.
func Forfeit(cur realm, gameID uint64) {
	assertFreeDirectCall(0, cur)
	live().Forfeit(0, cur, cur.Previous().Address(), gameID)
}

// CancelGame refunds the pot to the creator of a game nobody has played yet.
func CancelGame(cur realm, gameID uint64) {
	assertFreeDirectCall(0, cur)
	live().CancelGame(0, cur, cur.Previous().Address(), gameID)
}

// ---------------------------------------------------------------- reading

// SimulateShot runs the live outcome function on ten inputs, without touching
// any state: the taker's aim, contact, power and 48-hex-char mishit seed, and
// the keeper's four uint16, under config ("" for the defaults). Returns JSON.
func SimulateShot(aimX, aimY, contactX, contactY, power int64, mishitHex string,
	direction, speed, jump, reaction uint16, config string) string {
	cfg, err := penalty.ParseConfig(config)
	if err != nil {
		panic(err)
	}
	m, ok := penalty.ParseMishitHex(mishitHex)
	if !ok {
		panic("shots: mishit seed must be 48 hex characters")
	}
	shot := penalty.ShotInput{AimX: aimX, AimY: aimY, ContactX: contactX, ContactY: contactY, Power: power}.WithMishit(m)
	plan := penalty.KeeperPlan{Direction: direction, Speed: speed, Jump: jump, Reaction: reaction}
	return resultJSON(live().SimulateShot(shot, plan, cfg))
}

// GameJSON returns game id as JSON ("" if it does not exist).
func GameJSON(gameID uint64) string {
	g, ok := getGame(gameID)
	if !ok {
		return ""
	}
	return gameJSON(g)
}

// SessionJSON returns session no of a game, kicks included, as JSON.
func SessionJSON(gameID uint64, no int) string {
	s, ok := getSession(gameID, no)
	if !ok {
		return ""
	}
	return sessionJSON(s)
}

// ListGames returns up to limit games as a JSON array, newest first,
// optionally filtered by status ("open", "playing", "won", "cancelled"; ""
// for all).
func ListGames(status string, offset, limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	out := []string{}
	skipped := 0
	games.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*shootout.Game)
		if status != "" && g.Status.String() != status {
			return false
		}
		if skipped < offset {
			skipped++
			return false
		}
		out = append(out, gameJSON(*g))
		return len(out) >= limit
	})
	return "[" + strings.Join(out, ",") + "]"
}

// VerifySession re-runs every recorded kick of a shootout through the live
// outcome function and reports whether all of them reproduce, so anyone can
// check a result from the ten recorded inputs alone.
func VerifySession(gameID uint64, no int) bool {
	g, ok := getGame(gameID)
	if !ok {
		return false
	}
	s, ok := getSession(gameID, no)
	if !ok {
		return false
	}
	im := live()
	for _, k := range s.Kicks {
		if im.SimulateShot(k.Shot, k.Plan, g.Config) != k.Result {
			return false
		}
	}
	return true
}

// GameCount returns how many games have been created.
func GameCount() uint64 { return lastID }

// ---------------------------------------------------------------- guards

// receivePayment returns the ugnot sent with a direct user call. The coin
// envelope is credited to this realm only when this realm is the message's
// target, so a payment from any other call shape is refused rather than
// trusted.
func receivePayment(_ int, rlm realm) int64 {
	assertDirect(0, rlm)
	var amount int64
	for _, c := range unsafe.OriginSend() {
		if c.Denom != Denom {
			panic("shots: only " + Denom + " is accepted, got " + c.Denom)
		}
		amount += c.Amount
	}
	return amount
}

// assertFreeDirectCall requires a direct user call that sends no coins.
func assertFreeDirectCall(_ int, rlm realm) {
	assertDirect(0, rlm)
	if len(unsafe.OriginSend()) > 0 {
		panic("shots: this call does not accept coins")
	}
}

func assertDirect(_ int, rlm realm) {
	if !rlm.IsCurrent() || !rlm.Previous().IsUserCall() {
		panic("shots: call this directly from an account (no run scripts or other realms)")
	}
}

// ---------------------------------------------------------------- upgrades

// Register records the calling realm as a candidate implementation; an
// implementation calls it from its own init. Nothing serves until Accept.
func Register(cur realm, impl Impl) { proxy.Propose(0, cur, impl) }

// Accept makes the candidate at pkgPath live. Authority only.
func Accept(cur realm, pkgPath string) { proxy.Accept(0, cur, pkgPath) }

// Withdraw drops a candidate. Authority only, or the candidate itself.
func Withdraw(cur realm, pkgPath string) { proxy.Withdraw(0, cur, pkgPath) }

// Rollback restores the previous implementation. Authority only.
func Rollback(cur realm) { proxy.Rollback(0, cur) }

// Forget drops the rollback history. Authority only.
func Forget(cur realm) { proxy.Forget(0, cur) }

// Freeze ends upgradeability permanently. Authority only.
func Freeze(cur realm) { proxy.Freeze(0, cur) }

// AddExtension lets another realm act as this one. Authority only.
func AddExtension(cur realm, pkgPath string) { proxy.AddExtension(0, cur, pkgPath) }

// DropExtension revokes one. Authority only.
func DropExtension(cur realm, pkgPath string) { proxy.DropExtension(0, cur, pkgPath) }

// TransferAuthority hands the power to upgrade to another address.
func TransferAuthority(cur realm, newOwner address) {
	proxy.TransferAuthority(0, cur, upgradeable.NewAddrAuthority(newOwner))
}

// TransferAuthorityToRealms hands it to governance realms (comma-separated).
func TransferAuthorityToRealms(cur realm, csvPaths string) {
	paths := []string{}
	for _, p := range strings.Split(csvPaths, ",") {
		paths = append(paths, strings.TrimSpace(p))
	}
	proxy.TransferAuthority(0, cur, upgradeable.NewRealmAuthority(paths...))
}

func LivePath() string     { return proxy.LivePath() }
func Frozen() bool         { return proxy.Frozen() }
func Authority() string    { return proxy.Authority().String() }
func Extensions() []string { return proxy.Extensions() }

func PendingPaths() []string {
	out := []string{}
	for _, r := range proxy.Pending() {
		out = append(out, r.PkgPath())
	}
	return out
}

func HistoryPaths() []string {
	out := []string{}
	for _, r := range proxy.History() {
		out = append(out, r.PkgPath())
	}
	return out
}

func live() Impl {
	v, ok := proxy.TryImpl()
	if !ok {
		panic("shots: no implementation has been accepted yet")
	}
	im, ok := v.(Impl)
	if !ok {
		panic("shots: live implementation does not satisfy Impl")
	}
	return im
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
