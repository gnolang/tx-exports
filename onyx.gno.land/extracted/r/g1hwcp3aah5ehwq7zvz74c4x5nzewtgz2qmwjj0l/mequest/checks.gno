package mequest

// Self-verifying checks. Every rule here is public code: the board runs it
// on the caller's wallet and only pays when it returns no reason.

import (
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/r/sys/users"
)

const (
	KindCheckin  = "checkin"  // check-in streak of at least Arg days (1 = first check-in)
	KindEarly    = "early"    // among the first Arg wallets to join MeQuest
	KindInvites  = "invites"  // at least Arg invited friends earned a card
	KindProjects = "projects" // cards from at least Arg different projects
	KindCards    = "cards"    // own at least Arg cards
	KindPosted   = "posted"   // funded at least Arg quests as a project
	KindMyRealm  = "myrealm"  // your own realm (gno.land/r/<your addr>/...) calls ProveRealm
	KindGrant    = "grant"    // given by the quest funder (e.g. season top 3)
)

var (
	joinRank    = map[address]int{}
	joined      int
	streak      = map[address]int{}
	lastDay     = map[address]int64{}
	inviter     = map[address]address{}
	invitesDone = map[address]int{}
	posted      = map[address]int{}
)

func validKind(kind, arg string) string {
	switch kind {
	case KindManual, KindPush, KindMyRealm, KindGrant, KindName:
		return ""
	case KindHold:
		if n, err := strconv.ParseInt(arg, 10, 64); err != nil || n < 1 {
			return "hold quests need a ugnot amount as arg"
		}
		return ""
	case KindCard:
		for _, part := range strings.Split(arg, ",") {
			if n, err := strconv.Atoi(strings.TrimSpace(part)); err != nil || n < 1 || n > len(quests) {
				return "card quests need existing quest ids as arg, like 1,2,3"
			}
		}
		return ""
	case KindCheckin, KindEarly, KindInvites, KindProjects, KindCards, KindPosted:
		if n, err := strconv.Atoi(arg); err != nil || n < 1 {
			return "this kind needs a number as arg"
		}
		return ""
	}
	return "bad kind"
}

// verifyReason runs the quest's own check. "" means the wallet passes.
func verifyReason(q *Quest, user address) string {
	n, _ := strconv.Atoi(q.Arg)
	switch q.Kind {
	case KindHold:
		min, _ := strconv.ParseInt(q.Arg, 10, 64)
		if banker.NewReadonlyBanker().GetCoin(user, "ugnot") < min {
			return "check failed: hold at least " + gnot(min)
		}
	case KindName:
		if users.ResolveAddress(user) == nil {
			return "check failed: register a gno.land username first"
		}
	case KindCard:
		for _, part := range strings.Split(q.Arg, ",") {
			id, _ := strconv.Atoi(strings.TrimSpace(part))
			if !HasCard(user, id) {
				return "check failed: you need the card from quest #" + strconv.Itoa(id) + " first"
			}
		}
	case KindCheckin:
		if s := StreakOf(user); s < n {
			return "check failed: check-in streak is " + strconv.Itoa(s) + ", needs " + q.Arg
		}
	case KindEarly:
		r := joinRank[user]
		if r == 0 {
			return "check failed: you haven't joined yet, check in first"
		}
		if r > n {
			return "check failed: you joined as wallet #" + strconv.Itoa(r) + ", only the first " + q.Arg + " get this"
		}
	case KindInvites:
		if invitesDone[user] < n {
			return "check failed: " + strconv.Itoa(invitesDone[user]) + " invited friends earned a card, needs " + q.Arg
		}
	case KindProjects:
		if p := ProjectsDone(user); p < n {
			return "check failed: cards from " + strconv.Itoa(p) + " projects, needs " + q.Arg
		}
	case KindCards:
		if len(cards[user]) < n {
			return "check failed: you own " + strconv.Itoa(len(cards[user])) + " cards, needs " + q.Arg
		}
	case KindPosted:
		if posted[user] < n {
			return "check failed: post a funded quest first"
		}
	case KindManual:
		return "this quest needs a proof: use Submit"
	case KindPush:
		return "finish this quest on the partner app: " + q.Arg
	case KindMyRealm:
		return "deploy your own realm and have it call ProveRealm"
	case KindGrant:
		return "this card is given by the project"
	}
	return ""
}

// gateReason checks board rules shared by every payout.
func gateReason(q *Quest, user address) string {
	if time.Now().Unix() >= q.Expires {
		return "quest expired"
	}
	if q.won[user] {
		return "already claimed: one win per wallet"
	}
	if q.Rarity == Legendary && BestRarity(user) < Epic {
		return "Legendary needs an Epic card first"
	}
	if len(q.Winners) >= q.Max {
		return "all winner slots are taken"
	}
	day := strconv.FormatInt(time.Now().Unix()/daySecs, 10)
	if daily[string(user)+":"+day] >= DailyCap {
		return "daily cap reached: 10 claims per day"
	}
	return ""
}

// CanClaim is a free read-only dry run of Claim: "ok" or the reason it would fail.
func CanClaim(wallet address, id int) string {
	if id < 1 || id > len(quests) {
		return "quest not found"
	}
	q := quests[id-1]
	if r := gateReason(q, wallet); r != "" {
		return r
	}
	if r := verifyReason(q, wallet); r != "" {
		return r
	}
	return "ok"
}

// CheckIn records today's check-in and grows your streak.
func CheckIn(cur realm) int {
	requireWallet(cur)
	user := cur.Previous().Address()
	today := time.Now().Unix() / daySecs
	last, seen := lastDay[user]
	if seen && last == today {
		panic("already checked in today")
	}
	if seen && last == today-1 {
		streak[user]++
	} else {
		streak[user] = 1
	}
	lastDay[user] = today
	touch(user)
	return streak[user]
}

// StreakOf returns the live streak (0 if a day was missed).
func StreakOf(wallet address) int {
	last, seen := lastDay[wallet]
	if !seen || time.Now().Unix()/daySecs-last > 1 {
		return 0
	}
	return streak[wallet]
}

// SetInviter links you to the friend who invited you. Once, before your first card.
func SetInviter(cur realm, friend address) {
	requireWallet(cur)
	user := cur.Previous().Address()
	if friend == user || !friend.IsValid() {
		panic("invalid inviter")
	}
	if _, ok := inviter[user]; ok {
		panic("inviter already set")
	}
	if len(cards[user]) > 0 {
		panic("set your inviter before your first card")
	}
	inviter[user] = friend
	touch(user)
}

// ProveRealm must be called by a realm deployed under the caller's own
// address: gno.land/r/<your g1 address>/anything. That path proves you built it.
func ProveRealm(cur realm, id int) {
	q := mustQuest(id)
	if q.Kind != KindMyRealm {
		panic("not a first-realm quest")
	}
	user := unsafe.OriginCaller()
	prev := cur.Previous()
	if !prev.IsCode() || !strings.HasPrefix(prev.PkgPath(), "gno.land/r/"+string(user)+"/") {
		panic("call this from a realm under gno.land/r/" + string(user) + "/")
	}
	award(cur, q, user)
}

// Grant gives a grant-kind card. Quest funder only (e.g. Season Champion).
func Grant(cur realm, id int, wallet address) {
	q := mustQuest(id)
	if q.Kind != KindGrant {
		panic("not a grant quest")
	}
	if c := cur.Previous().Address(); c != q.Funder && c != admin {
		panic("only the quest funder can grant")
	}
	award(cur, q, wallet)
}

func ProjectsDone(wallet address) int {
	seen := map[address]bool{}
	for _, c := range cards[wallet] {
		seen[quests[c.QuestID-1].Funder] = true
	}
	return len(seen)
}

func JoinRank(wallet address) int  { return joinRank[wallet] }
func InvitesDone(wallet address) int { return invitesDone[wallet] }
func InviterOf(wallet address) address { return inviter[wallet] }

func touch(a address) {
	if joinRank[a] == 0 {
		joined++
		joinRank[a] = joined
	}
}

// checkLabel is the short proof line shown on a receipt.
func checkLabel(q *Quest) string {
	switch q.Kind {
	case KindHold:
		if mustInt64(q.Arg) < 1000 {
			return "holds GNOT → true"
		}
		return "balance >= " + gnot(mustInt64(q.Arg)) + " → true"
	case KindName:
		return "users.ResolveAddress → found"
	case KindCard:
		return "owns cards " + q.Arg + " → true"
	case KindCheckin:
		return "streak >= " + q.Arg + " → true"
	case KindEarly:
		return "join rank <= " + q.Arg + " → true"
	case KindInvites:
		return "invited friends >= " + q.Arg + " → true"
	case KindProjects:
		return "projects done >= " + q.Arg + " → true"
	case KindCards:
		return "cards owned >= " + q.Arg + " → true"
	case KindPosted:
		return "quests posted >= " + q.Arg + " → true"
	case KindManual:
		return "project review → approved"
	case KindPush:
		parts := strings.Split(q.Arg, "/")
		return "reported by the " + parts[len(parts)-1] + " realm"
	case KindMyRealm:
		return "caller realm path → yours"
	case KindGrant:
		return "granted by project"
	}
	return "verified"
}

func mustInt64(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}
