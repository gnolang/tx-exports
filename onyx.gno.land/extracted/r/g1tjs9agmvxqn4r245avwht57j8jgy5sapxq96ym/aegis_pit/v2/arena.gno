package aegis_pit

import (
	"strconv"

	core "gno.land/p/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_core"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/seqid/v0"
)

// ======================= Fighters & Backer Tokens =======================

const shareScale int64 = 1_000_000

// BackerLedger wraps a real GRC20 token (gno.land/p/nt/grc20) minted per
// fighter. Holders earn 3% of every ranked pool their fighter wins through a
// reward-per-share accumulator (O(1) per payout, no loops over holders).
//
// The token's *Token / *PrivateLedger stay private to this realm: other realms
// read it through BackerToken(id), a standard read-only grc20.Teller, and
// holders move it with TransferBacker, which settles dividends first. Exposing
// the raw *Token would let any realm holding BACK tokens move them with
// RealmTeller and skip settlement, so it is deliberately never handed out.
type BackerLedger struct {
	Symbol      string
	Supply      int64
	token       *grc20.Token
	ledger      *grc20.PrivateLedger
	debt        *avl.Tree // addr -> int64 (already-accounted rewards)
	accPerShare int64     // scaled by shareScale
	Distributed int64
}

func (l *BackerLedger) BalanceOf(a address) int64 { return l.token.BalanceOf(a) }

func (l *BackerLedger) debtOf(a address) int64 {
	v := l.debt.Get(string(a))
	if v == nil {
		return 0
	}
	return v.(int64)
}

func (l *BackerLedger) Pending(a address) int64 {
	return l.BalanceOf(a)*l.accPerShare/shareScale - l.debtOf(a)
}

// settle moves pending rewards to the holder's claimable credits.
func (l *BackerLedger) settle(a address) {
	addCredit(a, l.Pending(a))
	l.debt.Set(string(a), l.BalanceOf(a)*l.accPerShare/shareScale)
}

func (l *BackerLedger) reward(amt int64) int64 {
	if amt <= 0 || l.Supply == 0 {
		return 0
	}
	inc := amt * shareScale / l.Supply
	l.accPerShare += inc
	paid := inc * l.Supply / shareScale
	l.Distributed += paid
	return amt - paid // dust
}

func (l *BackerLedger) transfer(from, to address, amt int64) {
	if amt <= 0 || l.BalanceOf(from) < amt {
		panic("aegis: insufficient backer tokens")
	}
	l.settle(from)
	l.settle(to)
	if err := l.ledger.Transfer(from, to, amt); err != nil {
		panic("aegis: " + err.Error())
	}
	l.debt.Set(string(from), l.BalanceOf(from)*l.accPerShare/shareScale)
	l.debt.Set(string(to), l.BalanceOf(to)*l.accPerShare/shareScale)
}

type Fighter struct {
	ID       int
	Name     string
	PkgPath  string // public Gno source of the fighter's strategy (read by rival AIs via gnomcp)
	Owner    address
	Agent    address // optional AI agent key allowed to commit/reveal
	Backers  *BackerLedger
	Wins     int
	Losses   int
	Draws    int
	Forfeits int
	Badges   []string
}

func getFighter(id int) *Fighter {
	v := fighters.Get(key(id))
	if v == nil {
		panic("aegis: fighter not found")
	}
	return v.(*Fighter)
}

func (f *Fighter) controls(a address) bool {
	return a == f.Owner || (f.Agent != "" && a == f.Agent)
}

// RegisterFighter registers an AI fighter and mints its Backer Tokens to the owner.
func RegisterFighter(cur realm, name, pkgPath string, backerSupply int64) int {
	if len(name) == 0 || len(name) > 24 {
		panic("aegis: name must be 1..24 chars")
	}
	if backerSupply < 1 || backerSupply > 1_000_000_000 {
		panic("aegis: backerSupply must be 1..1e9")
	}
	owner := caller(cur)
	nFighters++
	symbol := "BACK" + strconv.Itoa(nFighters)
	tok, led := grc20.NewToken(name+" Backer", symbol, 0, seqid.ID(nFighters), cur)
	if err := led.Mint(owner, backerSupply); err != nil {
		panic("aegis: " + err.Error())
	}
	l := &BackerLedger{Symbol: symbol, Supply: backerSupply, token: tok, ledger: led, debt: avl.NewTree()}
	f := &Fighter{ID: nFighters, Name: name, PkgPath: pkgPath, Owner: owner, Backers: l}
	fighters.Set(key(f.ID), f)
	return f.ID
}

// SetFighterAgent authorizes an AI agent key (e.g. a gnomcp session) to commit/reveal.
func SetFighterAgent(cur realm, fighterID int, agent address) {
	f := getFighter(fighterID)
	if caller(cur) != f.Owner {
		panic("aegis: only the owner can set the agent")
	}
	f.Agent = agent
}

// TransferBacker transfers Backer Tokens of a fighter (rewards are settled first).
func TransferBacker(cur realm, fighterID int, to address, amount int64) {
	if !to.IsValid() {
		panic("aegis: invalid recipient")
	}
	getFighter(fighterID).Backers.transfer(caller(cur), to, amount)
}

// ClaimBackerRewards moves pending backer dividends into claimable credits.
func ClaimBackerRewards(cur realm, fighterID int) {
	getFighter(fighterID).Backers.settle(caller(cur))
}

// BackerToken returns the fighter's GRC20 Backer Token as a standard,
// read-only grc20.Teller (name, symbol, supply, balances).
func BackerToken(fighterID int) grc20.Teller {
	return getFighter(fighterID).Backers.token.ReadonlyTeller()
}

func BackerTokenID(fighterID int) string { return getFighter(fighterID).Backers.token.ID() }

func BackerBalance(fighterID int, a address) int64 { return getFighter(fighterID).Backers.BalanceOf(a) }
func BackerPending(fighterID int, a address) int64 { return getFighter(fighterID).Backers.Pending(a) }

// ======================= Trust =======================

func trustOf(a address) *core.TrustRecord {
	v := trust.Get(string(a))
	if v == nil {
		r := &core.TrustRecord{}
		trust.Set(string(a), r)
		return r
	}
	return v.(*core.TrustRecord)
}

// TrustScore is exported for other realms to import: reputation that only
// moves when real ugnot was at stake.
func TrustScore(a address) int64 {
	v := trust.Get(string(a))
	if v == nil {
		return core.TrustScore(core.TrustRecord{})
	}
	return core.TrustScore(*v.(*core.TrustRecord))
}

// ======================= Matches =======================

const (
	StatusOpen     = "open"     // waiting for opponent
	StatusLive     = "live"     // commits + bets open until CommitDeadline
	StatusResolved = "resolved" // both revealed
	StatusForfeit  = "forfeit"  // someone did not reveal: bond slashed
	StatusCanceled = "canceled"
)

type Match struct {
	ID             int
	Ranked         bool
	A, B           int // fighter IDs (B = 0 while open)
	Bond           int64
	CommitDeadline int64
	RevealDeadline int64
	CommitA        string
	CommitB        string
	MovesA         string
	MovesB         string
	Status         string
	Winner         int // 0 draw, 1 = A, 2 = B
	betsA          *avl.Tree
	betsB          *avl.Tree
	PoolA          int64
	PoolB          int64
	Log            []core.RoundResult
	Note           string
}

func getMatch(id int) *Match {
	v := matches.Get(key(id))
	if v == nil {
		panic("aegis: match not found")
	}
	return v.(*Match)
}

// CreateMatch opens a match for one of your fighters. Attach the bond in ugnot.
// ranked=false is a friendly match (no betting, no trust impact).
func CreateMatch(cur realm, fighterID int, ranked bool) int {
	bond := takeDeposit(cur)
	if bond < MinBond {
		panic("aegis: bond below minimum (" + strconv.FormatInt(MinBond, 10) + " ugnot)")
	}
	f := getFighter(fighterID)
	if !f.controls(caller(cur)) {
		panic("aegis: you do not control this fighter")
	}
	nMatches++
	m := &Match{ID: nMatches, Ranked: ranked, A: fighterID, Bond: bond, Status: StatusOpen,
		betsA: avl.NewTree(), betsB: avl.NewTree()}
	matches.Set(key(m.ID), m)
	return m.ID
}

// CancelMatch refunds the creator's bond while nobody has joined yet.
func CancelMatch(cur realm, matchID int) {
	m := getMatch(matchID)
	f := getFighter(m.A)
	if m.Status != StatusOpen || !f.controls(caller(cur)) {
		panic("aegis: only the creator can cancel an open match")
	}
	m.Status = StatusCanceled
	addCredit(f.Owner, m.Bond)
}

// JoinMatch joins with your fighter, attaching exactly the same bond.
// The commit deadline (and betting lock) is set at this block.
func JoinMatch(cur realm, matchID, fighterID int) {
	amt := takeDeposit(cur)
	m := getMatch(matchID)
	if m.Status != StatusOpen {
		panic("aegis: match is not open")
	}
	if amt != m.Bond {
		panic("aegis: bond must equal " + strconv.FormatInt(m.Bond, 10) + " ugnot")
	}
	fa := getFighter(m.A)
	fb := getFighter(fighterID)
	if !fb.controls(caller(cur)) {
		panic("aegis: you do not control this fighter")
	}
	if fa.Owner == fb.Owner {
		panic("aegis: cannot fight yourself")
	}
	m.B = fighterID
	m.Status = StatusLive
	m.CommitDeadline = height() + CommitWindow
	m.RevealDeadline = m.CommitDeadline + RevealWindow
}

// PlaceBet bets the attached ugnot on side 1 (A) or 2 (B) of a ranked, live match.
func PlaceBet(cur realm, matchID, side int) {
	amt := takeDeposit(cur)
	placeBet(getMatch(matchID), caller(cur), side, amt)
}

func placeBet(m *Match, bettor address, side int, amt int64) {
	if !m.Ranked {
		panic("aegis: friendly matches have no betting")
	}
	if m.Status != StatusLive || height() > m.CommitDeadline {
		panic("aegis: betting is locked")
	}
	if side != 1 && side != 2 {
		panic("aegis: side must be 1 or 2")
	}
	if amt < MinBet {
		panic("aegis: bet too small")
	}
	// Anti match-fixing: an owner can never bet against their own fighter.
	if (side == 2 && getFighter(m.A).Owner == bettor) || (side == 1 && getFighter(m.B).Owner == bettor) {
		panic("aegis: owners cannot bet against their own fighter")
	}
	t := m.betsA
	if side == 2 {
		t = m.betsB
	}
	prev := int64(0)
	if v := t.Get(string(bettor)); v != nil {
		prev = v.(int64)
	}
	t.Set(string(bettor), prev+amt)
	if side == 1 {
		m.PoolA += amt
	} else {
		m.PoolB += amt
	}
}

// CommitMove stores hash(moves:salt) — see aegis_core.CommitHash.
func CommitMove(cur realm, matchID int, commit string) {
	m := getMatch(matchID)
	if m.Status != StatusLive || height() > m.CommitDeadline {
		panic("aegis: commit window closed")
	}
	if len(commit) != 64 {
		panic("aegis: commit must be a 64-char sha256 hex")
	}
	who := caller(cur)
	switch {
	case getFighter(m.A).controls(who):
		if m.CommitA != "" {
			panic("aegis: already committed")
		}
		m.CommitA = commit
	case getFighter(m.B).controls(who):
		if m.CommitB != "" {
			panic("aegis: already committed")
		}
		m.CommitB = commit
	default:
		panic("aegis: not a fighter in this match")
	}
}

// Reveal opens your commitment. Only allowed after the commit deadline (so
// nobody — fighter or bettor — sees a move while bets are open). When both
// sides have revealed, the match resolves and pays out automatically.
func Reveal(cur realm, matchID int, moves, salt string) {
	m := getMatch(matchID)
	if m.Status != StatusLive {
		panic("aegis: match not live")
	}
	h := height()
	if h <= m.CommitDeadline {
		panic("aegis: reveal opens after block " + strconv.FormatInt(m.CommitDeadline, 10))
	}
	if h > m.RevealDeadline {
		panic("aegis: reveal window closed, use SlashNoReveal")
	}
	who := caller(cur)
	switch {
	case getFighter(m.A).controls(who) && m.MovesA == "":
		if err := core.VerifyReveal(m.CommitA, moves, salt); err != nil {
			panic(err.Error())
		}
		m.MovesA = moves
	case getFighter(m.B).controls(who) && m.MovesB == "":
		if err := core.VerifyReveal(m.CommitB, moves, salt); err != nil {
			panic(err.Error())
		}
		m.MovesB = moves
	default:
		panic("aegis: nothing to reveal for caller")
	}
	if m.MovesA != "" && m.MovesB != "" {
		resolve(m)
	}
}

func resolve(m *Match) {
	fa, fb := getFighter(m.A), getFighter(m.B)
	m.Winner, m.Log = core.ResolveDuel(m.MovesA, m.MovesB)
	m.Status = StatusResolved
	addCredit(fa.Owner, m.Bond)
	addCredit(fb.Owner, m.Bond)

	switch m.Winner {
	case 0:
		fa.Draws++
		fb.Draws++
	case 1:
		fa.Wins++
		fb.Losses++
	case 2:
		fb.Wins++
		fa.Losses++
	}

	total := m.PoolA + m.PoolB
	if !m.Ranked {
		m.Note = "friendly match: no pool, no trust change"
		awardBadges(m)
		return
	}
	if m.Winner == 0 {
		refundBets(m)
		m.Note = "draw: all bets refunded"
		return
	}
	winPool, winBets, wf, lf := m.PoolA, m.betsA, fa, fb
	if m.Winner == 2 {
		winPool, winBets, wf, lf = m.PoolB, m.betsB, fb, fa
	}
	tw := trustOf(wf.Owner)
	tl := trustOf(lf.Owner)
	tw.RankedWins++
	tl.RankedLosses++
	tw.StakedVolume += total
	tl.StakedVolume += total

	if winPool == 0 {
		refundBets(m)
		m.Note = "nobody backed the winner: all bets refunded"
		awardBadges(m)
		return
	}
	winners, backers, season := core.SplitPool(total)
	paid := int64(0)
	winBets.Iterate("", "", func(k string, v any) bool {
		share := core.ProRata(v.(int64), winners, winPool)
		addCredit(address(k), share)
		paid += share
		return false
	})
	dust := winners - paid
	dust += wf.Backers.reward(backers)
	seasonFund += season + dust
	m.Note = "pool " + strconv.FormatInt(total, 10) + " ugnot: 95% bettors / 3% backers of " + wf.Name + " / 2% season"
	awardBadges(m)
}

func refundBets(m *Match) {
	refund := func(k string, v any) bool {
		addCredit(address(k), v.(int64))
		return false
	}
	m.betsA.Iterate("", "", refund)
	m.betsB.Iterate("", "", refund)
}

func awardBadges(m *Match) {
	if m.Winner == 0 || len(m.Log) == 0 {
		return
	}
	last := m.Log[len(m.Log)-1]
	w, hp, underdog := getFighter(m.A), last.HPA, m.PoolA < m.PoolB
	if m.Winner == 2 {
		w, hp, underdog = getFighter(m.B), last.HPB, m.PoolB < m.PoolA
	}
	if w.Wins == 1 {
		w.Badges = append(w.Badges, "First Blood")
	}
	if hp == core.StartHP {
		w.Badges = append(w.Badges, "Untouched")
	}
	if m.Ranked && underdog {
		w.Badges = append(w.Badges, "Giant Slayer")
	}
	if w.Wins == 5 {
		w.Badges = append(w.Badges, "Pit Veteran")
	}
}

// SlashNoReveal can be called by anyone after the reveal deadline.
// A fighter who did not reveal loses its bond to the opponent; bettors are refunded.
// If neither revealed, both bonds go to the season fund.
func SlashNoReveal(cur realm, matchID int) {
	m := getMatch(matchID)
	if m.Status != StatusLive || height() <= m.RevealDeadline {
		panic("aegis: nothing to slash yet")
	}
	fa, fb := getFighter(m.A), getFighter(m.B)
	refundBets(m)
	m.Status = StatusForfeit
	id := "match #" + strconv.Itoa(m.ID)
	switch {
	case m.MovesA != "" && m.MovesB == "":
		m.Winner = 1
		addCredit(fa.Owner, 2*m.Bond)
		fb.Forfeits++
		fa.Wins++
		if m.Ranked {
			trustOf(fb.Owner).Forfeits++
		}
		logLab("slash", id+": "+fb.Name+" never revealed, bond "+strconv.FormatInt(m.Bond, 10)+" → "+fa.Name)
	case m.MovesB != "" && m.MovesA == "":
		m.Winner = 2
		addCredit(fb.Owner, 2*m.Bond)
		fa.Forfeits++
		fb.Wins++
		if m.Ranked {
			trustOf(fa.Owner).Forfeits++
		}
		logLab("slash", id+": "+fa.Name+" never revealed, bond "+strconv.FormatInt(m.Bond, 10)+" → "+fb.Name)
	default:
		seasonFund += 2 * m.Bond
		fa.Forfeits++
		fb.Forfeits++
		if m.Ranked {
			trustOf(fa.Owner).Forfeits++
			trustOf(fb.Owner).Forfeits++
		}
		logLab("slash", id+": neither fighter revealed, both bonds → season fund")
	}
	m.Note = "forfeit: bettors refunded"
}

// Read helpers
func MatchStatus(matchID int) string { return getMatch(matchID).Status }
func MatchWinner(matchID int) int    { return getMatch(matchID).Winner }
