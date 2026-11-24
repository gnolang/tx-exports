package aimledger

import (
	"strconv"
	"time"

	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	daySeconds       int64 = 86400
	cooldownSeconds  int64 = 10
	maxScore               = 10000
	dailyQuestTarget       = 1500
	dailyCreditCap   int64 = 500
	creditsPerPoint  int64 = 1
	ugnotPerCredit   int64 = 1000
	maxClaimCredits  int64 = 1000
)

type Player struct {
	Addr       address
	Credits    int64
	Best       int
	Runs       int
	Streak     int
	LastDay    int64
	LastSubmit int64
	TodayScore int
}

var (
	admin        address
	players      *avl.Tree
	totalPlayers int
	totalRuns    int64
	pool         int64
)

func init() {
	admin = unsafe.OriginCaller()
	players = avl.NewTree()
}

// requireUser validates the crossing realm token and returns the EOA caller.
func requireUser(cur realm) address {
	if !cur.IsCurrent() {
		panic("invalid realm token")
	}
	if !cur.Previous().IsUserCall() {
		panic("EOA calls only")
	}
	return cur.Previous().Address()
}

func playerFor(a address) *Player {
	key := a.String()
	if !players.Has(key) {
		return nil
	}
	p, _ := players.Get(key).(*Player)
	return p
}

func getOrCreate(a address) *Player {
	p := playerFor(a)
	if p == nil {
		p = &Player{Addr: a}
		players.Set(a.String(), p)
		totalPlayers++
	}
	return p
}

// Join registers the caller. Free, idempotent.
func Join(cur realm) {
	a := requireUser(cur)
	getOrCreate(a)
}

// SubmitScore records a run. One run per cooldown window; credits are capped daily.
func SubmitScore(cur realm, score int) {
	a := requireUser(cur)
	if score < 1 || score > maxScore {
		panic("score out of range")
	}
	p := getOrCreate(a)
	now := time.Now().Unix()
	if now-p.LastSubmit < cooldownSeconds {
		panic("too soon: wait before the next run")
	}

	day := now / daySeconds
	if day != p.LastDay {
		p.TodayScore = 0
		if day == p.LastDay+1 {
			p.Streak++
		} else if day > p.LastDay+1 {
			p.Streak = 1
		}
		p.LastDay = day
	}

	earned := int64(score) * creditsPerPoint
	if p.TodayScore+score > dailyQuestTarget {
		earned = int64(dailyQuestTarget-p.TodayScore) * creditsPerPoint
	}
	if earned < 0 {
		earned = 0
	}
	if earned > dailyCreditCap {
		earned = dailyCreditCap
	}

	p.TodayScore += score
	if score > p.Best {
		p.Best = score
	}
	p.Runs++
	p.LastSubmit = now
	p.Credits += earned
	totalRuns++

	chain.Emit("Run", "player", a.String(), "score", strconv.Itoa(score), "credits", strconv.FormatInt(earned, 10))
}

// Fund adds ugnot to the prize pool. Payable, EOA only.
func Fund(cur realm) {
	requireUser(cur)
	coins := unsafe.OriginSend()
	if len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount <= 0 {
		panic("send ugnot to fund the pool")
	}
	pool += coins[0].Amount
	chain.Emit("Fund", "amount", strconv.FormatInt(coins[0].Amount, 10))
}

// Claim redeems credits for ugnot from the pool.
func Claim(cur realm, credits int64) {
	a := requireUser(cur)
	if credits <= 0 || credits > maxClaimCredits || credits%100 != 0 {
		panic("claim must be a multiple of 100, up to 1000 credits")
	}
	p := playerFor(a)
	if p == nil || p.Credits < credits {
		panic("not enough credits")
	}
	amount := credits / 100 * ugnotPerCredit
	if amount > pool {
		panic("prize pool is empty")
	}
	p.Credits -= credits
	pool -= amount
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), a, chain.Coins{{Denom: "ugnot", Amount: amount}})
	chain.Emit("Claim", "player", a.String(), "amount", strconv.FormatInt(amount, 10))
}

// Top returns the ten highest-scoring players, ordered by best score then address.
func better(a, b *Player) bool {
	if a.Best != b.Best {
		return a.Best > b.Best
	}
	return a.Addr.String() < b.Addr.String()
}

func Top() []*Player {
	list := []*Player{}
	players.Iterate("", "", func(key string, value any) bool {
		p, ok := value.(*Player)
		if ok {
			list = append(list, p)
		}
		return false
	})
	for i := 1; i < len(list); i++ {
		j := i
		for j > 0 && better(list[j], list[j-1]) {
			list[j], list[j-1] = list[j-1], list[j]
			j--
		}
	}
	if len(list) > 10 {
		return list[:10]
	}
	return list
}

func Credits(a address) int64 {
	p := playerFor(a)
	if p == nil {
		return 0
	}
	return p.Credits
}

func Pool() int64 { return pool }
func Players() int { return totalPlayers }
func Runs() int64  { return totalRuns }

func Render(path string) string {
	out := "# Aim Ledger\n\n"
	out += "Aim. Quest. Earn. An on-chain scoreboard for a browser aim trainer — every run, streak and payout is settled in a realm.\n\n"
	out += "## How to play\n\n"
	out += "1. Open the companion aim trainer in the project repo and get a score (1-10000).\n"
	out += "2. Submit it below. Runs are rate-limited and credits are capped daily.\n"
	out += "3. Build a streak, climb the board, then redeem credits for testnet GNOT.\n\n"
	out += "100 credits = 0.001 GNOT. Maximum redemption is 1000 credits at a time. Fund the pool with a payable call to Fund.\n\n"

	out += "## Stats\n\n"
	out += "| Players | Runs | Pool (ugnot) |\n|---|---:|---:|\n"
	out += "| " + strconv.Itoa(totalPlayers) + " | " + strconv.FormatInt(totalRuns, 10) + " | " + strconv.FormatInt(pool, 10) + " |\n\n"

	out += "## Your account\n\n"
	out += "<gno-form exec=\"Join\">\n<gno-button label=\"Join for free\" />\n</gno-form>\n\n"
	out += "<gno-form exec=\"SubmitScore\">\n<gno-input name=\"score\" type=\"number\" placeholder=\"Score from the aim trainer\" required=\"true\" />\n</gno-form>\n\n"
	out += "<gno-form exec=\"Claim\">\n<gno-input name=\"credits\" type=\"number\" placeholder=\"Credits to redeem (multiple of 100)\" required=\"true\" />\n</gno-form>\n\n"

	out += "## Leaderboard\n\n"
	out += "| # | Player | Best | Streak | Credits |\n|---:|---|---:|---:|---:|\n"
	for i, p := range Top() {
		out += "| " + strconv.Itoa(i+1) + " | " + sanitize.InlineText(p.Addr.String()) + " | " + strconv.Itoa(p.Best) + " | " + strconv.Itoa(p.Streak) + " | " + strconv.FormatInt(p.Credits, 10) + " |\n"
	}
	return out
}
