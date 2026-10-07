package game25

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	admin      address
	minterAddr address
	balances   avl.Tree
	lastClaim  avl.Tree
	paused     bool
)

func init(cur realm) {
	admin = cur.Previous().Address()
}

func isAdmin(cur realm) bool {
	return cur.Previous().Address() == admin
}

func requireNotPaused() {
	if paused {
		panic("game is paused")
	}
}

func SetMinter(cur realm, newMinter string) {
	if !isAdmin(cur) {
		panic("unauthorized: only admin can set minter")
	}
	minterAddr = address(newMinter)
}

func ClaimAndMint(cur realm, coinsJson string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	now := time.Now().Unix()
	if lastClaim.Has(caller) {
		last, _ := strconv.ParseInt(lastClaim.Get(caller).(string), 10, 64)
		if now-last < 60 {
			remaining := 60 - (now - last)
			panic("too fast — " + strconv.FormatInt(remaining, 10) + "s remaining (1 min cooldown)")
		}
	}
	lastClaim.Set(caller, strconv.FormatInt(now, 10))
	coinsJson = strings.TrimSpace(coinsJson)
	balances.Set(caller, coinsJson)
}

func ClaimAchievement(cur realm, achievementId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	balances.Set(caller+":"+achievementId, "1")
}

func Render(_ string) string {
	return ufmt.Sprintf("# GnoMoji\n\nAdmin: %s\n", admin.String())
}
