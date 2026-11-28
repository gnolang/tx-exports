// Package assertpay pays for code that passes.
//
// A spec is Go code on chain: an interface and a test suite in a frozen /p/
// package. A sponsor funds a task on a spec. A solver commits a hash with a
// bond, deploys an implementation and reveals it from a small entry realm.
// This realm runs the spec's tests against it, in the reveal transaction.
// The earliest-committed passing implementation wins, unless someone
// breaks it during the challenge window with a seed of their choice, which
// pays them the winner's bond. After the window the winner is paid.
//
// The task logic lives in the pure market package; this realm only moves
// coins and decides who may call what. There is no admin key.
package assertpay

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/check/v1"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/market/v1"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/specs/intervals/bad/v1"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/specs/intervals/v1"
	lrubad "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/specs/lru/bad/v1"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/specs/lru/v1"
)

const denom = "ugnot"

type specEntry struct {
	Spec      check.Spec
	Path      string // package holding the interface and tests
	Reviewed  bool   // imported statically by this realm
	Registrar string // realm that registered it (unreviewed specs)
	bad       any    // a known-bad implementation for the walletless demo
}

var (
	specs     = map[string]*specEntry{}
	specOrder []string
	tasks     []*market.Task
	running   bool

	// counters for the home page
	statPaid      int64
	statPaidTasks int
	statAttempts  int
	statBroken    int
)

func init() {
	addSpec(&specEntry{Spec: intervals.Spec(), Path: "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/specs/intervals/v1", Reviewed: true, bad: intervals.Factory(bad.New)})
	addSpec(&specEntry{Spec: lru.Spec(), Path: "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/specs/lru/v1", Reviewed: true, bad: lru.Factory(lrubad.New)})
}

func addSpec(e *specEntry) {
	if _, ok := specs[e.Spec.Name]; ok {
		panic("assertpay: spec name taken")
	}
	specs[e.Spec.Name] = e
	specOrder = append(specOrder, e.Spec.Name)
}

// RegisterSpec adds a spec from another realm (usually from its init). It
// is listed as unreviewed: its test function could be realm code.
func RegisterSpec(cur realm, s check.Spec, path string) {
	guard()
	reg := cur.Previous().PkgPath()
	if reg == "" {
		panic("assertpay: RegisterSpec must be called from a realm")
	}
	if !validName(s.Name) || s.Tests == nil || len(s.Doc) > 600 || !validPkgPath(path) {
		panic("assertpay: bad spec")
	}
	addSpec(&specEntry{Spec: s, Path: path, Registrar: reg})
	chain.Emit("SpecRegistered", "name", s.Name, "registrar", reg)
}

func guard() {
	if running {
		panic("assertpay: re-entrant call")
	}
}

func mustUser(cur realm) address {
	guard()
	if cur.Previous().PkgPath() != "" {
		panic("assertpay: call this directly from your wallet")
	}
	return cur.Previous().Address()
}

func sent() int64 { return unsafe.OriginSend().AmountOf(denom) }

func mustTask(id int) *market.Task {
	if id < 0 || id >= len(tasks) {
		panic("assertpay: unknown task")
	}
	return tasks[id]
}

// Fund opens a task on spec with the ugnot sent as the reward. Commits are
// accepted for deadlineBlocks blocks; each new winner can be challenged for
// windowBlocks blocks before it can be paid (longer gives humans time to
// audit, shorter pays sooner).
func Fund(cur realm, spec string, deadlineBlocks, windowBlocks int64) int {
	who := mustUser(cur)
	if _, ok := specs[spec]; !ok {
		panic("assertpay: unknown spec")
	}
	t := market.NewTask(len(tasks), spec, who, sent(), runtime.ChainHeight(), deadlineBlocks, windowBlocks)
	tasks = append(tasks, t)
	chain.Emit("TaskFunded", "task", strconv.Itoa(t.ID), "spec", spec, "reward", strconv.FormatInt(t.Reward, 10))
	return t.ID
}

// HashFor is the commitment a solver must Commit before revealing from
// entry with salt. Compute it off chain or with a query.
func HashFor(task int, who address, entry, salt string) string {
	h := sha256.Sum256([]byte(strconv.Itoa(task) + "|" + who.String() + "|" + entry + "|" + salt))
	return hex.EncodeToString(h[:])
}

// Commit seals a future reveal. Send exactly the task's bond.
func Commit(cur realm, task int, hash string) {
	who := mustUser(cur)
	t := mustTask(task)
	if sent() != t.Bond {
		panic("assertpay: send exactly the bond (" + strconv.FormatInt(t.Bond, 10) + denom + ")")
	}
	if len(hash) != 64 {
		panic("assertpay: hash must be 64 hex chars")
	}
	t.AddCommit(who, hash, runtime.ChainHeight())
	chain.Emit("Committed", "task", strconv.Itoa(task), "who", who.String())
}

// SeedFor is the seed a reveal runs with: public and deterministic. A
// reveal passing one seed proves little; challenges decide.
func SeedFor(hash string, height int64) uint64 {
	d := sha256.Sum256([]byte(hash + "|" + strconv.FormatInt(height, 10)))
	var x uint64
	for i := 0; i < 8; i++ {
		x = x<<8 | uint64(d[i])
	}
	return x
}

// Reveal is called by the solver's entry realm with the implementation.
// It returns "passed/total".
func Reveal(cur realm, task int, salt string, impl any) string {
	guard()
	entry := cur.Previous().PkgPath()
	if entry == "" {
		panic("assertpay: Reveal must be called from your entry realm")
	}
	who := unsafe.OriginCaller()
	t := mustTask(task)
	now := runtime.ChainHeight()
	hash := HashFor(task, who, entry, salt)
	c := t.FindCommit(who, hash, now)
	res := runTests(t.Spec, impl, SeedFor(hash, now))
	a, pays := t.Reveal(c, entry, impl, res, now)
	statAttempts++
	pay(cur, pays)
	chain.Emit("Revealed", "task", strconv.Itoa(task), "attempt", strconv.Itoa(a.ID), "passed", strconv.Itoa(a.Passed), "total", strconv.Itoa(a.Total))
	return strconv.Itoa(a.Passed) + "/" + strconv.Itoa(a.Total)
}

// Challenge runs the current winner with your seed. If it fails, the
// winner is removed and its bond is paid to you.
func Challenge(cur realm, task int, seed uint64) string {
	who := mustUser(cur)
	t := mustTask(task)
	now := runtime.ChainHeight()
	w := t.CheckChallenge(now)
	res := runTests(t.Spec, w.Impl, seed)
	pays := t.Challenged(who, res, now)
	pay(cur, pays)
	out := "held"
	if !res.Pass() {
		out = "broke: " + res.Fail
		statBroken++
	}
	chain.Emit("Challenged", "task", strconv.Itoa(task), "seed", strconv.FormatUint(seed, 10), "outcome", out)
	return out
}

// OpenChallenge is the two-step challenge for a winner whose code aborts
// the transaction. Send the task's bond; then anyone calls RunChallenge,
// or after the task's window length TimeoutChallenge removes the winner.
func OpenChallenge(cur realm, task int, seed uint64) {
	who := mustUser(cur)
	t := mustTask(task)
	t.Open(who, seed, sent(), runtime.ChainHeight())
	chain.Emit("ChallengeOpened", "task", strconv.Itoa(task), "seed", strconv.FormatUint(seed, 10))
}

// RunChallenge runs the open challenge. Anyone may call it; if the winner
// holds, the caller gets half of the challenger's bond.
func RunChallenge(cur realm, task int) string {
	runner := mustUser(cur)
	t := mustTask(task)
	ch := t.OpenChallenge()
	if ch == nil {
		panic("assertpay: no open challenge")
	}
	res := runTests(t.Spec, t.Attempts[ch.Target].Impl, ch.Seed)
	pay(cur, t.RanOpen(runner, res, runtime.ChainHeight()))
	if ch.Outcome == "broke" {
		statBroken++
	}
	chain.Emit("ChallengeRun", "task", strconv.Itoa(task), "outcome", ch.Outcome)
	return ch.Outcome
}

// TimeoutChallenge removes a winner whose open challenge nobody could run.
func TimeoutChallenge(cur realm, task int) {
	mustUser(cur)
	t := mustTask(task)
	pay(cur, t.TimeoutOpen(runtime.ChainHeight()))
	statBroken++
	chain.Emit("ChallengeTimeout", "task", strconv.Itoa(task))
}

// Claim pays the winner after the window. Anyone may call it.
func Claim(cur realm, task int) string {
	mustUser(cur)
	t := mustTask(task)
	pays := t.Claim(runtime.ChainHeight())
	pay(cur, pays)
	statPaid += t.Reward
	statPaidTasks++
	chain.Emit("Paid", "task", strconv.Itoa(task), "to", pays[0].To.String(), "amount", strconv.FormatInt(pays[0].Amount, 10))
	return "paid " + pays[0].To.String()
}

// Refund returns the reward to the sponsor after the deadline when no
// implementation passed and nothing is pending. Anyone may call it.
func Refund(cur realm, task int) {
	mustUser(cur)
	t := mustTask(task)
	pay(cur, t.Refund(runtime.ChainHeight()))
	chain.Emit("Refunded", "task", strconv.Itoa(task))
}

func runTests(spec string, impl any, seed uint64) market.Result {
	e := specs[spec]
	running = true
	rs := check.RunSpec(e.Spec, impl, seed)
	running = false
	return summarize(rs, seed)
}

func summarize(rs []check.Result, seed uint64) market.Result {
	bits := make([]byte, len(rs))
	r := market.Result{Seed: seed, Total: len(rs)}
	for i, x := range rs {
		if x.Pass {
			bits[i] = 'p'
			r.Passed++
		} else {
			bits[i] = 'f'
			if r.Fail == "" {
				msg := x.Msg
				if len(msg) > 300 {
					msg = msg[:300] + "..."
				}
				r.Fail = x.Name + ": " + msg
			}
		}
	}
	r.Bits = string(bits)
	return r
}

func pay(cur realm, pays []market.Payment) {
	if len(pays) == 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	for _, p := range pays {
		if p.Amount > 0 {
			b.SendCoins(cur.Address(), p.To, chain.NewCoins(chain.NewCoin(denom, p.Amount)))
		}
	}
}

func validName(s string) bool {
	if len(s) < 2 || len(s) > 24 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// validPkgPath accepts gno.land/p/... or gno.land/r/... with a plain charset,
// so a registered path cannot inject Markdown.
func validPkgPath(p string) bool {
	if len(p) > 120 || !(strings.HasPrefix(p, "gno.land/p/") || strings.HasPrefix(p, "gno.land/r/")) {
		return false
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '/' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}
