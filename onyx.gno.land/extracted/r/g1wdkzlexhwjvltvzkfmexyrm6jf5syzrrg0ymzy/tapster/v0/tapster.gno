// Package tapster is a staked price oracle for gno.land.
//
// Reporters stake GNOT and submit prices for feeds such as GNOT-USD. Each
// feed runs in fixed time rounds. When a round closes, the realm takes the
// median of the reports as the answer, pays reporters who were within the
// feed's tolerance from the feed's reward pool, and slashes part of the
// stake of reporters who were far from the median. Slashed stake goes to
// the reward pool, so honest reporters are paid by dishonest ones.
//
// Any realm can read prices for free with Latest or PriceFresh.
package tapster

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapmath/v0"
)

// Protocol limits. These protect reporters and readers from extreme
// parameters, including from the admin.
const (
	maxHistory      = 120  // answers kept per feed for charts
	maxReportsRound = 64   // reports accepted per round
	maxSlashBps     = 2000 // admin can never slash more than 20% per round
	minRoundSecs    = 15
	maxRoundSecs    = 86400
	maxPairLen      = 16
	maxNameLen      = 32
	maxEvents       = 200
	ugnot           = "ugnot"
)

// Tunable protocol settings (admin-only, bounded).
var (
	minStake      int64 = 1000000 // 1 GNOT to become an active reporter
	unbondingSecs int64 = 3600    // stake stays slashable this long after exit
)

// admin is the realm administrator. The deploy script writes the deployer
// address here. The admin can add feeds and tune parameters within the
// hard limits above, and can never move reporters' stake.
var admin address = "g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy"

// Report is one reporter's price in a round.
type Report struct {
	Reporter address
	Price    int64
	Weight   int64 // reporter's stake when the report was made
	At       int64
	DevBps   int64 // filled at finalization: distance from the answer
	Outcome  string
}

// Round holds the reports collected during one round of a feed.
type Round struct {
	ID      int64
	Reports []Report
}

// Answer is a finalized price.
type Answer struct {
	Round   int64
	Price   int64
	At      int64 // unix seconds when the round was finalized
	Reports int
	Spread  int64 // bps between the lowest and highest report
}

// Feed is one price pair.
type Feed struct {
	Pair            string
	Description     string
	Decimals        int
	RoundSecs       int64
	MinReports      int
	ToleranceBps    int64 // within this: accurate, earns a reward
	OutlierBps      int64 // beyond this: outlier, gets slashed
	SlashBps        int64 // share of stake slashed per outlier report
	RewardPerReport int64 // ugnot paid per accurate report
	Pool            int64 // ugnot available for rewards
	Paused          bool

	current      *Round
	latest       Answer
	hasAnswer    bool
	history      []Answer
	lastReports  []Report // reports of the last finalized round
	roundsMissed int      // rounds closed without quorum
}

// Reporter is a staked price reporter.
type Reporter struct {
	Addr     address
	Name     string
	Stake    int64
	Rewards  int64 // claimable ugnot
	Accurate int
	Outliers int
	Reports  int
	Slashed  int64
	Earned   int64 // lifetime rewards
	JoinedAt int64
	ExitAt   int64 // 0 = active; otherwise unix time stake can be withdrawn
}

// Event is a human-readable log line for the activity page.
type Event struct {
	At   int64
	Kind string
	Text string
}

var (
	feeds     = avl.NewTree() // pair -> *Feed
	reporters = avl.NewTree() // address -> *Reporter
	events    []Event
	totalSlashed int64
	totalRewards int64
)

func init() {
	addFeed("GNOT-USD", "Gno.land GNOT priced in US dollars", 6, 300, 2)
	addFeed("BTC-USD", "Bitcoin priced in US dollars", 6, 300, 2)
	addFeed("ETH-USD", "Ether priced in US dollars", 6, 300, 2)
	addFeed("XAU-USD", "Gold (1 troy ounce) priced in US dollars", 6, 300, 2)
}

func addFeed(pair, desc string, decimals int, roundSecs int64, minReports int) {
	validatePair(pair)
	if feeds.Has(pair) {
		panic("feed already exists: " + pair)
	}
	if decimals < 0 || decimals > tapmath.MaxDecimals {
		panic("decimals must be between 0 and 8")
	}
	checkRoundSecs(roundSecs)
	if minReports < 1 || minReports > maxReportsRound {
		panic("minReports out of range")
	}
	feeds.Set(pair, &Feed{
		Pair:            pair,
		Description:     desc,
		Decimals:        decimals,
		RoundSecs:       roundSecs,
		MinReports:      minReports,
		ToleranceBps:    100,  // 1%
		OutlierBps:      500,  // 5%
		SlashBps:        500,  // 5% of stake
		RewardPerReport: 2000, // 0.002 GNOT
	})
}

func validatePair(pair string) {
	if len(pair) < 3 || len(pair) > maxPairLen {
		panic("pair must be 3-16 characters, like GNOT-USD")
	}
	for _, c := range pair {
		ok := (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'
		if !ok {
			panic("pair may only use A-Z, 0-9 and '-'")
		}
	}
}

func checkRoundSecs(s int64) {
	if s < minRoundSecs || s > maxRoundSecs {
		panic(ufmt.Sprintf("roundSecs must be between %d and %d", minRoundSecs, maxRoundSecs))
	}
}

func now() int64 { return time.Now().Unix() }

func mustFeed(pair string) *Feed {
	v := feeds.Get(pair)
	if v == nil {
		panic("unknown feed: " + pair)
	}
	return v.(*Feed)
}

func getReporter(addr address) *Reporter {
	v := reporters.Get(addr.String())
	if v == nil {
		return nil
	}
	return v.(*Reporter)
}

func logEvent(kind, text string) {
	events = append(events, Event{At: now(), Kind: kind, Text: text})
	if len(events) > maxEvents {
		events = events[len(events)-maxEvents:]
	}
}

func assertCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
}

// receivedUgnot returns the ugnot sent with this call. The IsUserCall
// guard and the OriginSend read are a pair: only for a direct call from
// an account are the -send coins guaranteed to have reached this realm.
func receivedUgnot(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("call this function directly from an account (gnokey maketx call or a wallet)")
	}
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != ugnot {
			panic("only ugnot is accepted")
		}
	}
	return sent.AmountOf(ugnot)
}

func send(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.Coins{{ugnot, amount}})
}

func assertAdmin(cur realm) {
	assertCurrent(cur)
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func displayName(a address) string {
	if r := getReporter(a); r != nil && r.Name != "" {
		return r.Name
	}
	return shortAddr(a)
}

func cleanName(name string) string {
	name = strings.TrimSpace(name)
	if len(name) > maxNameLen {
		panic("name too long (max 32)")
	}
	for _, c := range name {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == ' ' || c == '.'
		if !ok {
			panic("name may only use letters, digits, space, '-', '_' and '.'")
		}
	}
	return name
}
