package oracle

import (
	"time"

	"chain"

	poracle "gno.land/p/g18ugne5ng6eylkca4mqeet9luj0xaykp84sh2cf/oracle/v2"
)

const (
	maxUsdFeeds    = 8
	maxPublishers  = 8
	maxSymbolLen   = 32
	maxUsdMicro    = int64(1_000_000) * poracle.UsdScale // $1e6 cap, not a credit LTV
)

type usdPost struct {
	usdMicro   int64
	postedAt   int64
	observedAt int64
}

type usdFeed struct {
	symbol     string
	maxAgeSec  int64
	minFresh   int
	pubs       []address
	posts      []usdPost
}

var usdFeeds []usdFeed

func UsdFeedCount() int {
	return len(usdFeeds)
}

func validSymbol(sym string) bool {
	if sym == "" || len(sym) > maxSymbolLen {
		return false
	}
	hyphen := 0
	for i := 0; i < len(sym); i++ {
		c := sym[i]
		if c == '-' {
			hyphen++
			continue
		}
		ok := (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return hyphen == 1 && sym[0] != '-' && sym[len(sym)-1] != '-'
}

func findUsd(sym string) int {
	for i := 0; i < len(usdFeeds); i++ {
		if usdFeeds[i].symbol == sym {
			return i
		}
	}
	return -1
}

func findPub(f usdFeed, who address) int {
	for i := 0; i < len(f.pubs); i++ {
		if f.pubs[i] == who {
			return i
		}
	}
	return -1
}

// AddUsdFeed registers an EXTERNAL USD symbol (e.g. BTC-USD). Informational only.
func AddUsdFeed(cur realm, symbol string, maxAgeSec int64, minFresh int) {
	requireAdmin(cur)
	if !validSymbol(symbol) {
		panic("oracle: invalid symbol")
	}
	if maxAgeSec < 1 {
		panic("oracle: maxAgeSec required")
	}
	if minFresh < 1 || minFresh > maxPublishers {
		panic("oracle: minFresh out of range")
	}
	if findUsd(symbol) >= 0 {
		panic("oracle: symbol exists")
	}
	if len(usdFeeds) >= maxUsdFeeds {
		panic("oracle: usd feed cap")
	}
	usdFeeds = append(usdFeeds, usdFeed{
		symbol:    symbol,
		maxAgeSec: maxAgeSec,
		minFresh:  minFresh,
	})
	chain.Emit("UsdFeedAdd", "symbol", symbol)
}

func RemoveUsdFeed(cur realm, symbol string) {
	requireAdmin(cur)
	i := findUsd(symbol)
	if i < 0 {
		panic("oracle: unknown symbol")
	}
	usdFeeds = append(usdFeeds[:i], usdFeeds[i+1:]...)
	chain.Emit("UsdFeedRemove", "symbol", symbol)
}

func AddPublisher(cur realm, symbol string, who address) {
	requireAdmin(cur)
	if !who.IsValid() {
		panic("oracle: invalid publisher")
	}
	i := findUsd(symbol)
	if i < 0 {
		panic("oracle: unknown symbol")
	}
	if findPub(usdFeeds[i], who) >= 0 {
		panic("oracle: publisher exists")
	}
	if len(usdFeeds[i].pubs) >= maxPublishers {
		panic("oracle: publisher cap")
	}
	usdFeeds[i].pubs = append(usdFeeds[i].pubs, who)
	usdFeeds[i].posts = append(usdFeeds[i].posts, usdPost{})
	chain.Emit("UsdPublisherAdd", "symbol", symbol, "who", who.String())
}

func RemovePublisher(cur realm, symbol string, who address) {
	requireAdmin(cur)
	i := findUsd(symbol)
	if i < 0 {
		panic("oracle: unknown symbol")
	}
	j := findPub(usdFeeds[i], who)
	if j < 0 {
		panic("oracle: unknown publisher")
	}
	f := usdFeeds[i]
	f.pubs = append(f.pubs[:j], f.pubs[j+1:]...)
	f.posts = append(f.posts[:j], f.posts[j+1:]...)
	usdFeeds[i] = f
	chain.Emit("UsdPublisherRemove", "symbol", symbol, "who", who.String())
}

// PostUsd is called by an allowlisted publisher EOA. Auth = MsgCall address.
// sig bytes are not accepted: Gno cannot ecrecover; do not pretend.
func PostUsd(cur realm, symbol string, usdMicro, observedAt int64) {
	if !cur.IsCurrent() {
		panic("oracle: invalid realm")
	}
	caller := cur.Previous().Address()
	i := findUsd(symbol)
	if i < 0 {
		panic("oracle: unknown symbol")
	}
	j := findPub(usdFeeds[i], caller)
	if j < 0 {
		panic("oracle: not a publisher")
	}
	if usdMicro < 1 || usdMicro > maxUsdMicro {
		panic("oracle: usdMicro out of range")
	}
	now := time.Now().Unix()
	if observedAt < 0 || observedAt > now {
		panic("oracle: observedAt invalid")
	}
	usdFeeds[i].posts[j] = usdPost{
		usdMicro:   usdMicro,
		postedAt:   now,
		observedAt: observedAt,
	}
	chain.Emit("UsdPost", "symbol", symbol, "who", caller.String())
}

// ConsultUsd returns median of fresh publisher posts, or GradeNone.
// Always Informational when OK — never GradeOracle.
func ConsultUsd(symbol string) poracle.UsdQuote {
	if !validSymbol(symbol) {
		return poracle.UsdNone(symbol, "invalid symbol")
	}
	i := findUsd(symbol)
	if i < 0 {
		return poracle.UsdNone(symbol, "unknown symbol")
	}
	f := usdFeeds[i]
	now := time.Now().Unix()
	fresh := make([]int64, 0, len(f.posts))
	var newestObs int64
	for k := 0; k < len(f.posts); k++ {
		p := f.posts[k]
		if p.usdMicro < 1 || p.postedAt < 1 {
			continue
		}
		if now-p.postedAt > f.maxAgeSec || now-p.observedAt > f.maxAgeSec {
			continue
		}
		fresh = append(fresh, p.usdMicro)
		if p.observedAt > newestObs {
			newestObs = p.observedAt
		}
	}
	if len(fresh) < f.minFresh {
		return poracle.UsdNone(symbol, "quorum")
	}
	med := poracle.MedianInt64(fresh)
	return poracle.UsdInformational(symbol, med, newestObs, len(fresh))
}
