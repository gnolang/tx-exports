// Package pay is the kill-test version of pay-on-pass: a task pays the
// first implementation that passes its spec's tests on chain.
package pay

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/ppkt/harness"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/ppkt/sortspec"
)

const (
	Bond       = 1_000_000 // ugnot locked per commit, refunded on reveal
	Expiry     = 300       // blocks a commit stays valid
	Window     = 40        // blocks a provisional winner can be displaced or rechecked
	MinReward  = 1_000_000
)

type commitT struct {
	Hash   string
	Who    address
	Height int64
	Used   bool
}

type attempt struct {
	Who        address
	Entry      string
	CommitH    int64
	Height     int64
	Passed     int
	Total      int
	FirstFail  string
	Kind       string // reveal or recheck
}

type task struct {
	Reward     int64
	Sponsor    address
	Commits    []*commitT
	Attempts   []*attempt
	Winner     *attempt
	winnerImpl any
	WindowEnd  int64
	Paid       bool
}

var tasks []*task

func coinsSent() int64 {
	s := unsafe.OriginSend()
	return s.AmountOf("ugnot")
}

// Post opens a task funded by the ugnot sent with the call.
func Post(cur realm) int {
	amt := coinsSent()
	if amt < MinReward {
		panic("send a reward")
	}
	tasks = append(tasks, &task{Reward: amt, Sponsor: cur.Previous().Address()})
	return len(tasks) - 1
}

// Commit locks a hash of (address|entry realm path|salt) with a bond.
func Commit(cur realm, id int, hash string) {
	t := tasks[id]
	if coinsSent() < Bond {
		panic("send the bond")
	}
	t.Commits = append(t.Commits, &commitT{Hash: hash, Who: cur.Previous().Address(), Height: runtime.ChainHeight()})
}

// HashOf is the commitment a submitter must commit to.
func HashOf(who address, entry, salt string) string {
	h := sha256.Sum256([]byte(who.String() + "|" + entry + "|" + salt))
	return hex.EncodeToString(h[:])
}

// Reveal is called by the submitter's entry realm with the implementation.
func Reveal(cur realm, id int, salt string, impl any) string {
	entry := cur.Previous().PkgPath()
	if entry == "" {
		panic("call Reveal from your entry realm")
	}
	who := unsafe.OriginCaller()
	t := tasks[id]
	if t.Paid {
		panic("task closed")
	}
	h := HashOf(who, entry, salt)
	now := runtime.ChainHeight()
	var c *commitT
	for _, x := range t.Commits {
		if x.Hash == h && !x.Used {
			c = x
			break
		}
	}
	if c == nil {
		panic("no matching commit")
	}
	if now-c.Height > Expiry {
		panic("commit expired")
	}
	c.Used = true
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), who, chain.NewCoins(chain.NewCoin("ugnot", Bond)))
	seed := seedFor(h, now)
	rs := harness.Run(sortspec.Tests(impl), seed)
	a := &attempt{Who: who, Entry: entry, CommitH: c.Height, Height: now, Passed: harness.Passed(rs), Total: len(rs), Kind: "reveal"}
	for _, r := range rs {
		if !r.Pass {
			a.FirstFail = r.Name + ": " + r.Msg
			break
		}
	}
	t.Attempts = append(t.Attempts, a)
	if a.Passed == a.Total {
		if t.Winner == nil || a.CommitH < t.Winner.CommitH {
			t.Winner = a
			t.winnerImpl = impl
			t.WindowEnd = now + Window
		}
	}
	return strconv.Itoa(a.Passed) + "/" + strconv.Itoa(a.Total)
}

// Recheck reruns the provisional winner with a fresh seed during the window.
func Recheck(cur realm, id int) string {
	t := tasks[id]
	if t.Winner == nil || t.Paid || runtime.ChainHeight() > t.WindowEnd {
		panic("nothing to recheck")
	}
	now := runtime.ChainHeight()
	rs := harness.Run(sortspec.Tests(t.winnerImpl), seedFor("recheck", now))
	a := &attempt{Who: t.Winner.Who, Entry: t.Winner.Entry, CommitH: t.Winner.CommitH, Height: now, Passed: harness.Passed(rs), Total: len(rs), Kind: "recheck"}
	t.Attempts = append(t.Attempts, a)
	if a.Passed != a.Total {
		t.Winner = nil
		t.winnerImpl = nil
		return "winner failed recheck"
	}
	return "winner holds"
}

// Claim pays the winner once the window has passed.
func Claim(cur realm, id int) string {
	t := tasks[id]
	if t.Winner == nil || t.Paid || runtime.ChainHeight() <= t.WindowEnd {
		panic("not claimable")
	}
	t.Paid = true
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), t.Winner.Who, chain.NewCoins(chain.NewCoin("ugnot", t.Reward)))
	return "paid " + t.Winner.Who.String()
}

func seedFor(s string, h int64) uint64 {
	d := sha256.Sum256([]byte(s + "|" + strconv.FormatInt(h, 10)))
	var x uint64
	for i := 0; i < 8; i++ {
		x = x<<8 | uint64(d[i])
	}
	return x
}

func Render(path string) string {
	out := "# pay-on-pass kill test\n\n"
	for i, t := range tasks {
		out += "## Task " + strconv.Itoa(i) + " reward " + strconv.FormatInt(t.Reward, 10) + "ugnot paid=" + strconv.FormatBool(t.Paid) + "\n\n"
		for _, a := range t.Attempts {
			out += "- " + a.Kind + " " + a.Entry + " by " + a.Who.String() + " commit@" + strconv.FormatInt(a.CommitH, 10) + " at " + strconv.FormatInt(a.Height, 10) + ": " + strconv.Itoa(a.Passed) + "/" + strconv.Itoa(a.Total) + " " + a.FirstFail + "\n"
		}
		if t.Winner != nil {
			out += "\nWinner: " + t.Winner.Entry + " (commit@" + strconv.FormatInt(t.Winner.CommitH, 10) + "), window ends " + strconv.FormatInt(t.WindowEnd, 10) + "\n"
		}
	}
	return out
}
