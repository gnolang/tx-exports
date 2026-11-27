// Package duels implements Tavern Duel Arena: a commit-reveal wagering
// game on Gno.land.
//
// Two players stake the same amount of GNOT on a tavern-brawl match
// (Ale vs Broom vs Dagger, a rock-paper-scissors cycle):
//
//	🍺 Ale      beats 🧹 Broom   (spills everywhere)
//	🧹 Broom    beats 🗡️ Dagger  (sweeps it away)
//	🗡️ Dagger   beats 🍺 Ale     (stabs the keg)
//
// Fairness comes from a commit-reveal scheme, so neither player can
// see or react to the other's move:
//
//  1. Creator opens a duel with a commitment: sha256("<move>:<salt>")
//     and the stake, sent as native coins (gnokey maketx call -send).
//  2. Opponent joins with the exact same stake and their own commitment.
//  3. Both reveal (move + salt). The realm verifies each reveal against
//     the stored commitment and pays the winner the pot minus rake.
//  4. Timeouts protect stakes: an unjoined duel is refundable by its
//     creator, a silent revealer forfeits the pot to the player who
//     did reveal, and if nobody reveals both stakes are refunded.
//
// The realm also serves its UI through gnoweb (see Render below).
package duels

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"

	"gno.land/p/jeronimoalbi/mdform/v0"
	"gno.land/p/moul/md/v0"
	"gno.land/p/moul/mdtable/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/mdalert/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

// ---- game parameters -------------------------------------------------------

const (
	// Denom is the only accepted staking denomination.
	Denom = "ugnot"
	// MinStake / MaxStake bound the stake, per player, in ugnot.
	MinStake int64 = 1_000_000     // 0.001 GNOT
	MaxStake int64 = 1_000_000_000 // 1 GNOT
	// MinWindow / MaxWindow bound the admin-adjustable deadlines.
	MinWindow = 10
	MaxWindow = 100_000
	// MaxRakeBps caps the house rake at 10%.
	MaxRakeBps = 1_000
)

// Defaults for the admin-adjustable parameters.
const (
	defaultJoinWindow   = 300 // blocks to wait for an opponent
	defaultRevealWindow = 300 // blocks to reveal after both are in
	defaultRakeBps      = 250 // 2.5%
)

// webRoot is this realm's URL path inside gnoweb, used to build links.
const webRoot = "r/g196ke3ypjh04jts7qjez74cgsd09ufuednn2f3m/duels"

// Tavern brawl moves, forming a rock-paper-scissors cycle.
const (
	MoveAle    = 0 // 🍺
	MoveBroom  = 1 // 🧹
	MoveDagger = 2 // 🗡️
)

// Duel phases.
const (
	PhaseOpen   uint8 = 0 // created, waiting for an opponent
	PhaseReveal uint8 = 1 // both players committed, revealing
	PhaseDone   uint8 = 2 // resolved, refunded or expired
)

// Duel results.
const (
	ResultCreator = "creator"
	ResultJoiner  = "joiner"
	ResultTie     = "tie"
	ResultExpired = "expired"
)

// ---- realm state -----------------------------------------------------------

var (
	duels        avl.Tree // decimal duel id -> *Duel
	stats        avl.Tree // address string -> *Stats
	nextID       uint64
	joinWindow   = int64(defaultJoinWindow)
	revealWindow = int64(defaultRevealWindow)
	rakeBps      = int64(defaultRakeBps)
	escrow       int64  // ugnot held on behalf of live duels
	treasury     int64  // ugnot of accumulated rake, withdrawable by admin
	volume       int64  // ugnot wagered in resolved duels
	duelsPlayed  uint64 // number of resolved duels
	admin        address
	hasAdmin     bool
)

// Duel is one match between two players.
type Duel struct {
	id      uint64
	creator address
	joiner  address
	stake   int64 // ugnot per player

	creatorCommit string
	joinerCommit  string
	creatorMove   int // -1 until revealed
	joinerMove    int

	phase          uint8
	joinDeadline   int64
	revealDeadline int64
	createdHeight  int64
	resolvedHeight int64

	result string // ResultCreator, ResultJoiner, ResultTie or ResultExpired
	payout int64  // ugnot paid to the winner (0 on tie/expiry)
	rake   int64  // ugnot taken by the house
}

// Stats tracks a player's lifetime record.
type Stats struct {
	duels   int64
	wins    int64
	losses  int64
	draws   int64
	wagered int64
	won     int64
}

// ---- admin -----------------------------------------------------------------

// Init records the realm administrator. Call it once, from the deployer,
// right after deployment. The admin may tune the windows and rake and
// withdraw accumulated rake; it has no access to player stakes.
func Init(cur realm) {
	require(cur.Previous().IsUserCall(), "only user-call accepted")
	require(!hasAdmin, "already initialized")
	admin = cur.Previous().Address()
	hasAdmin = true
	chain.Emit("DuelsInit", "admin", admin.String())
}

// Admin returns the realm administrator, or "" before Init.
func Admin() address {
	return admin
}

// SetWindows adjusts the join and reveal deadlines, in blocks.
func SetWindows(cur realm, joinBlocks, revealBlocks int64) {
	assertAdmin(cur)
	require(joinBlocks >= MinWindow && joinBlocks <= MaxWindow, "join window out of bounds")
	require(revealBlocks >= MinWindow && revealBlocks <= MaxWindow, "reveal window out of bounds")
	joinWindow = joinBlocks
	revealWindow = revealBlocks
	chain.Emit("WindowsUpdated", "join", strconv.FormatInt(joinBlocks, 10), "reveal", strconv.FormatInt(revealBlocks, 10))
}

// SetRakeBps adjusts the house rake, in basis points, capped at 10%.
func SetRakeBps(cur realm, bps uint16) {
	assertAdmin(cur)
	require(int64(bps) <= MaxRakeBps, "rake capped at 10%")
	rakeBps = int64(bps)
	chain.Emit("RakeUpdated", "bps", strconv.FormatUint(uint64(bps), 10))
}

// WithdrawTreasury sends accumulated rake to the given address. Player
// stakes in escrow are never touched: treasury ≤ realm balance - escrow.
func WithdrawTreasury(cur realm, to address, amount int64) {
	assertAdmin(cur)
	require(to.IsValid(), "invalid recipient")
	require(amount > 0 && amount <= treasury, "amount exceeds treasury")
	bank := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bank.SendCoins(cur.Address(), to, chain.Coins{{Denom: Denom, Amount: amount}})
	treasury -= amount
	chain.Emit("TreasuryWithdrawn", "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// ---- gameplay --------------------------------------------------------------

// CreateDuel opens a duel. commitment must equal CommitmentHex(move,
// salt) for a private move + salt pair — keep both secret until the
// reveal. The stake is the native coin sent with the call.
func CreateDuel(cur realm, commitment string) uint64 {
	require(cur.Previous().IsUserCall(), "only user-call accepted")
	caller := cur.Previous().Address()

	stake := mustStake()
	validateCommitment(commitment)

	nextID++
	id := nextID
	now := runtime.ChainHeight()
	duels.Set(strconv.FormatUint(id, 10), &Duel{
		id:            id,
		creator:       caller,
		stake:         stake,
		creatorCommit: commitment,
		creatorMove:   -1,
		joinerMove:    -1,
		phase:         PhaseOpen,
		joinDeadline:  now + joinWindow,
		createdHeight: now,
	})
	escrow += stake
	statsFor(caller).wagered += stake

	chain.Emit("DuelCreated", "id", strconv.FormatUint(id, 10), "creator", caller.String(),
		"stake", strconv.FormatInt(stake, 10), "joinDeadline", strconv.FormatInt(now+joinWindow, 10))
	return id
}

// JoinDuel accepts an open duel, matching its stake exactly, with a
// fresh commitment of the joiner's own.
func JoinDuel(cur realm, id uint64, commitment string) {
	require(cur.Previous().IsUserCall(), "only user-call accepted")
	caller := cur.Previous().Address()
	d := mustDuel(id)

	require(d.phase == PhaseOpen, "duel is not open")
	require(d.creator != caller, "cannot duel yourself")
	require(runtime.ChainHeight() <= d.joinDeadline, "join window closed")
	validateCommitment(commitment)

	stake := mustStake()
	require(stake == d.stake, "stake must match the creator's exactly")

	d.joiner = caller
	d.joinerCommit = commitment
	d.phase = PhaseReveal
	d.revealDeadline = runtime.ChainHeight() + revealWindow
	escrow += stake
	statsFor(caller).wagered += stake

	chain.Emit("DuelJoined", "id", strconv.FormatUint(id, 10), "joiner", caller.String(),
		"stake", strconv.FormatInt(stake, 10), "revealDeadline", strconv.FormatInt(d.revealDeadline, 10))
}

// RevealDuel opens a player's commitment. When both players have
// revealed, the duel resolves immediately and the winner is paid.
func RevealDuel(cur realm, id uint64, move int, salt string) {
	require(cur.Previous().IsUserCall(), "only user-call accepted")
	caller := cur.Previous().Address()
	d := mustDuel(id)

	require(d.phase == PhaseReveal, "duel is not in the reveal phase")
	require(runtime.ChainHeight() <= d.revealDeadline, "reveal window closed")
	require(move == MoveAle || move == MoveBroom || move == MoveDagger, "invalid move")

	isCreator := caller == d.creator
	isJoiner := caller == d.joiner
	require(isCreator || isJoiner, "not a player in this duel")

	if isCreator {
		require(d.creatorMove < 0, "already revealed")
		require(CommitmentHex(move, salt) == d.creatorCommit, "commitment mismatch")
		d.creatorMove = move
	} else {
		require(d.joinerMove < 0, "already revealed")
		require(CommitmentHex(move, salt) == d.joinerCommit, "commitment mismatch")
		d.joinerMove = move
	}

	chain.Emit("DuelRevealed", "id", strconv.FormatUint(id, 10), "player", caller.String(), "move", strconv.Itoa(move))

	if d.creatorMove >= 0 && d.joinerMove >= 0 {
		resolveDuel(cur, d)
	}
}

// ClaimForfeit settles a duel whose opponent never showed up:
//   - open past its join deadline: the creator reclaims the stake;
//   - reveal phase past its deadline with exactly one reveal: the
//     player who revealed takes the pot (minus rake);
//   - reveal phase past its deadline with no reveal: both refunded.
func ClaimForfeit(cur realm, id uint64) {
	require(cur.Previous().IsUserCall(), "only user-call accepted")
	caller := cur.Previous().Address()
	d := mustDuel(id)

	if d.phase == PhaseOpen {
		require(runtime.ChainHeight() > d.joinDeadline, "join window still open")
		require(caller == d.creator, "only the creator can reclaim an unjoined duel")
		refund(cur, d.creator, d.stake)
		escrow -= d.stake
		finish(d, ResultExpired)
		chain.Emit("DuelExpired", "id", strconv.FormatUint(id, 10), "refunded", strconv.FormatInt(d.stake, 10))
		return
	}

	require(d.phase == PhaseReveal, "duel already resolved")
	require(runtime.ChainHeight() > d.revealDeadline, "reveal window still open")

	pot := 2 * d.stake
	switch {
	case d.creatorMove >= 0 && d.joinerMove < 0:
		payForfeit(cur, d, d.creator)
	case d.joinerMove >= 0 && d.creatorMove < 0:
		payForfeit(cur, d, d.joiner)
	default:
		// Nobody revealed: both get their stake back, no rake.
		refund(cur, d.creator, d.stake)
		refund(cur, d.joiner, d.stake)
		escrow -= pot
		finish(d, ResultExpired)
		statsFor(d.creator).duels++
		statsFor(d.joiner).duels++
		chain.Emit("DuelExpired", "id", strconv.FormatUint(id, 10), "refunded", strconv.FormatInt(pot, 10))
	}
}

// resolveDuel pays out a duel where both players revealed.
func resolveDuel(cur realm, d *Duel) {
	pot := 2 * d.stake
	volume += pot

	switch outcome(d.creatorMove, d.joinerMove) {
	case 0: // tie
		refund(cur, d.creator, d.stake)
		refund(cur, d.joiner, d.stake)
		escrow -= pot
		finish(d, ResultTie)
		statsFor(d.creator).draws++
		statsFor(d.joiner).draws++
		statsFor(d.creator).duels++
		statsFor(d.joiner).duels++
		chain.Emit("DuelTied", "id", strconv.FormatUint(d.id, 10))
	case 1: // creator wins
		rake := pot * rakeBps / 10_000
		payout(cur, d.creator, pot-rake)
		treasury += rake
		escrow -= pot
		finish(d, ResultCreator)
		d.payout, d.rake = pot-rake, rake
		bookResult(d, d.creator, d.joiner)
		chain.Emit("DuelWon", "id", strconv.FormatUint(d.id, 10), "winner", d.creator.String(),
			"payout", strconv.FormatInt(pot-rake, 10))
	default: // joiner wins
		rake := pot * rakeBps / 10_000
		payout(cur, d.joiner, pot-rake)
		treasury += rake
		escrow -= pot
		finish(d, ResultJoiner)
		d.payout, d.rake = pot-rake, rake
		bookResult(d, d.joiner, d.creator)
		chain.Emit("DuelWon", "id", strconv.FormatUint(d.id, 10), "winner", d.joiner.String(),
			"payout", strconv.FormatInt(pot-rake, 10))
	}
}

// outcome compares two moves: 0 tie, 1 first player wins, 2 second wins.
func outcome(a, b int) int {
	if a == b {
		return 0
	}
	if (a == MoveAle && b == MoveBroom) ||
		(a == MoveBroom && b == MoveDagger) ||
		(a == MoveDagger && b == MoveAle) {
		return 1
	}
	return 2
}

// payForfeit awards the pot to the player who revealed on time.
func payForfeit(cur realm, d *Duel, winner address) {
	pot := 2 * d.stake
	rake := pot * rakeBps / 10_000
	payout(cur, winner, pot-rake)
	treasury += rake
	escrow -= pot
	if winner == d.creator {
		finish(d, ResultCreator)
		bookResult(d, d.creator, d.joiner)
	} else {
		finish(d, ResultJoiner)
		bookResult(d, d.joiner, d.creator)
	}
	d.payout, d.rake = pot-rake, rake
	chain.Emit("DuelForfeited", "id", strconv.FormatUint(d.id, 10), "winner", winner.String(),
		"payout", strconv.FormatInt(pot-rake, 10))
}

// payout sends ugnot out of the realm (which holds the escrow).
func payout(cur realm, to address, amount int64) {
	bank := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bank.SendCoins(cur.Address(), to, chain.Coins{{Denom: Denom, Amount: amount}})
}

// refund returns coins held in escrow for a duel to a player.
func refund(cur realm, to address, amount int64) {
	if amount > 0 {
		payout(cur, to, amount)
	}
}

// bookResult books a win for winner and a loss for loser.
func bookResult(d *Duel, winner, loser address) {
	ws := statsFor(winner)
	ws.wins++
	ws.won += d.payout
	statsFor(loser).losses++
	statsFor(d.creator).duels++
	statsFor(d.joiner).duels++
}

// finish moves a duel to the done phase and stamps the resolution height.
func finish(d *Duel, result string) {
	d.result = result
	d.phase = PhaseDone
	d.resolvedHeight = runtime.ChainHeight()
	duelsPlayed++
}

// ---- views -----------------------------------------------------------------

// GetDuel returns a duel by id, or nil when unknown.
func GetDuel(id uint64) *Duel {
	if v := duels.Get(strconv.FormatUint(id, 10)); v != nil {
		return v.(*Duel)
	}
	return nil
}

// GetPlayerStats returns a player's lifetime record.
func GetPlayerStats(addr address) *Stats {
	if v := stats.Get(string(addr)); v != nil {
		return v.(*Stats)
	}
	return &Stats{}
}

// ArenaStats returns aggregate arena figures.
func ArenaStats() (played uint64, escrowed int64, rake int64, vol int64) {
	return duelsPlayed, escrow, treasury, volume
}

// Params returns the current game parameters, in ugnot/bps/blocks.
func Params() (minStake, maxStake int64, join, reveal int64, rake int64) {
	return MinStake, MaxStake, joinWindow, revealWindow, rakeBps
}

// OpenDuels returns duels still waiting for an opponent (newest first).
func OpenDuels() []*Duel {
	return collect(func(d *Duel) bool { return d.phase == PhaseOpen }, 20)
}

// LiveDuels returns duels in the reveal phase (newest first).
func LiveDuels() []*Duel {
	return collect(func(d *Duel) bool { return d.phase == PhaseReveal }, 20)
}

// RecentDuels returns the most recent resolved duels (newest first).
func RecentDuels() []*Duel {
	return collect(func(d *Duel) bool { return d.phase == PhaseDone }, 10)
}

// ---- gnoweb UI -------------------------------------------------------------

// Render serves the arena UI. Routes:
//
//	/                 arena overview
//	/duel/{id}        duel detail
//	/stats/{address}  player record
//	/leaderboard      all players
func Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("duel/{id}", renderDuel)
	router.HandleFunc("stats/{addr}", renderStats)
	router.HandleFunc("leaderboard", renderLeaderboard)
	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	out := md.H1("🍺 Tavern Duel Arena")
	out += md.Paragraph("Two gnomes walk into a tavern. One leaves with the pot. " +
		"Stake GNOT against another player in a fair, commit-reveal tavern brawl — " +
		"the rules live in this realm, and the code is open and readable on-chain.")
	out += md.Paragraph(md.Bold("Moves") + ": 🍺 Ale beats 🧹 Broom beats 🗡️ Dagger beats 🍺 Ale. Ties are refunded in full, no rake.")
	out += mdalert.Info("Fair by commitment",
		"Both players commit to a move with sha256(\"<move>:<salt>\") before seeing each other. "+
			"Reveals are checked against the commitment, so nobody can copy or react — and the pot is "+
			"paid automatically when the second reveal lands.")

	out += md.H2("How to play")
	out += md.OrderedList([]string{
		"Pick a move and a random salt. Compute the commitment locally: `sha256(\"<move>:<salt>\")`, hex encoded. Keep both secret.",
		"Open the duel with `CreateDuel(commitment)`, sending your stake as native coins.",
		"Your opponent calls `JoinDuel(id, theirCommitment)` with the exact same stake.",
		"Both reveal with `RevealDuel(id, move, salt)`. When the second reveal lands, the winner is paid the pot minus " + rakePct() + " rake.",
		"Opponent gone? After the deadline, `ClaimForfeit(id)` refunds your stake or awards you the pot.",
	})

	out += duelTable("Waiting for an opponent", OpenDuels())
	out += duelTable("Duels in the reveal phase", LiveDuels())

	out += md.H2("Recent results")
	out += recentTable(RecentDuels())

	out += md.H2("The house")
	out += md.BulletList([]string{
		ufmt.Sprintf("Rake: %s of the pot → treasury", rakePct()),
		ufmt.Sprintf("Player stakes in escrow: %s", coins(escrow)),
		ufmt.Sprintf("Rake accumulated in treasury: %s", coins(treasury)),
		ufmt.Sprintf("Wagered in resolved duels: %s", coins(volume)),
		ufmt.Sprintf("Duels resolved: %d", duelsPlayed),
		ufmt.Sprintf("Windows: join %d blocks · reveal %d blocks", joinWindow, revealWindow),
		ufmt.Sprintf("Admin: %s", adminLabel()),
	})
	out += md.Paragraph(md.Link("🏆 Leaderboard", "/"+webRoot+":leaderboard"))

	res.Write(out)
}

func renderDuel(res *mux.ResponseWriter, req *mux.Request) {
	d := duelByPath(req.GetVar("id"))
	if d == nil {
		res.Write(md.H1("No such duel") + md.Paragraph("This duel does not exist (yet)."))
		return
	}
	out := md.H1(ufmt.Sprintf("Duel #%d — %s", d.id, statusLabel(d)))
	out += md.BulletList([]string{
		ufmt.Sprintf("Creator: %s (%s)", short(d.creator.String()), d.creator.String()),
		ufmt.Sprintf("Joiner: %s", joinerLabel(d)),
		ufmt.Sprintf("Stake: %s per player (pot %s)", coins(d.stake), coins(2*d.stake)),
		ufmt.Sprintf("Creator commitment: `%s`", truncate(d.creatorCommit)),
		ufmt.Sprintf("Joiner commitment: `%s`", joinerCommitLabel(d)),
		ufmt.Sprintf("Creator move: %s", moveLabel(d.creatorMove)),
		ufmt.Sprintf("Joiner move: %s", moveLabel(d.joinerMove)),
		deadlineLabel(d),
	})
	if d.phase == PhaseDone {
		out += md.Paragraph(md.Bold("Result") + ": " + resultLabel(d))
		out += md.BulletList([]string{
			ufmt.Sprintf("Winner payout: %s", coins(d.payout)),
			ufmt.Sprintf("House rake: %s", coins(d.rake)),
			ufmt.Sprintf("Resolved at height %d", d.resolvedHeight),
		})
	} else {
		out += mdalert.Note("Moves are sealed", "Moves stay hidden until both players reveal — that is the point of the commitments.")
		if d.phase == PhaseReveal {
			if runtime.ChainHeight() <= d.revealDeadline {
				out += md.H2("Reveal your move")
				form := mdform.New("exec", "RevealDuel")
				form.Input("id", "value", strconv.FormatUint(d.id, 10), "readonly", "true")
				form.Input("move", "type", "number", "placeholder", "0 = 🍺 Ale, 1 = 🧹 Broom, 2 = 🗡️ Dagger", "required", "true")
				form.Input("salt", "placeholder", "your secret salt", "required", "true")
				out += form.String()
			} else {
				out += mdalert.Caution("Reveal window closed", "The deadline passed. Whoever revealed can claim the pot; if nobody revealed, both stakes are refundable.")
				form := mdform.New("exec", "ClaimForfeit")
				form.Input("id", "value", strconv.FormatUint(d.id, 10), "readonly", "true")
				out += form.String()
			}
		}
		if d.phase == PhaseOpen {
			out += joinForm(d)
		}
	}
	out += md.Paragraph(md.Link("← back to the arena", "/"+webRoot))
	res.Write(out)
}

// joinForm explains how to join a duel. Joining is a staking call, and
// gnoweb forms cannot attach coins, so the realm shows the gnokey
// command the player needs to run instead.
func joinForm(d *Duel) string {
	cmd := ufmt.Sprintf("gnokey maketx call -pkgpath gno.land/r/%s -func JoinDuel -args \"id=%d, commitment=<your-64-hex-commitment>\" -send %dugnot -gas-fee 1000000ugnot -gas-wanted 2000000 -broadcast -chainid <chain-id> -remote <rpc> <your-key>",
		webRoot, d.id, d.stake)
	return mdalert.Tip("Joining needs a stake",
		"Forms here cannot attach coins, so join from a wallet or CLI. "+
			"First compute sha256(\"<move>:<salt>\") locally, then run:  \n```\n"+cmd+"\n```")
}

func renderStats(res *mux.ResponseWriter, req *mux.Request) {
	addr := req.GetVar("addr")
	s := GetPlayerStats(address(addr))
	out := md.H1(ufmt.Sprintf("Player %s", short(addr)))
	out += md.BulletList([]string{
		ufmt.Sprintf("Address: %s", addr),
		ufmt.Sprintf("Duels played: %d", s.duels),
		ufmt.Sprintf("Wins: %d", s.wins),
		ufmt.Sprintf("Losses: %d", s.losses),
		ufmt.Sprintf("Draws: %d", s.draws),
		ufmt.Sprintf("Wagered: %s", coins(s.wagered)),
		ufmt.Sprintf("Won: %s", coins(s.won)),
	})
	out += md.Paragraph(md.Link("← back to the arena", "/"+webRoot))
	res.Write(out)
}

func renderLeaderboard(res *mux.ResponseWriter, req *mux.Request) {
	out := md.H1("🏆 Tavern Duel Arena — Leaderboard")
	table := mdtable.Table{Headers: []string{"Player", "Duels", "Wins", "Losses", "Draws", "Wagered"}}
	stats.IterateByOffset(0, 200, func(key string, value any) bool {
		s := value.(*Stats)
		if s.duels == 0 {
			return false
		}
		table.Append([]string{short(key), strconv.FormatInt(s.duels, 10), strconv.FormatInt(s.wins, 10),
			strconv.FormatInt(s.losses, 10), strconv.FormatInt(s.draws, 10), coins(s.wagered)})
		return false
	})
	out += table.String()
	res.Write(out)
}

// ---- helpers ---------------------------------------------------------------

// CommitmentHex computes the commitment for a move and salt:
// sha256("<move>:<salt>"), hex encoded. Compute it locally, keep the
// move and salt secret until the reveal.
func CommitmentHex(move int, salt string) string {
	sum := sha256.Sum256([]byte(strconv.Itoa(move) + ":" + salt))
	return hex.EncodeToString(sum[:])
}

func mustDuel(id uint64) *Duel {
	v := duels.Get(strconv.FormatUint(id, 10))
	if v == nil {
		panic("unknown duel id")
	}
	return v.(*Duel)
}

// mustStake returns the ugnot amount sent with the current call and
// enforces the stake bounds.
func mustStake() int64 {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("send the stake in ugnot")
	}
	amt := sent[0].Amount
	if amt < MinStake || amt > MaxStake {
		panic("stake out of bounds")
	}
	return amt
}

func statsFor(addr address) *Stats {
	key := string(addr)
	if v := stats.Get(key); v != nil {
		return v.(*Stats)
	}
	s := &Stats{}
	stats.Set(key, s)
	return s
}

// collect returns duels matching keep, newest first.
func collect(keep func(*Duel) bool, limit int) []*Duel {
	var out []*Duel
	duels.ReverseIterateByOffset(0, 500, func(_ string, value any) bool {
		if len(out) >= limit {
			return true
		}
		d := value.(*Duel)
		if keep(d) {
			out = append(out, d)
		}
		return false
	})
	return out
}

func validateCommitment(c string) {
	if len(c) != 64 || !isHex(c) {
		panic("commitment must be 64 hex characters (sha256)")
	}
}

func isHex(s string) bool {
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') {
			return false
		}
	}
	return true
}

func assertAdmin(cur realm) {
	require(hasAdmin, "realm not initialized")
	require(cur.Previous().Address() == admin, "only the realm admin")
}

func require(check bool, msg string) {
	if !check {
		panic(msg)
	}
}

func duelByPath(id string) *Duel {
	if v := duels.Get(id); v != nil {
		return v.(*Duel)
	}
	return nil
}

func duelTable(title string, list []*Duel) string {
	if len(list) == 0 {
		return ""
	}
	table := mdtable.Table{Headers: []string{"#", "Creator", "Stake", "Deadline", "Details"}}
	for _, d := range list {
		table.Append([]string{
			strconv.FormatUint(d.id, 10),
			short(d.creator.String()),
			coins(d.stake),
			ufmt.Sprintf("height %d", deadline(d)),
			md.Link("detail", "/"+webRoot+":duel/"+strconv.FormatUint(d.id, 10)),
		})
	}
	return md.H2(title) + table.String() + "\n"
}

func recentTable(list []*Duel) string {
	if len(list) == 0 {
		return md.Paragraph("No resolved duels yet — be the first!")
	}
	table := mdtable.Table{Headers: []string{"#", "Players", "Result", "Payout"}}
	for _, d := range list {
		table.Append([]string{
			strconv.FormatUint(d.id, 10),
			short(d.creator.String()) + " vs " + joinerLabel(d),
			resultLabel(d),
			coins(d.payout),
		})
	}
	return table.String() + "\n"
}

func deadline(d *Duel) int64 {
	if d.phase == PhaseOpen {
		return d.joinDeadline
	}
	return d.revealDeadline
}

func deadlineLabel(d *Duel) string {
	if d.phase == PhaseOpen {
		return ufmt.Sprintf("Join deadline: height %d", d.joinDeadline)
	}
	if d.phase == PhaseReveal {
		return ufmt.Sprintf("Reveal deadline: height %d", d.revealDeadline)
	}
	return ufmt.Sprintf("Resolved at height %d", d.resolvedHeight)
}

func statusLabel(d *Duel) string {
	switch d.phase {
	case PhaseOpen:
		return "waiting for an opponent"
	case PhaseReveal:
		return "reveal phase"
	default:
		return "done"
	}
}

func joinerLabel(d *Duel) string {
	if string(d.joiner) == "" {
		return "— (nobody yet)"
	}
	return short(d.joiner.String())
}

func joinerCommitLabel(d *Duel) string {
	if d.joinerCommit == "" {
		return "—"
	}
	return truncate(d.joinerCommit)
}

func moveLabel(move int) string {
	switch move {
	case MoveAle:
		return "🍺 Ale (revealed)"
	case MoveBroom:
		return "🧹 Broom (revealed)"
	case MoveDagger:
		return "🗡️ Dagger (revealed)"
	default:
		return "committed, not revealed yet"
	}
}

func resultLabel(d *Duel) string {
	switch d.result {
	case ResultCreator:
		return "creator wins 🍻"
	case ResultJoiner:
		return "joiner wins 🍻"
	case ResultTie:
		return "tie — both refunded 🤝"
	default:
		return "expired — refunded ⏰"
	}
}

func rakePct() string {
	return ufmt.Sprintf("%d.%02d%%", rakeBps/100, rakeBps%100)
}

func coins(ugnot int64) string {
	if ugnot == 0 {
		return "0 GNOT"
	}
	return ufmt.Sprintf("%d.%06d GNOT", ugnot/1_000_000, ugnot%1_000_000)
}

func short(addr string) string {
	if len(addr) < 14 {
		return addr
	}
	return addr[:8] + "…" + addr[len(addr)-6:]
}

func truncate(s string) string {
	if len(s) <= 16 {
		return s
	}
	return s[:16] + "…"
}

func adminLabel() string {
	if !hasAdmin {
		return "not initialized"
	}
	return admin.String()
}
