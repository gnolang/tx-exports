package arena

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRenderBoard(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), bob)

	out := Render("")
	uassert.True(t, strings.Contains(out, "[Match 1](/r/nym-gfanton001/gnomepit/arena/v0:match/1)"), out)
	uassert.True(t, strings.Contains(out, "Pickers"), out)
	uassert.True(t, strings.Contains(out, "reserved for "+bob.String()), out)
}

func TestRenderMatch(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))

	v := Match(id)
	out := Render("match/" + id)
	uassert.True(t, strings.Contains(out, "# Match 1"), out)
	uassert.True(t, strings.Contains(out, "Round 2, waiting for "+bob.String()), out)
	uassert.True(t, strings.Contains(out, "| Round 1 | "+strconv.Itoa(v.HP[0][0])+" | "+strconv.Itoa(v.HP[0][1])+" |"), out)
}

func TestRenderPlayer(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	out := Render("player/" + alice.String())
	uassert.True(t, strings.Contains(out, "[Match 1](/r/nym-gfanton001/gnomepit/arena/v0:match/1)"), out)
}

func TestRenderNotFound(t *testing.T) {
	reset()
	for _, path := range []string{"match/99", "match/", "player/nope", "player/" + strings.ToUpper(alice.String()), "elsewhere"} {
		uassert.True(t, strings.Contains(Render(path), "Not found"), path)
	}
}
