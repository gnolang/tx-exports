package game30

import (
	"strings"
	"testing"
	"time"
)

// Sherlock's 4 main-tree exploit probes (SHERLOCK_REPORT §4), inverted:
// each must now be refused by the single game29 realm.

func TestSherlockH1aBankAndFreePass_Closed(cur realm, t *testing.T) {
	setup()
	bot := ta("sherlock-bot")
	testing.SetRealm(testing.NewUserRealm(bot))
	exp := time.Now().Unix() + 300
	mustAbort(t, "unsigned bank claim", revive(func() { ClaimAndMint(cross(cur), `[["grin","1000"]]`, 1, exp, "") }), "")
	mustAbort(t, "forged bank claim", revive(func() { ClaimAndMint(cross(cur), `[["grin","1000"]]`, 1, exp, strings.Repeat("ab", 64)) }), "")
	mustAbort(t, "free pass", revive(func() { ActivateGnomePass(cross(cur), 3650) }), "")
	if strings.Contains(AllBalances(bot.String()), "grin") || HasActivePass(bot.String()) {
		t.Errorf("H1a open: %s", AllBalances(bot.String()))
	}
}

func TestSherlockN1ForgedMedal_Closed(cur realm, t *testing.T) {
	setup()
	bot := ta("sherlock-n1")
	testing.SetRealm(testing.NewUserRealm(bot))
	mustAbort(t, "forged medal", revive(func() { ClaimAchievement(cross(cur), "made-up-medal", 1, time.Now().Unix()+300, "") }), "")
	if strings.Contains(GetMedals(bot.String()), "made-up-medal") {
		t.Errorf("N1 open")
	}
}

func TestSherlockH2bCommitOverwrite_Closed(cur realm, t *testing.T) {
	setup()
	bot := ta("sherlock-h2b")
	testing.SetRealm(testing.NewUserRealm(bot))
	mustAbort(t, "commit on missing lobby", revive(func() { CommitPvpMove(cross(cur), "no-such-lobby", "aaaa") }), "")
}

func TestSherlockH1fSybil_Closed(cur realm, t *testing.T) {
	setup()
	main := ta("sherlock-main")
	for _, n := range []string{"s1", "s2", "s3"} {
		a := ta("sherlock-" + n)
		testing.SetRealm(testing.NewUserRealm(a))
		mustAbort(t, "sybil claim", revive(func() { ClaimAndMint(cross(cur), `[["grin","1000"]]`, 1, time.Now().Unix()+300, "") }), "")
		mustAbort(t, "sybil transfer", revive(func() { Transfer(cross(cur), "grin", main.String(), "1000") }), "")
	}
	if strings.Contains(AllBalances(main.String()), "grin") {
		t.Errorf("H1f open: %s", AllBalances(main.String()))
	}
}
