package tavernwagers

import (
	"chain/banker"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

// Group bets ("pools") are for games with more than two players: a poker
// night, a FIFA tournament, a pub quiz. Every player locks the same stake
// plus a 10% bond. The pot is paid out by finishing position, using shares
// chosen up front: "100" is winner-takes-all, "60,30,10" pays the top three.
//
// Nobody deals the result. Every player reports the finishing order; if
// they all agree, the pot pays out instantly. If anyone disagrees, the
// table members who did NOT play judge it, exactly like a 1v1 bet. Any
// player whose report loses the vote forfeits their bond.

const (
	MaxPoolPlayers = 20
	MinJudges      = 3 // recommended minimum judge panel for a group bet
)

type Pool struct {
	ID      int
	TableID int
	Title   string
	Creator address
	Players []address // invited players, creator first
	Joined  *avl.Tree // address -> true once their stake is locked
	Stake   int64
	Bond    int64
	Shares  []int64 // percent of the pot by finishing position, sums to 100
	Status  BetStatus

	Reports       *avl.Tree // address -> canonical ranking
	FirstReportAt time.Time

	Judges   []address
	Votes    *avl.Tree // address -> canonical ranking
	Deadline time.Time

	FewJudges bool // created with fewer than MinJudges possible judges

	Final   string // canonical ranking: comma-separated addresses, 1st first
	Payouts []Payout
	Created time.Time
}

var (
	pools   avl.Tree // id -> *Pool
	poolSeq int
)

// CreatePool opens a group bet and locks your stake. players is a
// comma-separated list of the OTHER players' nicknames (or addresses).
// payout is the split of the pot by finishing position in percent:
// "100" (winner takes all) or e.g. "60,30,10". Send stake + 10% bond.
//
// Disputes are decided by the table members who are NOT playing. We want at
// least MinJudges of them, so no one or two people hold all the power. A
// table can still play with fewer (everyone wants in on poker night) by
// setting acceptFewJudges, which is shown as a warning on the game.
func CreatePool(cur realm, tableID int, title string, players string, stake int64, payout string, acceptFewJudges bool) int {
	require(cur.Previous().IsUserCall(), "only direct user calls accepted")
	caller := cur.Previous().Address()
	t := mustTable(tableID)
	title = strings.TrimSpace(title)
	require(title != "", "title required")
	require(len(title) <= 140, "title too long (max 140)")
	require(printable(title), "title has invalid characters")
	require(t.isMember(caller), "you are not a member of this table")
	require(stake >= MinStake, "stake too small (min "+strconv.FormatInt(MinStake, 10)+"ugnot)")

	list := []address{caller}
	for _, name := range strings.Split(players, ",") {
		if strings.TrimSpace(name) == "" {
			continue
		}
		a := t.resolve(name)
		require(!containsAddr(list, a), "a player is listed twice")
		list = append(list, a)
	}
	require(len(list) >= 3, "a group bet needs at least 3 players (use a 1v1 bet for 2)")
	require(len(list) <= MaxPoolPlayers, "too many players (max 20)")

	shares := parseShares(payout)
	require(len(shares) < len(list), "more paid places than players minus one")

	judgesNow := len(t.Members) - len(list)
	require(judgesNow >= MinJudges || acceptFewJudges,
		"only "+strconv.Itoa(judgesNow)+" table member(s) left to judge disputes (we recommend "+strconv.Itoa(MinJudges)+
			"): leave some people out to judge, or set acceptFewJudges to play anyway")

	bond := stake / 10
	requireSent(stake + bond)

	poolSeq++
	p := &Pool{
		ID:      poolSeq,
		TableID: tableID,
		Title:   title,
		Creator: caller,
		Players: list,
		Joined:  avl.NewTree(),
		Stake:   stake,
		Bond:    bond,
		Shares:  shares,
		Status:  StatusOpen,
		Reports: avl.NewTree(),
		Votes:   avl.NewTree(),
		Created: time.Now(),

		FewJudges: judgesNow < MinJudges,
	}
	p.Joined.Set(caller.String(), true)
	pools.Set(strconv.Itoa(p.ID), p)
	t.PoolIDs = append(t.PoolIDs, p.ID)
	return p.ID
}

// JoinPool locks your stake + bond. The game goes live once every invited
// player has joined; the judges are fixed at that moment.
func JoinPool(cur realm, poolID int) {
	require(cur.Previous().IsUserCall(), "only direct user calls accepted")
	caller := cur.Previous().Address()
	p := mustPool(poolID)
	require(p.Status == StatusOpen, "this group bet is not open")
	require(containsAddr(p.Players, caller), "you are not invited to this group bet")
	require(!p.Joined.Has(caller.String()), "you already joined")
	requireSent(p.Stake + p.Bond)
	p.Joined.Set(caller.String(), true)

	if p.Joined.Size() == len(p.Players) {
		p.Status = StatusLive
		t := mustTable(p.TableID)
		var judges []address
		for _, m := range t.Members {
			if !containsAddr(p.Players, m) {
				judges = append(judges, m)
			}
		}
		p.Judges = judges
		totalLocked += int64(len(p.Players)) * (p.Stake + p.Bond)
	}
}

// CancelPool lets the creator call it off before everyone joined.
// Everyone who already joined is refunded in full.
func CancelPool(cur realm, poolID int) {
	caller := cur.Previous().Address()
	p := mustPool(poolID)
	require(p.Status == StatusOpen, "only open group bets can be cancelled")
	require(caller == p.Creator, "only the creator can cancel")
	p.Status = StatusCancelled
	for _, a := range p.Players {
		if p.Joined.Has(a.String()) {
			p.Payouts = append(p.Payouts, Payout{a, p.Stake + p.Bond, "cancelled, refund"})
		}
	}
	pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), p.Payouts)
}

// ReportPool is how each player reports the finishing order of the paid
// places, as comma-separated nicknames: "Alice,Bob" for 1st and 2nd.
// When every player has reported the same order, the pot pays out.
func ReportPool(cur realm, poolID int, ranking string) {
	caller := cur.Previous().Address()
	p := mustPool(poolID)
	require(p.Status == StatusLive, "this group bet is not waiting for reports")
	require(containsAddr(p.Players, caller), "only players can report")
	require(!p.Reports.Has(caller.String()), "you already reported")
	r := p.canonical(ranking)
	p.Reports.Set(caller.String(), r)

	if p.Reports.Size() == 1 {
		p.FirstReportAt = time.Now()
	}
	if p.Reports.Size() < len(p.Players) {
		return
	}
	if p.allReportsAgree() {
		p.settle(r, nil)
	} else {
		p.openDispute()
	}
	pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), p.Payouts)
}

// EscalatePool sends the group bet to the judges when some players went
// quiet for longer than the report window.
func EscalatePool(cur realm, poolID int) {
	caller := cur.Previous().Address()
	p := mustPool(poolID)
	require(p.Status == StatusLive, "this group bet is not waiting for reports")
	require(containsAddr(p.Players, caller), "only players can escalate")
	require(p.Reports.Size() > 0, "nobody has reported yet")
	require(time.Now().After(p.FirstReportAt.Add(ReportWindow)), "players still have time to report")
	p.openDispute()
	pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), p.Payouts)
}

// VotePool is for judges of a disputed group bet. The order with a strict
// majority of judges wins.
func VotePool(cur realm, poolID int, ranking string) {
	caller := cur.Previous().Address()
	p := mustPool(poolID)
	require(p.Status == StatusDisputed, "this group bet is not in dispute")
	require(containsAddr(p.Judges, caller), "you are not a judge on this group bet")
	require(!p.Votes.Has(caller.String()), "you already voted")
	require(time.Now().Before(p.Deadline), "voting is closed")
	r := p.canonical(ranking)
	p.Votes.Set(caller.String(), r)

	if countValue(p.Votes, r)*2 > len(p.Judges) {
		var majority []address
		for _, j := range p.Judges {
			if v, ok := p.Votes.Get(j.String()).(string); ok && v == r {
				majority = append(majority, j)
			}
		}
		p.settle(r, majority)
		pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), p.Payouts)
	}
}

// ExpirePool refunds everyone if the judges missed the deadline.
func ExpirePool(cur realm, poolID int) {
	p := mustPool(poolID)
	require(p.Status == StatusDisputed, "this group bet is not in dispute")
	require(time.Now().After(p.Deadline), "voting is still open")
	p.refundAll("no judge majority")
	pay(banker.NewBanker(banker.BankerTypeRealmSend, cur), cur.Address(), p.Payouts)
}

// ---------------------------------------------------------------------------
// Settlement (bookkeeping only)

func (p *Pool) openDispute() {
	if len(p.Judges) == 0 {
		p.refundAll("no judges at this table")
		return
	}
	p.Status = StatusDisputed
	p.Deadline = time.Now().Add(VoteWindow)
}

func (p *Pool) refundAll(why string) {
	p.Status = StatusRefunded
	p.Payouts = nil
	for _, a := range p.Players {
		p.Payouts = append(p.Payouts, Payout{a, p.Stake + p.Bond, why + ", refund"})
	}
}

func (p *Pool) settle(final string, majority []address) {
	p.Status = StatusSettled
	p.Final = final
	totalSettled++
	t := mustTable(p.TableID)
	n := int64(len(p.Players))
	pot := n * p.Stake
	disputed := majority != nil
	fee := int64(0)
	if disputed {
		fee = pot / 100
	}

	var payouts []Payout
	add := func(to address, amt int64, why string) {
		if amt > 0 {
			payouts = append(payouts, Payout{to, amt, why})
		}
	}

	// 1. The pot, by finishing position. Rounding dust goes to 1st place.
	order := p.rankingAddrs(final)
	prize := pot - fee
	rest := int64(0)
	for i := 1; i < len(order); i++ {
		rest += prize * p.Shares[i] / 100
	}
	for i, a := range order {
		amt := prize * p.Shares[i] / 100
		if i == 0 {
			amt = prize - rest
		}
		add(a, amt, placeName(i)+" place")
	}

	// 2. Bonds.
	forfeited := int64(0)
	var honest []address
	for _, a := range p.Players {
		rep, _ := p.Reports.Get(a.String()).(string)
		if !disputed || rep == final {
			add(a, p.Bond, "bond back")
			if disputed {
				honest = append(honest, a)
			}
		} else {
			forfeited += p.Bond
			t.stats(a).DisputesLost++
			liarsCaught++
		}
	}

	// 3. Forfeited bonds: half to honest players, half to judges.
	judgePool := fee
	if forfeited > 0 {
		if len(honest) > 0 {
			toHonest := forfeited / 2
			judgePool += forfeited - toHonest
			split(honest, toHonest, "liars' bonds", add)
		} else {
			judgePool += forfeited
		}
	}
	if disputed {
		split(majority, judgePool, "judge reward", add)
		for _, j := range majority {
			t.stats(j).Judged++
			t.stats(j).Net += received(payouts, j)
		}
	}
	p.Payouts = payouts
	if pot > biggestPot {
		biggestPot = pot
	}
	for _, j := range majority {
		judgesPaid += received(payouts, j)
	}

	// Leaderboard.
	deposit := p.Stake + p.Bond
	for _, a := range p.Players {
		s := t.stats(a)
		s.Net += received(payouts, a) - deposit
		if len(order) > 0 && a == order[0] {
			s.Wins++
		} else if !containsAddr(order, a) {
			s.Losses++
		}
	}
}

// ---------------------------------------------------------------------------
// Rankings

// canonical turns "Alice, bob" into "g1...,g1..." with exactly as many
// entries as there are paid places, all distinct players.
func (p *Pool) canonical(ranking string) string {
	t := mustTable(p.TableID)
	var out []string
	var seen []address
	for _, name := range strings.Split(ranking, ",") {
		if strings.TrimSpace(name) == "" {
			continue
		}
		a := t.resolve(name)
		require(containsAddr(p.Players, a), "everyone in the ranking must be a player")
		require(!containsAddr(seen, a), "a player is ranked twice")
		seen = append(seen, a)
		out = append(out, a.String())
	}
	require(len(out) == len(p.Shares), "rank exactly "+strconv.Itoa(len(p.Shares))+" player(s), best first")
	return strings.Join(out, ",")
}

func (p *Pool) rankingAddrs(r string) []address {
	var out []address
	for _, s := range strings.Split(r, ",") {
		if s != "" {
			out = append(out, address(s))
		}
	}
	return out
}

func (p *Pool) allReportsAgree() bool {
	first := ""
	agree := true
	p.Reports.Iterate("", "", func(_ string, v any) bool {
		if first == "" {
			first = v.(string)
		} else if v.(string) != first {
			agree = false
			return true
		}
		return false
	})
	return agree
}

func parseShares(payout string) []int64 {
	payout = strings.TrimSpace(payout)
	if payout == "" {
		payout = "100"
	}
	var shares []int64
	total := int64(0)
	for _, s := range strings.Split(payout, ",") {
		n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
		require(err == nil && n > 0, `payout must be percentages like "100" or "60,30,10"`)
		shares = append(shares, n)
		total += n
	}
	require(total == 100, "payout percentages must add up to 100")
	for i := 1; i < len(shares); i++ {
		require(shares[i] <= shares[i-1], "payout must not grow for lower places")
	}
	return shares
}

func placeName(i int) string {
	switch i {
	case 0:
		return "1st"
	case 1:
		return "2nd"
	case 2:
		return "3rd"
	}
	return strconv.Itoa(i+1) + "th"
}

func containsAddr(list []address, a address) bool {
	for _, x := range list {
		if x == a {
			return true
		}
	}
	return false
}

func countValue(tree *avl.Tree, want string) int {
	n := 0
	tree.Iterate("", "", func(_ string, v any) bool {
		if v.(string) == want {
			n++
		}
		return false
	})
	return n
}

func mustPool(id int) *Pool {
	v := pools.Get(strconv.Itoa(id))
	if v == nil {
		panic("group bet not found")
	}
	return v.(*Pool)
}

// GetPoolStatus returns a group bet's status.
func GetPoolStatus(poolID int) string { return mustPool(poolID).Status.String() }
