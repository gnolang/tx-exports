package pointsv2

import "testing"

func TestReferralCheckInAndTrade(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))

	padPath := "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/gnomi/pad"
	AllowPad(cross(cur), padPath)
	if !IsPadAllowed(padPath) {
		t.Fatal("pad should be allowed")
	}

	ref := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	user := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")

	testing.SetRealm(testing.NewUserRealm(user))
	SetReferrer(cross(cur), ref)
	if GetPoints(ref.String()) != PointsReferrerBonus {
		t.Fatalf("ref pts %d", GetPoints(ref.String()))
	}
	CheckIn(cross(cur))
	want := PointsRefereeBonus + PointsCheckIn
	if GetPoints(user.String()) != want {
		t.Fatalf("after checkin %d want %d", GetPoints(user.String()), want)
	}

	// Simulate pad realm calling OnTrade
	testing.SetRealm(testing.NewCodeRealm(padPath))
	got := OnTrade(cross(cur), user, "1", 0, 2_000_000) // 2 GNOT buy
	// base 2 + 2*10 = 22
	if got != PointsBuyBase+2*PointsPerGnotBuy {
		t.Fatalf("buy pts %d", got)
	}
	if GetPoints(user.String()) != want+got {
		t.Fatalf("user after trade %d", GetPoints(user.String()))
	}

	gotC := OnCreate(cross(cur), user, "1")
	if gotC != PointsCreateBonus {
		t.Fatalf("create pts %d", gotC)
	}

	// Disallowed pad path must fail allowlist
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/other/pad"))
	if IsPadAllowed("gno.land/r/other/pad") {
		t.Fatal("other pad should not be allowed")
	}

	p := ParamsInfo()
	okV2 := false
	for i := 0; i+2 <= len(p); i++ {
		if p[i:i+2] == "v2" {
			okV2 = true
			break
		}
	}
	if !okV2 {
		t.Fatalf("params missing v2: %s", p)
	}
	if Leaderboard(5) == "" {
		t.Fatal("leaderboard empty")
	}
	if PadCount() != 1 {
		t.Fatalf("pad count %d", PadCount())
	}
}
