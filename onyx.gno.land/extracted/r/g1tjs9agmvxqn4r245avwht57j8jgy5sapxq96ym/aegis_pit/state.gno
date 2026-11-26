// Package aegis_pit is the main Aegis Pit realm:
// an oracle-free prediction market on deterministic AI duels,
// with policy-locked budget boxes for AI agents and an always-on exit.
package aegis_pit

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	Denom              = "ugnot"
	MinBond      int64 = 1_000
	MinBet       int64 = 1
	CommitWindow int64 = 30 // blocks after both fighters are in
	RevealWindow int64 = 30 // blocks after the commit deadline
	MaxLab             = 50
)

var (
	selfPath   string          // e.g. gno.land/r/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_pit
	fighters   = avl.NewTree() // id -> *Fighter
	matches    = avl.NewTree() // id -> *Match
	boxes      = avl.NewTree() // id -> *Box
	credits    = avl.NewTree() // addr -> int64 claimable ugnot
	trust      = avl.NewTree() // owner addr -> *core.TrustRecord
	seasonFund int64
	nFighters  int
	nMatches   int
	nBoxes     int
	lab        []LabEvent
)

// LabEvent is a line in the Breaker Lab (blocked attacks, slashes, preflight reports).
type LabEvent struct {
	Height int64
	Kind   string
	Detail string
}

func init(cur realm) {
	selfPath = cur.PkgPath()
}

// ---------- helpers ----------

func height() int64 { return runtime.ChainHeight() }

func key(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 8 {
		s = "0" + s
	}
	return s
}

// takeDeposit returns the ugnot attached to a direct user call.
// Indirect calls are refused so OriginSend can't describe a phantom payment.
func takeDeposit(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("aegis: deposits must come from a direct user call (gnokey maketx call / gnoweb)")
	}
	return unsafe.OriginSend().AmountOf(Denom)
}

func caller(cur realm) address { return cur.Previous().Address() }

func send(cur realm, to address, amt int64) {
	if amt <= 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{{Denom, amt}})
}

func addCredit(a address, amt int64) {
	if amt <= 0 {
		return
	}
	credits.Set(string(a), CreditOf(a)+amt)
}

func logLab(kind, detail string) {
	lab = append(lab, LabEvent{Height: height(), Kind: kind, Detail: detail})
	if len(lab) > MaxLab {
		lab = lab[len(lab)-MaxLab:]
	}
}

func linkPath() string {
	return strings.TrimPrefix(selfPath, "gno.land")
}

// txLink builds a gnoweb "$help" link that pre-fills a call form.
func txLink(fn string, kv ...string) string {
	s := linkPath() + "$help&func=" + fn
	for i := 0; i+1 < len(kv); i += 2 {
		s += "&" + kv[i] + "=" + kv[i+1]
	}
	return s
}

// ---------- credits (pull payments) ----------

// CreditOf returns claimable ugnot for an address (winnings, refunds, bonds, dividends).
func CreditOf(a address) int64 {
	v := credits.Get(string(a))
	if v == nil {
		return 0
	}
	return v.(int64)
}

// Claim withdraws all claimable ugnot to the caller.
func Claim(cur realm) int64 {
	who := caller(cur)
	amt := CreditOf(who)
	if amt <= 0 {
		panic("aegis: nothing to claim")
	}
	credits.Remove(string(who))
	send(cur, who, amt)
	return amt
}

// SeasonFund returns the season prize pool (2% of every ranked pool).
func SeasonFund() int64 { return seasonFund }
