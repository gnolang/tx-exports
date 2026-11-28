package verdict4

import (
	"chain"
	"strings"
	"testing"
)

func TestEmptyViewsAreWellFormed(t *testing.T) {
	resetCreationState()
	if got := GetMarketsJSON(); got != `{"markets":[]}` {
		t.Fatalf("empty markets %q", got)
	}
	if got := GetMarketJSON(1); got != "null" {
		t.Fatalf("missing market %q", got)
	}
	if got := GetActivityJSON(1, 10); got != `{"activity":[]}` {
		t.Fatalf("empty activity %q", got)
	}
	if got := GetAgentActivityJSON(testAddressString, 10); got != `{"activity":[]}` {
		t.Fatalf("empty agent activity %q", got)
	}
	if got := GetPositionJSON(1, testAddressString); got != "null" {
		t.Fatalf("missing position %q", got)
	}
	if got := GetPositionJSON(1, "not-an-address"); got != "null" {
		t.Fatalf("invalid account position %q", got)
	}
	if got := GetLeaderboardJSON(10); got != `{"entries":[]}` {
		t.Fatalf("empty leaderboard %q", got)
	}
	if got := GetProtocolStatsJSON(); got != `{"totalVolumeUgnot":"0","openMarkets":0,"resolvedMarkets":0,"totalBets":0}` {
		t.Fatalf("empty stats %q", got)
	}
}

func TestViewsEscapeQuestionsAndReportMarketState(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))

	question := "Does \"quoted\" and \\ backslash work?"
	id := CreateMarket(cross(cur), question, testHeight+2, "balance", testAddressString, 1)
	attachBetStake(20)
	Bet(cross(cur), id, true)

	markets := GetMarketsJSON()
	if !strings.Contains(markets, `\"quoted\"`) || !strings.Contains(markets, `\\ backslash`) {
		t.Fatalf("question was not escaped: %q", markets)
	}
	if !strings.Contains(markets, `"status":"open"`) || !strings.Contains(markets, `"outcome":"unresolved"`) {
		t.Fatalf("open market state missing: %q", markets)
	}
	if !strings.Contains(markets, `"yesPoolUgnot":"20"`) || !strings.Contains(markets, `"activityCount":1`) {
		t.Fatalf("pool or activity count missing: %q", markets)
	}
	single := GetMarketJSON(id)
	if single != strings.TrimSuffix(strings.TrimPrefix(markets, `{"markets":[`), `]}`) {
		t.Fatalf("single market differs: %q", single)
	}

	position := GetPositionJSON(id, testAddressString)
	if !strings.Contains(position, `"yesStakeUgnot":"20"`) || !strings.Contains(position, `"claimed":false`) {
		t.Fatalf("position view %q", position)
	}
	if !strings.Contains(position, `"marketId":"1","account":"`+testAddressString+`"`) {
		t.Fatalf("position view has invalid JSON quoting: %q", position)
	}
	activity := GetActivityJSON(id, 10)
	if !strings.Contains(activity, `"side":"yes"`) || !strings.Contains(activity, `"stakeUgnot":"20"`) {
		t.Fatalf("activity view %q", activity)
	}
	if !strings.Contains(activity, `"marketId":"1","bettor":"`+testAddressString+`"`) {
		t.Fatalf("activity view has invalid JSON quoting: %q", activity)
	}
	agent := GetAgentActivityJSON(testAddressString, 10)
	if agent != activity {
		t.Fatalf("agent activity %q, want %q", agent, activity)
	}
	stats := GetProtocolStatsJSON()
	if !strings.Contains(stats, `"totalVolumeUgnot":"20"`) || !strings.Contains(stats, `"totalBets":1`) {
		t.Fatalf("stats view %q", stats)
	}
}

func TestViewsOrderActivityAndLeaderboard(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+10, "balance", testAddressString, 1)
	testing.SetHeight(testHeight + 1)
	attachBetStake(5)
	Bet(cross(cur), id, true)
	testing.SetHeight(testHeight + 2)
	testing.SetRealm(testing.NewUserRealm(address(otherAddressString)))
	attachBetStake(9)
	Bet(cross(cur), id, false)
	testing.SetRealm(testRealm)

	activity := GetActivityJSON(id, 10)
	first := strings.Index(activity, `"id":"2"`)
	second := strings.Index(activity, `"id":"1"`)
	if first < 0 || second < 0 || first > second {
		t.Fatalf("activity is not newest first: %q", activity)
	}
	limited := GetActivityJSON(id, 1)
	if strings.Contains(limited, `"id":"1"`) || !strings.Contains(limited, `"id":"2"`) {
		t.Fatalf("activity limit ignored: %q", limited)
	}

	testing.SetHeight(testHeight + 10)
	Settle(cross(cur), id)
	fundClaimRealm(14)
	claimFor(cross(cur), id, testAddress)

	position := GetPositionJSON(id, testAddressString)
	if !strings.Contains(position, `"claimed":true`) {
		t.Fatalf("claimed position %q", position)
	}
	leaderboard := GetLeaderboardJSON(10)
	if !strings.Contains(leaderboard, `"rank":1`) || !strings.Contains(leaderboard, `"netUgnot":"9"`) {
		t.Fatalf("leaderboard %q", leaderboard)
	}
	stats := GetProtocolStatsJSON()
	if !strings.Contains(stats, `"resolvedMarkets":1`) {
		t.Fatalf("stats %q", stats)
	}
}

func TestRenderRoutes(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+2, "balance", testAddressString, 1)
	attachBetStake(20)
	Bet(cross(cur), id, true)

	dashboard := Render("")
	if !strings.HasPrefix(dashboard, "# Verdict") || !strings.Contains(dashboard, testQuestion) || !strings.Contains(dashboard, "0.000020 GNOT") {
		t.Fatalf("dashboard %q", dashboard)
	}
	if Render("/") != dashboard {
		t.Fatal("root and empty render paths differ")
	}
	if strings.Contains(dashboard, "/r/r/") || !strings.Contains(dashboard, ":leaderboard)") {
		t.Fatalf("native links are malformed: %q", dashboard)
	}
	detail := Render("/market/1")
	if !strings.Contains(detail, "## Settlement") || !strings.Contains(detail, "At settlement on or after block") || !strings.Contains(detail, "0.000020 GNOT") {
		t.Fatalf("detail %q", detail)
	}
	if strings.Contains(detail, "{") || strings.Contains(detail, "avl.") {
		t.Fatalf("detail leaked internal data: %q", detail)
	}
	if !strings.Contains(Render("/leaderboard"), "# Leaderboard") {
		t.Fatal("leaderboard route missing")
	}
	if !strings.Contains(Render("/market/99"), "not found") || !strings.Contains(Render("/other"), "not found") {
		t.Fatal("unknown routes should show navigation")
	}
}
