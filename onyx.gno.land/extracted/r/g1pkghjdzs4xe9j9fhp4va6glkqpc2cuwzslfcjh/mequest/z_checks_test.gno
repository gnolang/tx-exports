package mequest

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func fund(who address, ugnot int64) {
	testing.SetOriginCaller(who)
	testing.SetOriginSend(chain.Coins{{"ugnot", ugnot}})
	testing.IssueCoins(self, chain.Coins{{"ugnot", ugnot}})
}

func TestCounterChecks(cur realm, t *testing.T) {
	cara := testutils.TestAddress("cara")
	dan := testutils.TestAddress("dan")
	p2 := testutils.TestAddress("project2")

	// quests: 1 check-in, 2 streak 2, 3 early 1, 4 invites 1, 5 projects 2, 6 cards 2, 7 posted, 8 myrealm, 9 grant, 10 path (1,2)
	testing.SetRealm(testing.NewUserRealm(admin))
	fund(admin, 10_000_000)
	base := len(quests)
	id := func(n int) int { return base + n }
	CreateQuest(cross(cur), "First Check-in", "", "checkin", Common, KindCheckin, "1", PayFixed, 10, 30)
	testing.SetOriginSend(nil)
	for _, k := range []struct{ title, art, kind, arg string; r int }{
		{"Week Warrior", "week", KindCheckin, "2", Rare},
		{"Early Bird", "bird", KindEarly, "1", Common},
		{"Recruiter", "recruit", KindInvites, "1", Common},
		{"Explorer", "explorer", KindProjects, "2", Rare},
		{"Founding", "founder", KindCards, "2", Rare},
		{"Quest Maker", "maker", KindPosted, "1", Rare},
		{"First Realm", "realm", KindMyRealm, "", Rare},
		{"Season Champion", "champ", KindGrant, "", Epic},
	} {
		testing.SetRealm(testing.NewUserRealm(admin))
		fund(admin, 1_000_000)
		CreateQuest(cross(cur), k.title, "", k.art, k.r, k.kind, k.arg, PayFixed, 1, 30)
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	fund(admin, 1_000_000)
	CreateQuest(cross(cur), "Starter path", "", "builder", Epic, KindCard, itoa(id(1))+","+itoa(id(2)), PayFixed, 1, 30)
	testing.SetOriginSend(nil)

	// cara: invited by dan, checks in day 1
	testing.SetRealm(testing.NewUserRealm(cara))
	testing.SetOriginCaller(cara)
	urequire.NotPanics(t, cur, func() { SetInviter(cross(cur), dan) })
	uassert.Equal(t, "check failed: check-in streak is 0, needs 1", CanClaim(cara, id(1)))
	CheckIn(cross(cur))
	uassert.AbortsContains(t, cur, "already checked in", func() { CheckIn(cross(cur)) })
	uassert.Equal(t, "ok", CanClaim(cara, id(1)))
	Claim(cross(cur), id(1))
	uassert.True(t, HasCard(cara, id(1)))
	// streak of 2 needs tomorrow
	uassert.AbortsContains(t, cur, "streak is 1", func() { Claim(cross(cur), id(2)) })
	testing.SkipHeights(17_280) // ~1 day
	CheckIn(cross(cur))
	uassert.Equal(t, 2, StreakOf(cara))
	Claim(cross(cur), id(2))
	// early bird: admin joined first (rank 1), cara is not in the first 1
	uassert.AbortsContains(t, cur, "only the first 1", func() { Claim(cross(cur), id(3)) })
	// cards: cara has 2 now (only from admin = 1 project)
	urequire.NotPanics(t, cur, func() { Claim(cross(cur), id(6)) })
	uassert.AbortsContains(t, cur, "1 projects", func() { Claim(cross(cur), id(5)) })
	// starter path: owns quests 1 and 2
	urequire.NotPanics(t, cur, func() { Claim(cross(cur), id(10)) })
	// dan's invite counts once cara got her first card
	uassert.Equal(t, 1, InvitesDone(dan))
	uassert.AbortsContains(t, cur, "inviter already set", func() { SetInviter(cross(cur), dan) })

	testing.SetRealm(testing.NewUserRealm(dan))
	testing.SetOriginCaller(dan)
	urequire.NotPanics(t, cur, func() { Claim(cross(cur), id(4)) })
	uassert.AbortsContains(t, cur, "post a funded quest", func() { Claim(cross(cur), id(7)) })

	// project2 posts a quest -> quest maker
	testing.SetRealm(testing.NewUserRealm(p2))
	fund(p2, 1_000_000)
	CreateQuest(cross(cur), "P2 hold", "", "wallet", Common, KindHold, "1", PayFixed, 1, 30)
	testing.SetOriginSend(nil)
	urequire.NotPanics(t, cur, func() { Claim(cross(cur), id(7)) })

	// first realm: only a realm under the wallet's own address works
	testing.SetOriginCaller(dan)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/" + string(cara) + "/hello"))
	uassert.AbortsContains(t, cur, "call this from a realm under", func() { ProveRealm(cross(cur), id(8)) })
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/" + string(dan) + "/hello"))
	urequire.NotPanics(t, cur, func() { ProveRealm(cross(cur), id(8)) })
	uassert.True(t, HasCard(dan, id(8)))

	// grant: only the funder
	testing.SetRealm(testing.NewUserRealm(dan))
	uassert.AbortsContains(t, cur, "only the quest funder", func() { Grant(cross(cur), id(9), dan) })
	testing.SetRealm(testing.NewUserRealm(admin))
	urequire.NotPanics(t, cur, func() { Grant(cross(cur), id(9), cara) })
	uassert.Equal(t, Epic, BestRarity(cara))
	println("JSON " + Render("api/p/"+string(cara)))
}
