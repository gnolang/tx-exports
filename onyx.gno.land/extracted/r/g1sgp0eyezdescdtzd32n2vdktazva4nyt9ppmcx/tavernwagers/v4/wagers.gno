// Package tavernwagers lets friend groups ("tables") bet on anything with each other.
//
// How it works:
//   - A table is an invite-only group of friends.
//   - Two players lock the same stake into the realm before the game,
//     plus a 10% honesty bond.
//   - After the game, both players report the result. If they agree, the
//     realm pays out instantly and both bonds come back.
//   - If they disagree, every other table member becomes a judge. Judges
//     have no money in the bet, so they have no reason to lie. As soon as
//     a strict majority of judges agree, the bet settles.
//   - A player whose report loses the vote forfeits their bond. Half goes
//     to the honest player, half to the judges who voted with the majority.
//     Majority judges also split a 1% fee from the pot for showing up.
//   - If the judges can't reach a majority before the deadline, everyone
//     is refunded in full.
//
// The realm takes no cut: every coin that goes in comes back out to the
// players and judges.
package tavernwagers

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

const (
	ResultA    = "a"    // player A won
	ResultB    = "b"    // player B won
	ResultDraw = "draw" // draw, stakes go back

	MinStake int64 = 10_000 // 0.01 GNOT

	ReportWindow = 24 * time.Hour // how long a player has to answer the other's report
	VoteWindow   = 48 * time.Hour // how long judges have to vote
)

type BetStatus int

const (
	StatusOpen      BetStatus = iota // waiting for player B to accept
	StatusLive                       // both staked, waiting for reports
	StatusDisputed                   // players disagree, judges voting
	StatusSettled                    // paid out
	StatusCancelled                  // cancelled before B accepted
	StatusRefunded                   // judges could not decide, everyone refunded
)

func (s BetStatus) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusLive:
		return "live"
	case StatusDisputed:
		return "disputed"
	case StatusSettled:
		return "settled"
	case StatusCancelled:
		return "cancelled"
	case StatusRefunded:
		return "refunded"
	}
	return "unknown"
}

// Stats is one member's record at a table.
type Stats struct {
	Net          int64 // ugnot won minus ugnot lost
	Wins         int
	Losses       int
	Draws        int
	DisputesLost int // times this player's report lost a judges' vote
	Judged       int // times this member voted with the majority as a judge
}

type Table struct {
	ID      int
	Name    string
	Owner   address
	Members []address
	Stats   *avl.Tree // address -> *Stats
	Names   *avl.Tree // address -> nickname
	BetIDs  []int
	PoolIDs []int
	Created time.Time
}

type Payout struct {
	To     address
	Amount int64
	Why    string
}

type Bet struct {
	ID      int
	TableID int
	Title   string
	PlayerA address
	PlayerB address
	Stake   int64 // per player
	Bond    int64 // per player
	Status  BetStatus

	ReportA       string
	ReportB       string
	FirstReportAt time.Time

	Judges   []address
	Votes    *avl.Tree // address -> result string
	Deadline time.Time // voting deadline when disputed

	Final   string
	Payouts []Payout
	Created time.Time
}

var (
	tables   avl.Tree // id -> *Table
	bets     avl.Tree // id -> *Bet
	tableSeq int
	betSeq   int

	totalLocked  int64 // ugnot locked in accepted bets, all time
	totalSettled int   // bets settled (paid out to a winner or draw)
	liarsCaught  int   // reports that lost a judges' vote
	biggestPot   int64 // largest pot ever settled, ugnot
	judgesPaid   int64 // ugnot paid to judges, all time
)

// ---------------------------------------------------------------------------
// Tables

// CreateTable opens a new table. The caller becomes its owner and first
// member, shown under the given nickname.
func CreateTable(cur realm, name string, nickname string) int {
	caller := cur.Previous().Address()
	name = strings.TrimSpace(name)
	require(name != "", "table name required")
	require(len(name) <= 64, "table name too long (max 64)")
	require(printable(name), "table name has invalid characters")

	tableSeq++
	t := &Table{
		ID:      tableSeq,
		Name:    name,
		Owner:   caller,
		Members: []address{caller},
		Stats:   avl.NewTree(),
		Names:   avl.NewTree(),
		Created: time.Now(),
	}
	t.setName(caller, nickname)
	tables.Set(strconv.Itoa(t.ID), t)
	return t.ID
}

// AddMember invites a friend to a table under a nickname. Only the table
// owner can do this. Members can change their own nickname later.
func AddMember(cur realm, tableID int, member address, nickname string) {
	caller := cur.Previous().Address()
	t := mustTable(tableID)
	require(caller == t.Owner, "only the table owner can add members")
	require(member.IsValid(), "invalid address")
	require(!t.isMember(member), "already a member")
	require(len(t.Members) < 50, "table is full (max 50)")
	t.setName(member, nickname) // validate the nickname before changing anything
	t.Members = append(t.Members, member)
}

// SetNickname changes how you appear at a table.
func SetNickname(cur realm, tableID int, nickname string) {
	caller := cur.Previous().Address()
	t := mustTable(tableID)
	require(t.isMember(caller), "you are not a member of this table")
	t.setName(caller, nickname)
}

// ---------------------------------------------------------------------------
// Bets

// CreateBet proposes a bet against another table member and locks your stake.
// opponent is their nickname at the table (or their g1... address).
// Send exactly stake + 10% bond, e.g. stake 1000000 -> send 1100000ugnot.
// You are player A, the opponent is player B. The judges are fixed when
// the bet is accepted: every other member of the table at that moment.
func CreateBet(cur realm, tableID int, title string, opponentName string, stake int64) int {
	require(cur.Previous().IsUserCall(), "only direct user calls accepted")
	caller := cur.Previous().Address()
	t := mustTable(tableID)
	title = strings.TrimSpace(title)
	require(title != "", "bet title required")
	require(len(title) <= 140, "bet title too long (max 140)")
	require(printable(title), "bet title has invalid characters")
	require(t.isMember(caller), "you are not a member of this table")
	opponent := t.resolve(opponentName)
	require(opponent != caller, "you can't bet against yourself")
	require(stake >= MinStake, "stake too small (min "+strconv.FormatInt(MinStake, 10)+"ugnot)")

	bond := stake / 10
	requireSent(stake + bond)

	betSeq++
	b := &Bet{
		ID:      betSeq,
		TableID: tableID,
		Title:   title,
		PlayerA: caller,
		PlayerB: opponent,
		Stake:   stake,
		Bond:    bond,
		Status:  StatusOpen,
		Votes:   avl.NewTree(),
		Created: time.Now(),
	}
	bets.Set(strconv.Itoa(b.ID), b)
	t.BetIDs = append(t.BetIDs, b.ID)
	return b.ID
}

// AcceptBet is called by player B to match the stake and bond.
func AcceptBet(cur realm, betID int) {
	require(cur.Previous().IsUserCall(), "only direct user calls accepted")
	caller := cur.Previous().Address()
	b := mustBet(betID)
	require(b.Status == StatusOpen, "bet is not open")
	require(caller == b.PlayerB, "only the challenged player can accept")
	requireSent(b.Stake + b.Bond)
	b.Status = StatusLive
	b.Judges = mustTable(b.TableID).judgesFor(b.PlayerA, b.PlayerB)
	totalLocked += 2 * (b.Stake + b.Bond)
}

// CancelBet lets player A take the bet back before B accepts it.
func CancelBet(cur realm, betID int) {
	caller := cur.Previous().Address()
	b := mustBet(betID)
	require(b.Status == StatusOpen, "only open bets can be cancelled")
	require(caller == b.PlayerA, "only the player who created the bet can cancel it")
	b.Status = StatusCancelled
	b.Payouts = []Payout{{b.PlayerA, b.Stake + b.Bond, "cancelled, refund"}}
	pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), b.Payouts)
}

// Report is how each player says who won: "a", "b" or "draw".
// If both players report the same result, the bet pays out right away.
// If they disagree, it goes to the judges.
func Report(cur realm, betID int, result string) {
	caller := cur.Previous().Address()
	b := mustBet(betID)
	require(b.Status == StatusLive, "bet is not waiting for reports")
	result = normalizeResult(result)

	switch caller {
	case b.PlayerA:
		require(b.ReportA == "", "you already reported")
		b.ReportA = result
	case b.PlayerB:
		require(b.ReportB == "", "you already reported")
		b.ReportB = result
	default:
		panic("only the two players can report")
	}

	if b.ReportA == "" || b.ReportB == "" {
		b.FirstReportAt = time.Now()
		return
	}

	if b.ReportA == b.ReportB {
		b.settle(b.ReportA, nil)
		pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), b.Payouts)
		return
	}

	if !b.openDispute() {
		pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), b.Payouts)
	}
}

// Escalate sends a bet to the judges when one player reported and the
// other went quiet for longer than the report window.
func Escalate(cur realm, betID int) {
	caller := cur.Previous().Address()
	b := mustBet(betID)
	require(b.Status == StatusLive, "bet is not waiting for reports")
	require(caller == b.PlayerA || caller == b.PlayerB, "only the players can escalate")
	require((b.ReportA == "") != (b.ReportB == ""), "escalate needs exactly one report")
	require(time.Now().After(b.FirstReportAt.Add(ReportWindow)), "the other player still has time to report")

	if !b.openDispute() {
		pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), b.Payouts)
	}
}

// Vote is for judges of a disputed bet: "a", "b" or "draw".
// The bet settles the moment one result has a strict majority of judges.
func Vote(cur realm, betID int, result string) {
	caller := cur.Previous().Address()
	b := mustBet(betID)
	require(b.Status == StatusDisputed, "bet is not in dispute")
	require(b.isJudge(caller), "you are not a judge on this bet")
	require(!b.Votes.Has(caller.String()), "you already voted")
	require(time.Now().Before(b.Deadline), "voting is closed")
	result = normalizeResult(result)

	b.Votes.Set(caller.String(), result)

	if b.countVotes(result)*2 > len(b.Judges) {
		var majority []address
		for _, j := range b.Judges {
			if v, ok := b.Votes.Get(j.String()).(string); ok && v == result {
				majority = append(majority, j)
			}
		}
		b.settle(result, majority)
		pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), b.Payouts)
	}
}

// ExpireDispute refunds everyone if the judges failed to reach a majority
// before the deadline. Anyone can call it.
func ExpireDispute(cur realm, betID int) {
	b := mustBet(betID)
	require(b.Status == StatusDisputed, "bet is not in dispute")
	require(time.Now().After(b.Deadline), "voting is still open")
	b.refundAll("no judge majority")
	pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), b.Payouts)
}

// ---------------------------------------------------------------------------
// Settlement logic (pure bookkeeping, no coins move here)

// openDispute snapshots the judges. It returns false if the bet had to be
// refunded instead (a table with no possible judges).
func (b *Bet) openDispute() bool {
	if len(b.Judges) == 0 {
		b.refundAll("no judges at this table")
		return false
	}
	b.Status = StatusDisputed
	b.Deadline = time.Now().Add(VoteWindow)
	return true
}

func (b *Bet) refundAll(why string) {
	b.Status = StatusRefunded
	each := b.Stake + b.Bond
	b.Payouts = []Payout{
		{b.PlayerA, each, why + ", refund"},
		{b.PlayerB, each, why + ", refund"},
	}
}

// settle fills in b.Payouts for a final result and updates the leaderboard.
// majority is nil when the players agreed (no judges involved).
func (b *Bet) settle(final string, majority []address) {
	b.Status = StatusSettled
	totalSettled++
	b.Final = final
	pot := 2 * b.Stake

	disputed := majority != nil
	fee := int64(0)
	if disputed {
		fee = 2 * (b.Stake / 100) // 1% of the pot, always even
	}

	var payouts []Payout
	add := func(to address, amt int64, why string) {
		if amt > 0 {
			payouts = append(payouts, Payout{to, amt, why})
		}
	}

	// 1. The pot, minus the judges' fee.
	switch final {
	case ResultA:
		add(b.PlayerA, pot-fee, "won the pot")
	case ResultB:
		add(b.PlayerB, pot-fee, "won the pot")
	case ResultDraw:
		add(b.PlayerA, b.Stake-fee/2, "draw, stake back")
		add(b.PlayerB, b.Stake-fee/2, "draw, stake back")
	}

	// 2. Honesty bonds.
	forfeited := int64(0)
	var honest []address
	t := mustTable(b.TableID)
	players := []address{b.PlayerA, b.PlayerB}
	reports := []string{b.ReportA, b.ReportB}
	for i := range players {
		if !disputed || reports[i] == final {
			add(players[i], b.Bond, "bond back")
			if disputed {
				honest = append(honest, players[i])
			}
		} else {
			forfeited += b.Bond
			t.stats(players[i]).DisputesLost++
			liarsCaught++
		}
	}

	// 3. Forfeited bonds: half to the honest player(s), half to judges.
	judgePool := fee
	if forfeited > 0 {
		if len(honest) > 0 {
			toHonest := forfeited / 2
			judgePool += forfeited - toHonest
			split(honest, toHonest, "liar's bond", add)
		} else {
			judgePool += forfeited
		}
	}

	// 4. Judges who voted with the majority split their pool.
	if disputed {
		split(majority, judgePool, "judge reward", add)
		for _, j := range majority {
			t.stats(j).Judged++
		}
	}

	b.Payouts = payouts
	if pot > biggestPot {
		biggestPot = pot
	}
	for _, j := range majority {
		judgesPaid += received(payouts, j)
	}

	// Leaderboard: net result per person, relative to what they put in.
	deposit := b.Stake + b.Bond
	t.stats(b.PlayerA).Net += received(payouts, b.PlayerA) - deposit
	t.stats(b.PlayerB).Net += received(payouts, b.PlayerB) - deposit
	for _, j := range majority {
		t.stats(j).Net += received(payouts, j)
	}
	switch final {
	case ResultA:
		t.stats(b.PlayerA).Wins++
		t.stats(b.PlayerB).Losses++
	case ResultB:
		t.stats(b.PlayerB).Wins++
		t.stats(b.PlayerA).Losses++
	case ResultDraw:
		t.stats(b.PlayerA).Draws++
		t.stats(b.PlayerB).Draws++
	}
}

// split divides amount evenly; the remainder goes to the first recipient so
// no dust is ever stuck in the realm.
func split(to []address, amount int64, why string, add func(address, int64, string)) {
	if len(to) == 0 || amount <= 0 {
		return
	}
	n := int64(len(to))
	each := amount / n
	rest := amount - each*n
	for i, a := range to {
		amt := each
		if i == 0 {
			amt += rest
		}
		add(a, amt, why)
	}
}

func received(payouts []Payout, who address) int64 {
	total := int64(0)
	for _, p := range payouts {
		if p.To == who {
			total += p.Amount
		}
	}
	return total
}

// pay moves the coins. The banker is always created inside the exported
// crossing function, from its own cur.
func pay(bk banker.Banker, from address, payouts []Payout) {
	for _, p := range payouts {
		bk.SendCoins(from, p.To, chain.Coins{{"ugnot", p.Amount}})
	}
}

// ---------------------------------------------------------------------------
// Read-only getters

func GetTableName(tableID int) string { return mustTable(tableID).Name }
func GetBetStatus(betID int) string   { return mustBet(betID).Status.String() }
func GetBetResult(betID int) string   { return mustBet(betID).Final }

func GetNet(tableID int, who address) int64 {
	t := mustTable(tableID)
	if v := t.Stats.Get(who.String()); v != nil {
		return v.(*Stats).Net
	}
	return 0
}

// ---------------------------------------------------------------------------
// Helpers

func (t *Table) isMember(a address) bool {
	for _, m := range t.Members {
		if m == a {
			return true
		}
	}
	return false
}

// setName validates and stores a nickname (unique per table). An empty
// nickname clears it, and the address is shown instead.
func (t *Table) setName(a address, nickname string) {
	nickname = strings.TrimSpace(nickname)
	if nickname == "" {
		t.Names.Remove(a.String())
		return
	}
	require(len(nickname) <= 24, "nickname too long (max 24)")
	for _, r := range nickname {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') ||
			r == ' ' || r == '-' || r == '_' || r == '.'
		require(ok, "nickname can only use letters, numbers, spaces, - _ .")
	}
	lower := strings.ToLower(nickname)
	t.Names.Iterate("", "", func(k string, v any) bool {
		require(k == a.String() || strings.ToLower(v.(string)) != lower, "nickname already taken at this table")
		return false
	})
	t.Names.Set(a.String(), nickname)
}

// Nick returns a member's nickname, or "" if they have none.
func (t *Table) Nick(a address) string {
	if v := t.Names.Get(a.String()); v != nil {
		return v.(string)
	}
	return ""
}

// judgesFor lists every member except the two players.
func (t *Table) judgesFor(a, b address) []address {
	var judges []address
	for _, m := range t.Members {
		if m != a && m != b {
			judges = append(judges, m)
		}
	}
	return judges
}

// resolve finds a member by nickname (case-insensitive) or g1 address.
func (t *Table) resolve(who string) address {
	who = strings.TrimSpace(who)
	if strings.HasPrefix(who, "g1") {
		if a := address(who); a.IsValid() {
			require(t.isMember(a), "opponent is not a member of this table")
			return a
		}
	}
	lower := strings.ToLower(who)
	var found address
	t.Names.Iterate("", "", func(k string, v any) bool {
		if strings.ToLower(v.(string)) == lower {
			found = address(k)
			return true
		}
		return false
	})
	require(found != "" && t.isMember(found), "opponent is not a member of this table")
	return found
}

func (t *Table) stats(a address) *Stats {
	if v := t.Stats.Get(a.String()); v != nil {
		return v.(*Stats)
	}
	s := &Stats{}
	t.Stats.Set(a.String(), s)
	return s
}

func (b *Bet) isJudge(a address) bool {
	for _, j := range b.Judges {
		if j == a {
			return true
		}
	}
	return false
}

func (b *Bet) countVotes(result string) int {
	n := 0
	b.Votes.Iterate("", "", func(_ string, v any) bool {
		if v.(string) == result {
			n++
		}
		return false
	})
	return n
}

// printable rejects control characters (newlines, tabs, etc.).
func printable(s string) bool {
	for _, r := range s {
		if r < 32 || r == 127 {
			return false
		}
	}
	return true
}

func normalizeResult(r string) string {
	r = strings.ToLower(strings.TrimSpace(r))
	require(r == ResultA || r == ResultB || r == ResultDraw, `result must be "a", "b" or "draw"`)
	return r
}

func requireSent(want int64) {
	sent := unsafe.OriginSend()
	require(len(sent) == 1 && sent[0].Denom == "ugnot",
		"send exactly "+strconv.FormatInt(want, 10)+"ugnot (stake + 10% bond)")
	require(sent[0].Amount == want,
		"send exactly "+strconv.FormatInt(want, 10)+"ugnot (stake + 10% bond)")
}

func mustTable(id int) *Table {
	v := tables.Get(strconv.Itoa(id))
	if v == nil {
		panic("table not found")
	}
	return v.(*Table)
}

func mustBet(id int) *Bet {
	v := bets.Get(strconv.Itoa(id))
	if v == nil {
		panic("bet not found")
	}
	return v.(*Bet)
}

func require(ok bool, msg string) {
	if !ok {
		panic(msg)
	}
}
