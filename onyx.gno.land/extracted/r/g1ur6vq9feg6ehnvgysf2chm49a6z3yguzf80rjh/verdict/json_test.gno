package verdict

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestJSONStr(t *testing.T) {
	uassert.Equal(t, `"plain"`, jsonStr("plain"))
	uassert.Equal(t, `"a\"b\\c\nd"`, jsonStr("a\"b\\c\nd"))
	uassert.Equal(t, `"é"`, jsonStr("é"))
	uassert.Equal(t, `"🚀"`, jsonStr("🚀"))
}

func TestMarketsJSON(cur realm, t *testing.T) {
	pay(0)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateMarket(cross(cur), `Will "quotes" survive?`, 3)

	out := MarketsJSON(0, 1)
	uassert.True(t, strings.HasPrefix(out, `[{"id":`+itoa(id)+`,"kind":"community"`), out)
	uassert.True(t, strings.Contains(out, `"question":"Will \"quotes\" survive?"`), out)
	uassert.True(t, strings.Contains(out, `"outcome":"pending"`), out)
	uassert.Equal(t, "null", MarketJSON(999999))
	uassert.True(t, strings.HasPrefix(UserJSON(alice), `{"address":"`), UserJSON(alice))
	uassert.True(t, strings.HasPrefix(LeaderboardJSON(5), `[`), LeaderboardJSON(5))
}
