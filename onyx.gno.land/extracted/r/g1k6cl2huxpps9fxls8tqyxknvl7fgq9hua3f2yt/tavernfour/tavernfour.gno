package tavernfour

// Tavern Four — four in a row for two, played on gno.land, with a purse that
// settles itself.
//
// A host opens a table with a stake and a clock (in blocks). A guest joins by
// matching the stake, and the two take turns dropping discs by transaction.
// The realm owns the board: it refuses a move from the wrong player, a drop
// into a full column, and anything sent after the game is over. When a line
// appears, or the board fills, the pot is paid out by the realm in the same
// transaction that ended the game — nobody holds the money in between.
//
// The rules themselves (the 7x6 board, gravity, the four line directions) live
// in the imported package p/.../c4 and are pure; this realm is the table, the
// clock, the purse and the pages.

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1k6cl2huxpps9fxls8tqyxknvl7fgq9hua3f2yt/c4"
)

const (
	// RealmPath is this realm's own path; scripts/test.sh checks it against
	// gnomod.toml so a copy of this code cannot silently change its address.
	RealmPath = "gno.land/r/g1k6cl2huxpps9fxls8tqyxknvl7fgq9hua3f2yt/tavernfour"
	// PackagePath is the imported rules package.
	PackagePath = "gno.land/p/g1k6cl2huxpps9fxls8tqyxknvl7fgq9hua3f2yt/c4"

	// Denom is the only coin this realm accepts. Every stake and every
	// payout is in ugnot, so a table never mixes denominations.
	Denom = "ugnot"

	// MaxStake caps a purse at 10 GNOT per player.
	MaxStake int64 = 10_000_000
	// MinTurnBlocks and MaxTurnBlocks bound the per-move clock: at the
	// testnet's few-second blocks, 20 blocks is about a minute and 2,000 is
	// a couple of hours.
	MinTurnBlocks int64 = 20
	MaxTurnBlocks int64 = 2_000

	// MaxNameLen is the longest table name, in bytes.
	MaxNameLen = 24

	// StatusOpen is a table waiting for a guest; live means both seats are
	// taken and it is somebody's turn; finished and cancelled are final.
	StatusOpen      = "open"
	StatusLive      = "live"
	StatusFinished  = "finished"
	StatusCancelled = "cancelled"

	// ResultHost, ResultGuest and ResultDraw are the three ways a game ends.
	ResultHost  = "host"
	ResultGuest = "guest"
	ResultDraw  = "draw"

	// Red moves first; the host plays red.
	HostColour = c4.Red
	GuestColour = c4.Yellow
)

// Move is one disc, written down as it happened.
type Move struct {
	By     address
	Col    int
	Row    int
	Height int64
	At     int64
}

// Game is one table.
type Game struct {
	ID        uint64
	Host      address
	// Guest is the yellow seat's address as a string, empty until somebody
	// sits down. It is a string rather than an address because a table with
	// no guest would otherwise have to store an empty address, and the VM
	// refuses to persist one ("unexpected node").
	Guest     string
	HostName  string
	GuestName string

	// Stake is what each player put in; Pot is what the realm still holds
	// for this game, which is 2*Stake until it settles.
	Stake int64
	Purse int64

	// TurnBlocks is how long the player to move has, in blocks, before the
	// other may claim the game on the clock.
	TurnBlocks int64

	Board c4.Board
	// Turn is "host", "guest" or "" — the side to move while the game is
	// live, empty otherwise. Keeping it a word rather than an address means
	// a finished game stores nothing that is not a real value.
	Turn   string
	Status string
	Result string

	Moves   []Move
	WinLine []int

	OpenedAt       int64
	StartedAt      int64
	EndedAt        int64
	OpenedHeight   int64
	LastMoveHeight int64
}

// Player is one row of the tavern ladder.
type Player struct {
	Address    string
	Name       string
	Games      int
	Wins       int
	Losses     int
	Draws      int
	Points     int
	Streak     int
	BestStreak int
	Won        int64
	LastPlayed int64
}

var (
	games   []*Game
	byID    = map[uint64]*Game{}
	nextID  uint64
	players []*Player
	byAddr  = map[string]*Player{}

	// escrow is the total the realm holds across every table. It is kept so
	// that a payout can never reach coins that belong to another game.
	escrow int64
)

// ---------------------------------------------------------------- the table

// Open seats a table. The host sends exactly their stake with the call, and
// that stake is held by the realm until a guest arrives. A stake of zero opens
// a friendly game; the realm then moves no coins at all.
func Open(cur realm, stake int64, turnBlocks int64, name string) uint64 {
	caller := callerOf(cur)
	name = cleanName(name)

	require(stake >= 0, "stake cannot be negative")
	require(stake <= MaxStake, "stake is capped at "+itoa(MaxStake)+" ugnot (10 GNOT)")
	require(turnBlocks >= MinTurnBlocks && turnBlocks <= MaxTurnBlocks,
		"turn clock must be "+itoa(MinTurnBlocks)+"-"+itoa(MaxTurnBlocks)+" blocks")

	paid := sentUgnot()
	require(paid == stake, "send exactly the stake with the call: want "+itoa(stake)+" ugnot, got "+itoa(paid))

	nextID++
	g := &Game{
		ID:           nextID,
		Host:         caller,
		HostName:     name,
		Stake:        stake,
		Purse:        paid,
		TurnBlocks:   turnBlocks,
		Board:        c4.New(),
		Status:       StatusOpen,
		Moves:        []Move{},
		WinLine:      []int{},
		OpenedAt:       nowUnix(),
		OpenedHeight:   runtime.ChainHeight(),
		LastMoveHeight: runtime.ChainHeight(),
		Turn:         SeatHost,
	}
	games = append(games, g)
	byID[g.ID] = g
	escrow += paid
	playerOf(caller, name)
	trackName(caller, name)

	chain.Emit("TableOpened", "id", uitoa(g.ID), "host", caller.String(), "stake", itoa(stake), "clock", itoa(turnBlocks))
	println("table #" + uitoa(g.ID) + " opened by " + caller.String() + " at stake " + itoa(stake))
	return g.ID
}

// Join takes the empty seat by matching the host's stake, and starts the game.
// The host (red) moves first.
func Join(cur realm, id uint64, name string) {
	caller := callerOf(cur)
	g := mustGame(id)
	name = cleanName(name)

	require(g.Status == StatusOpen, "this table is not waiting for a guest")
	require(caller != g.Host, "the host cannot take the guest seat")
	require(g.Purse == g.Stake, "the table's purse does not match its stake")

	paid := sentUgnot()
	require(paid == g.Stake, "send exactly the stake to join: want "+itoa(g.Stake)+" ugnot, got "+itoa(paid))

	g.Guest = caller.String()
	g.GuestName = name
	g.Purse += paid
	g.Status = StatusLive
	g.Turn = SeatHost
	g.StartedAt = nowUnix()
	g.LastMoveHeight = runtime.ChainHeight()
	escrow += paid
	playerOf(caller, name)
	trackName(caller, name)

	chain.Emit("TableJoined", "id", uitoa(g.ID), "guest", caller.String(), "stake", itoa(g.Stake))
	println("table #" + uitoa(g.ID) + " joined by " + caller.String() + "; red to move")
}

// Drop puts a disc in a column. Only the player whose turn it is may move, and
// only into a column that still has room.
func Drop(cur realm, id uint64, col int) {
	caller := callerOf(cur)
	g := mustGame(id)

	require(g.Status == StatusLive, "this game is not being played")
	require(sideOf(g, caller) == g.Turn, "it is not your turn")

	next, row, err := g.Board.Play(colourOf(g, caller), col)
	require(err == "", err)

	g.Board = next
	height := runtime.ChainHeight()
	g.Moves = append(g.Moves, Move{By: caller, Col: col, Row: row, Height: height, At: nowUnix()})
	g.LastMoveHeight = height

	winner, line, won := g.Board.Winner()
	if won {
		g.WinLine = line
		if winner == HostColour {
			settle(cur, g, ResultHost, "line")
		} else {
			settle(cur, g, ResultGuest, "line")
		}
		return
	}
	if g.Board.Full() {
		settle(cur, g, ResultDraw, "board full")
		return
	}
	g.Turn = otherSide(g.Turn)

	chain.Emit("DiscDropped", "id", uitoa(g.ID), "by", caller.String(), "col", itoa(int64(col)), "row", itoa(int64(row)))
	println("table #" + uitoa(g.ID) + ": column " + itoa(int64(col)) + " by " + caller.String())
}

// Forfeit hands the game to the other player. It is always allowed on your own
// turn — walking away from the table is a decision, not a stall.
func Forfeit(cur realm, id uint64) {
	caller := callerOf(cur)
	g := mustGame(id)

	require(g.Status == StatusLive, "this game is not being played")
	require(sideOf(g, caller) != "", "only a seated player can forfeit")

	if caller == g.Host {
		settle(cur, g, ResultGuest, "host forfeited")
	} else {
		settle(cur, g, ResultHost, "guest forfeited")
	}
}

// ClaimTimeout takes the game when the player to move has used up the clock.
// Anyone seated may claim, but only against the other seat: a player who has
// run out of time cannot claim against themselves.
func ClaimTimeout(cur realm, id uint64) {
	caller := callerOf(cur)
	g := mustGame(id)

	require(g.Status == StatusLive, "this game is not being played")
	side := sideOf(g, caller)
	require(side != "", "only a seated player can claim the clock")
	require(side != g.Turn, "you cannot claim the clock against yourself")

	deadline := g.LastMoveHeight + g.TurnBlocks
	require(runtime.ChainHeight() > deadline,
		"the clock has not run out yet: block "+itoa(runtime.ChainHeight())+" of "+itoa(deadline))

	if caller == g.Host {
		settle(cur, g, ResultHost, "guest ran out of time")
	} else {
		settle(cur, g, ResultGuest, "host ran out of time")
	}
}

// Cancel closes a table nobody joined and returns the host's stake.
func Cancel(cur realm, id uint64) {
	caller := callerOf(cur)
	g := mustGame(id)

	require(g.Status == StatusOpen, "only a table waiting for a guest can be cancelled")
	require(caller == g.Host, "only the host can cancel the table")

	g.Status = StatusCancelled
	g.EndedAt = nowUnix()
	refund := g.Purse
	g.Purse = 0
	pay(cur, g.Host, refund)
	escrow -= refund

	chain.Emit("TableCancelled", "id", uitoa(g.ID), "refunded", itoa(refund))
	println("table #" + uitoa(g.ID) + " cancelled; " + itoa(refund) + " ugnot returned")
}

// settle ends a game, pays the purse and writes the result down. It runs in the
// same transaction as the move that ended the game, so there is no window in
// which the pot sits waiting for someone to collect it.
func settle(cur realm, g *Game, result string, reason string) {
	g.Status = StatusFinished
	g.Result = result
	g.EndedAt = nowUnix()
	g.Turn = ""

	pot := g.Purse
	g.Purse = 0

	if pot > 0 {
		switch result {
		case ResultHost:
			pay(cur, g.Host, pot)
		case ResultGuest:
			pay(cur, address(g.Guest), pot)
		case ResultDraw:
			half := pot / 2
			pay(cur, g.Host, half)
			pay(cur, address(g.Guest), pot-half)
		}
	}
	escrow -= pot

	record(g, result)

	chain.Emit("GameSettled", "id", uitoa(g.ID), "result", result, "pot", itoa(pot), "reason", reason)
	println("table #" + uitoa(g.ID) + " settled: " + result + " (" + reason + "), pot " + itoa(pot))
}

// pay sends coins out of the realm account. Every payout is against the escrow
// the realm has already received, so a table can only ever pay out what was
// put in.
func pay(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	require(amount <= escrow, "payout exceeds the realm's escrow")
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(chain.PackageAddress(RealmPath), to, chain.NewCoins(chain.NewCoin(Denom, amount)))
}

// ---------------------------------------------------------------- the ladder

// record updates both players' rows after a finished game. Points are the
// tavern's own currency: three for a win, one for a draw, none for a loss. It
// is deliberately not an Elo rating — a board that anyone can read should not
// need a paragraph to explain its numbers.
func record(g *Game, result string) {
	host := playerOf(g.Host, g.HostName)
	guest := playerOf(address(g.Guest), g.GuestName)
	now := nowUnix()

	host.Games++
	guest.Games++
	host.LastPlayed = now
	guest.LastPlayed = now
	trackName(g.Host, g.HostName)
	trackName(address(g.Guest), g.GuestName)

	switch result {
	case ResultHost:
		host.Wins++
		host.Points += 3
		host.Streak++
		if host.Streak > host.BestStreak {
			host.BestStreak = host.Streak
		}
		host.Won += 2 * g.Stake
		guest.Losses++
		guest.Streak = 0
	case ResultGuest:
		guest.Wins++
		guest.Points += 3
		guest.Streak++
		if guest.Streak > guest.BestStreak {
			guest.BestStreak = guest.Streak
		}
		guest.Won += 2 * g.Stake
		host.Losses++
		host.Streak = 0
	case ResultDraw:
		host.Draws++
		guest.Draws++
		host.Points++
		guest.Points++
		host.Streak = 0
		guest.Streak = 0
	}
}

func playerOf(a address, name string) *Player {
	if a.String() == "" {
		return &Player{Address: ""}
	}
	key := a.String()
	p, ok := byAddr[key]
	if !ok {
		p = &Player{Address: key, Name: name}
		players = append(players, p)
		byAddr[key] = p
	}
	return p
}

func trackName(a address, name string) {
	if name == "" {
		return
	}
	p := playerOf(a, name)
	p.Name = name
}

// Ladder returns every player who has played, best first: points, then wins,
// then the smaller number of games (a 3-0 record outranks 3-3).
func Ladder() []*Player {
	out := make([]*Player, len(players))
	copy(out, players)
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && ladderBefore(out[j], out[j-1]); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func ladderBefore(a, b *Player) bool {
	if a.Points != b.Points {
		return a.Points > b.Points
	}
	if a.Wins != b.Wins {
		return a.Wins > b.Wins
	}
	return a.Games < b.Games
}

// ------------------------------------------------------------------- reads

// Escrow is every ugnot the realm holds across all tables. A settlement pays
// out of it and a cancel refunds out of it, so after the last table closes the
// number should be back to zero; anyone can read it and compare it with the
// realm's account balance on the bank.
func Escrow() int64 {
	return escrow
}

// GameCount is the number of tables ever opened.
func GameCount() int {
	return len(games)
}

// GetGame returns a game by id, or nil.
func GetGame(id uint64) *Game {
	g, ok := byID[id]
	if !ok {
		return nil
	}
	return g
}

// PlayerOf returns a ladder row by address string, or nil.
func PlayerOf(addr string) *Player {
	p, ok := byAddr[addr]
	if !ok {
		return nil
	}
	return p
}

// Pot is what the realm still holds for this game.
func (g *Game) Pot() int64 {
	return g.Purse
}

// Deadline is the block by which the player to move must have moved.
func (g *Game) Deadline() int64 {
	return g.LastMoveHeight + g.TurnBlocks
}

// -------------------------------------------------------------- game JSON

// GameJSON returns one game as JSON for the browser table. The names are
// restricted to a safe character set at entry (see cleanName), so no string
// here can need escaping beyond what cleanName already refused.
func GameJSON(id uint64) string {
	g, ok := byID[id]
	if !ok {
		return "{}"
	}

	s := "{"
	s += "\"id\":" + uitoa(g.ID)
	s += ",\"status\":\"" + g.Status + "\""
	s += ",\"result\":\"" + g.Result + "\""
	s += ",\"stake\":" + itoa(g.Stake)
	s += ",\"pot\":" + itoa(g.Purse)
	s += ",\"host\":{\"address\":\"" + g.Host.String() + "\",\"name\":\"" + g.HostName + "\"}"
	s += ",\"guest\":{\"address\":\"" + g.Guest + "\",\"name\":\"" + g.GuestName + "\"}"
	s += ",\"turn\":\"" + turnSide(g) + "\""
	s += ",\"turnAddress\":\"" + seatAddress(g, g.Turn) + "\""
	s += ",\"board\":\"" + g.Board.String() + "\""
	s += ",\"winLine\":" + intListJSON(g.WinLine)
	s += ",\"moves\":["
	for i := 0; i < len(g.Moves); i++ {
		m := g.Moves[i]
		if i > 0 {
			s += ","
		}
		s += "{\"by\":\"" + m.By.String() + "\",\"col\":" + itoa(int64(m.Col)) + ",\"row\":" + itoa(int64(m.Row)) + ",\"height\":" + itoa(m.Height) + "}"
	}
	s += "]"
	s += ",\"openedHeight\":" + itoa(g.OpenedHeight)
	s += ",\"lastMoveHeight\":" + itoa(g.LastMoveHeight)
	s += ",\"turnBlocks\":" + itoa(g.TurnBlocks)
	s += ",\"height\":" + itoa(runtime.ChainHeight())
	s += ",\"deadline\":" + itoa(g.Deadline())
	s += "}"
	return s
}

// LadderJSON returns the ladder as JSON, best first.
func LadderJSON() string {
	rows := Ladder()
	s := "["
	for i := 0; i < len(rows); i++ {
		p := rows[i]
		if i > 0 {
			s += ","
		}
		s += "{\"address\":\"" + p.Address + "\""
		s += ",\"name\":\"" + p.Name + "\""
		s += ",\"games\":" + itoa(int64(p.Games))
		s += ",\"wins\":" + itoa(int64(p.Wins))
		s += ",\"losses\":" + itoa(int64(p.Losses))
		s += ",\"draws\":" + itoa(int64(p.Draws))
		s += ",\"points\":" + itoa(int64(p.Points))
		s += ",\"streak\":" + itoa(int64(p.Streak))
		s += ",\"won\":" + itoa(p.Won)
		s += "}"
	}
	s += "]"
	return s
}

// RecentJSON lists the newest tables, newest first, for the browser lobby.
func RecentJSON(limit int) string {
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	s := "["
	n := 0
	for i := len(games) - 1; i >= 0 && n < limit; i-- {
		g := games[i]
		if n > 0 {
			s += ","
		}
		s += "{\"id\":" + uitoa(g.ID)
		s += ",\"status\":\"" + g.Status + "\""
		s += ",\"host\":\"" + nameOf(g.Host, g.HostName) + "\""
		s += ",\"guest\":\"" + guestNameOf(g) + "\""
		s += ",\"stake\":" + itoa(g.Stake)
		s += ",\"result\":\"" + g.Result + "\""
		s += ",\"moves\":" + itoa(int64(len(g.Moves))) + "}"
		n++
	}
	s += "]"
	return s
}

// ---------------------------------------------------------------- internals

// callerOf is the account that signed the transaction, and the only identity a
// table accepts. It refuses any call whose immediate caller is another realm:
// a game action is a person at the table, not a contract playing on their
// behalf, because the stake and the turn would otherwise be spent by someone
// the player never authorised.
func callerOf(cur realm) address {
	require(cur.IsCurrent(), "invalid realm frame")
	require(cur.Previous().IsUserCall(), "call from a user account, not from another realm")
	require(unsafe.PreviousRealm().IsUserCall(), "call from a user account, not from another realm")
	return unsafe.OriginCaller()
}

// sentUgnot is the coin envelope of this message, refused unless it is purely
// ugnot: a stake paid in some other denom would otherwise be counted as free.
func sentUgnot() int64 {
	coins := unsafe.OriginSend()
	total := int64(0)
	for i := 0; i < len(coins); i++ {
		require(coins[i].Denom == Denom, "only "+Denom+" is accepted")
		total += coins[i].Amount
	}
	return total
}

// SeatHost and SeatGuest name the two seats wherever a seat has to be
// written down: the turn, a JSON field, an event.
const (
	SeatHost  = "host"
	SeatGuest = "guest"
)

// sideOf says which seat an address holds: "host", "guest" or "".
func sideOf(g *Game, who address) string {
	if who == g.Host {
		return SeatHost
	}
	if g.Guest != "" && who == address(g.Guest) {
		return SeatGuest
	}
	return ""
}

// seatAddress is the address in a seat, as a string, or "" for an empty seat.
func seatAddress(g *Game, side string) string {
	switch side {
	case SeatHost:
		return g.Host.String()
	case SeatGuest:
		return g.Guest
	}
	return ""
}

func colourOf(g *Game, who address) uint8 {
	if sideOf(g, who) == SeatGuest {
		return GuestColour
	}
	return HostColour
}

func otherSide(side string) string {
	if side == SeatHost {
		return SeatGuest
	}
	return SeatHost
}

// turnSide names the seat whose turn it is, for pages and JSON.
func turnSide(g *Game) string {
	if g.Status != StatusLive {
		return ""
	}
	return g.Turn
}

// guestNameOf is nameOf for the yellow seat, whose address is a string.
func guestNameOf(g *Game) string {
	if g.GuestName != "" {
		return g.GuestName
	}
	if g.Guest == "" {
		return ""
	}
	return short(g.Guest)
}

func nameOf(a address, fallback string) string {
	if fallback != "" {
		return fallback
	}
	s := a.String()
	if len(s) > 10 {
		return s[:6] + "…" + s[len(s)-4:]
	}
	return s
}

// cleanName keeps table names to printable ASCII without the characters that
// would break a markdown table or a JSON string. It is a whitelist, so any
// text a player sends either survives intact or not at all.
func cleanName(s string) string {
	s = trimSpace(s)
	if len(s) > MaxNameLen {
		s = s[:MaxNameLen]
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == ' ' || c == '-' || c == '_' || c == '.' || c == '\''
		if !ok {
			panic("name may only use letters, digits, spaces and - _ . '")
		}
	}
	if s == "" {
		return "guest"
	}
	return s
}

func mustGame(id uint64) *Game {
	g, ok := byID[id]
	if !ok {
		panic("table #" + uitoa(id) + " does not exist")
	}
	return g
}

func nowUnix() int64 {
	return time.Now().Unix()
}

func require(ok bool, msg string) {
	if !ok {
		panic(msg)
	}
}

func uitoa(u uint64) string {
	return strconv.FormatUint(u, 10)
}

func itoa(i int64) string {
	return strconv.FormatInt(i, 10)
}

func intListJSON(xs []int) string {
	s := "["
	for i := 0; i < len(xs); i++ {
		if i > 0 {
			s += ","
		}
		s += itoa(int64(xs[i]))
	}
	return s + "]"
}

func trimSpace(s string) string {
	start := 0
	end := len(s)
	for start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r') {
		start++
	}
	for end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n' || s[end-1] == '\r') {
		end--
	}
	return s[start:end]
}
