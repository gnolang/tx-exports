// Package gauntlet is a bounty board where the chain grades the answers.
//
// Post a coding challenge with a GNOT reward. Solvers commit a hash, deploy a
// realm with a Solve function, and reveal it. This realm runs the tests itself
// and pays the earliest commit that passes. No reviewer, no disputes.
package gauntlet

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strings"
	"time"

	"gno.land/p/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
	"gno.land/p/nt/avl/v0"
)

const denom = "ugnot"

var (
	board    gauntlet.Board
	profiles avl.Tree // address -> *Profile
	judges   avl.Tree // judge realm path -> *JudgeInfo

	pkgPath = unsafe.CurrentRealm().PkgPath()

	totalPaid int64 // ugnot paid to winners
	paidOut   []*PaidRecord
)

// Profile tracks what an address has done on the board.
type Profile struct {
	Addr     address
	Attempts int
	Solved   int
	Earned   int64
	Posted   int
	Funded   int64
}

// JudgeInfo is a registered judge: reusable, immutable test logic.
type JudgeInfo struct {
	Path  string
	Name  string
	About string
	Judge *gauntlet.Judge
	Uses  int
}

// PaidRecord is one winner payout, for the activity feed.
type PaidRecord struct {
	ChallengeID uint64
	To          address
	Amount      int64
	At          time.Time
}

// Post creates a challenge with fixed test cases. Send the reward in ugnot
// with the call. cases has one test per line: `input => expected output`.
func Post(cur realm, title, spec, cases string, hours int, bond int64, windowMinutes int) uint64 {
	poster := mustUser(cur)
	reward := sentUgnot()
	parsed, err := gauntlet.ParseCases(cases)
	if err != nil {
		panic(err)
	}
	return post(poster, gauntlet.PostParams{
		Title: title, Spec: spec, Poster: poster, Reward: reward, Bond: bond,
		Deadline: time.Now().Add(time.Duration(hours) * time.Hour),
		Window:   time.Duration(windowMinutes) * time.Minute,
		Cases:    parsed,
	})
}

// PostJudged creates a challenge graded by a registered judge (see
// RegisterJudge), plus optional fixed cases. Send the reward with the call.
func PostJudged(cur realm, title, spec, judgePath, cases string, hours int, bond int64, windowMinutes int) uint64 {
	poster := mustUser(cur)
	reward := sentUgnot()
	v := judges.Get(judgePath)
	if v == nil {
		panic("gauntlet: no judge registered at " + judgePath)
	}
	ji := v.(*JudgeInfo)
	var parsed []gauntlet.Case
	if strings.TrimSpace(cases) != "" {
		var err error
		parsed, err = gauntlet.ParseCases(cases)
		if err != nil {
			panic(err)
		}
	}
	id := post(poster, gauntlet.PostParams{
		Title: title, Spec: spec, Poster: poster, Reward: reward, Bond: bond,
		Deadline:  time.Now().Add(time.Duration(hours) * time.Hour),
		Window:    time.Duration(windowMinutes) * time.Minute,
		Cases:     parsed,
		Judge:     ji.Judge,
		JudgePath: ji.Path,
	})
	ji.Uses++
	return id
}

func post(poster address, p gauntlet.PostParams) uint64 {
	c, err := board.Post(p, time.Now())
	if err != nil {
		panic(err)
	}
	pr := profile(poster)
	pr.Posted++
	pr.Funded += p.Reward
	chain.Emit("Posted", "id", itoa(c.ID), "poster", poster.String(), "reward", i64toa(p.Reward))
	return c.ID
}

// RegisterJudge is called by a judge realm, usually from its init. The judge
// is stored under the caller's package path and can never change, so every
// bounty that uses it is graded by exactly the code anyone can read.
func RegisterJudge(cur realm, name, about string, inputs func(seed uint64) []string, check func(in, out string) bool) {
	prev := cur.Previous()
	if prev.IsUser() {
		panic("gauntlet: judges must be registered by a deployed realm")
	}
	path := prev.PkgPath()
	if judges.Has(path) {
		panic("gauntlet: judge already registered for " + path)
	}
	if inputs == nil || check == nil {
		panic("gauntlet: judge needs both inputs and check")
	}
	judges.Set(path, &JudgeInfo{
		Path: path, Name: name, About: about,
		Judge: &gauntlet.Judge{Inputs: inputs, Check: check},
	})
	chain.Emit("JudgeRegistered", "path", path)
}

// Commit reserves your place in line with sha256(solutionPath + ":" + salt).
// Send the challenge's bond with the call. Use HashFor to compute the hash.
func Commit(cur realm, id uint64, hash string) {
	solver := mustUser(cur)
	if _, err := board.Commit(id, solver, hash, sentUgnot(), time.Now()); err != nil {
		panic(err)
	}
	profile(solver).Attempts++
	chain.Emit("Committed", "id", itoa(id), "solver", solver.String())
}

// Reveal is called by your solution realm, never by a wallet directly:
//
//	func Submit(cur realm, id uint64, salt string) {
//		gauntlet.Reveal(cross(cur), id, salt, Solve)
//	}
//
// The realm path of the caller is read from the runtime, so nobody can reveal
// on behalf of a commit they do not own. The tests run here, on-chain.
func Reveal(cur realm, id uint64, salt string, solve func(string) string) {
	prev := cur.Previous()
	if !prev.IsCode() || prev.IsUser() {
		panic(gauntlet.ErrNotRealm)
	}
	if solve == nil {
		panic("gauntlet: nil solver")
	}
	a, payouts, err := board.Reveal(id, prev.PkgPath(), salt, solve, time.Now())
	if err != nil {
		panic(err)
	}
	chain.Emit("Revealed", "id", itoa(id), "solver", a.Solver.String(), "state", a.State.String(),
		"passed", itoa(uint64(a.Report.Passed)), "total", itoa(uint64(a.Report.Total)))
	pay(cur, id, payouts)
}

// Settle expires late commits and pays out when the result is final.
// Anyone can call it.
func Settle(cur realm, id uint64) {
	payouts, err := board.Settle(id, time.Now())
	if err != nil {
		panic(err)
	}
	pay(cur, id, payouts)
}

// Boost adds the ugnot sent with the call to an open challenge's reward.
func Boost(cur realm, id uint64) {
	from := mustUser(cur)
	amt := sentUgnot()
	if err := board.Boost(id, amt, time.Now()); err != nil {
		panic(err)
	}
	profile(from).Funded += amt
	chain.Emit("Boosted", "id", itoa(id), "from", from.String(), "amount", i64toa(amt))
}

// HashFor computes the commit hash for a solution realm path and a salt.
// Keep the salt secret until you reveal.
func HashFor(pkgPath, salt string) string {
	return gauntlet.HashSolution(pkgPath, salt)
}

func pay(cur realm, id uint64, payouts []gauntlet.Payout) {
	if len(payouts) == 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	self := cur.Address()
	c := board.Get(id)
	for _, p := range payouts {
		if p.Amount <= 0 {
			continue
		}
		bk.SendCoins(self, p.To, chain.Coins{chain.NewCoin(denom, p.Amount)})
		if p.Reason == "bounty won" {
			totalPaid += p.Amount
			pr := profile(p.To)
			pr.Solved++
			pr.Earned += p.Amount
			paidOut = append(paidOut, &PaidRecord{ChallengeID: c.ID, To: p.To, Amount: p.Amount, At: time.Now()})
			chain.Emit("Won", "id", itoa(c.ID), "winner", p.To.String(), "amount", i64toa(p.Amount))
		}
	}
}

func mustUser(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("gauntlet: call this directly from a wallet (maketx call)")
	}
	return prev.Address()
}

// sentUgnot returns the ugnot sent with a direct wallet call. Other denoms
// are rejected so nothing gets stuck.
func sentUgnot() int64 {
	var amt int64
	for _, c := range unsafe.OriginSend() {
		if c.Denom != denom {
			panic("gauntlet: only ugnot is accepted")
		}
		amt += c.Amount
	}
	return amt
}

func profile(a address) *Profile {
	if v := profiles.Get(a.String()); v != nil {
		return v.(*Profile)
	}
	p := &Profile{Addr: a}
	profiles.Set(a.String(), p)
	return p
}

func selfPkgPath() string { return pkgPath }
