package connect4_v4

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestGameJSONUnknown(t *testing.T) {
	reset()
	uassert.True(t, strings.HasSuffix(GameJSON(42), `,"game":null}`))
	uassert.True(t, strings.HasPrefix(GameJSON(42), `{"now":`))
}

func TestGameJSONOpenOffer(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id := Offer(cross(cur), bob, 10, commit(), fee)
	s := GameJSON(id)
	uassert.True(t, strings.Contains(s, `"id":1,`))
	uassert.True(t, strings.Contains(s, `"creator":"`+alice.String()+`"`))
	uassert.True(t, strings.Contains(s, `"opponent":"`+bob.String()+`"`))
	uassert.True(t, strings.Contains(s, `"acceptor":""`))
	uassert.True(t, strings.Contains(s, `"stake":10000000,`))
	uassert.True(t, strings.Contains(s, `"fee":100000,`))
	uassert.True(t, strings.Contains(s, `"status":"open"`))
	uassert.True(t, strings.Contains(s, `"turn":0,`))
	uassert.True(t, strings.Contains(s, `"turnPlayer":""`))
	uassert.True(t, strings.Contains(s, `"deadline":0,`))
	uassert.True(t, strings.Contains(s, `"board":"`+strings.Repeat("0", 42)+`"`))
}

func TestGameJSONMidPlayAndWon(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	first := g.player(g.Turn)
	move(cur, g, 3) // first mover, column 3 -> c=2, r=0
	s := GameJSON(g.ID)
	uassert.True(t, strings.Contains(s, `"status":"playing"`))
	uassert.True(t, strings.Contains(s, `"moves":1,`))
	uassert.True(t, strings.Contains(s, `"lastCol":2,"lastRow":0,`))
	uassert.True(t, strings.Contains(s, `"turnPlayer":"`+g.player(g.Turn).String()+`"`))
	uassert.True(t, strings.Contains(s, `"deadline":`+strconv.FormatInt(g.deadline().Unix(), 10)+`,`))
	want := strings.Repeat("0", 12) + string(rune('0'+int(3-g.Turn))) + strings.Repeat("0", 29)
	uassert.True(t, strings.Contains(s, `"board":"`+want+`"`))
	// Second mover plays 2,2,2,4; first mover stacks column 1 four times.
	move(cur, g, 2)
	move(cur, g, 1)
	move(cur, g, 2)
	move(cur, g, 1)
	move(cur, g, 2)
	move(cur, g, 1)
	move(cur, g, 4)
	move(cur, g, 1) // first mover: column 1 rows 0-3 -> win
	s = GameJSON(g.ID)
	uassert.True(t, strings.Contains(s, `"status":"won"`))
	uassert.True(t, strings.Contains(s, `"winner":"`+first.String()+`"`))
	uassert.True(t, strings.Contains(s, `"turnPlayer":""`))
}

func TestActiveJSON(cur realm, t *testing.T) {
	reset()
	for i := 0; i < 3; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		pay(stake)
		Offer(cross(cur), "", 10, commit(), fee)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Cancel(cross(cur), 2)
	s := ActiveJSON(0, 10)
	uassert.True(t, strings.HasPrefix(s, `{"now":`))
	uassert.True(t, strings.Contains(s, `,"fee":100000,"games":[`)) // the fee a new offer pays
	uassert.True(t, strings.Contains(s, `"id":1,`))
	uassert.False(t, strings.Contains(s, `"id":2,`))
	uassert.True(t, strings.Contains(s, `"id":3,`))
	uassert.Equal(t, 1, strings.Count(ActiveJSON(1, 10), `"id":`))
	uassert.Equal(t, 1, strings.Count(ActiveJSON(-5, 1), `"id":`)) // offset clamps to 0, limit 1
	uassert.Equal(t, 1, strings.Count(ActiveJSON(0, 0), `"id":`))  // limit clamps to 1
	uassert.Equal(t, 2, strings.Count(ActiveJSON(0, 1000), `"id":`))
	uassert.True(t, strings.HasSuffix(ActiveJSON(50, 10), `"games":[]}`))
}

func TestLeadersJSON(cur realm, t *testing.T) {
	reset()
	uassert.Equal(t, `{"wins":[],"gnot":[]}`, LeadersJSON())
	g := started(cur)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Resign(cross(cur), g.ID)
	uassert.Equal(t, `{"wins":[{"addr":"`+bob.String()+`","score":1}],"gnot":[{"addr":"`+bob.String()+`","score":`+strconv.FormatInt(stake-fee, 10)+`}]}`, LeadersJSON())
}
