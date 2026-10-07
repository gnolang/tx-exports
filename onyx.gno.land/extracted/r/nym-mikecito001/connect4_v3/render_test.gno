package connect4_v3

import (
	"encoding/base64"
	"strconv"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestLeaderboardTopTen(t *testing.T) {
	reset()
	for i := 1; i <= 12; i++ {
		topWins = bump(topWins, testutils.TestAddress("p"+strconv.Itoa(i)), int64(i))
	}
	out := leaderboard(topWins, func(v int64) string { return strconv.FormatInt(v, 10) })
	uassert.True(t, strings.HasPrefix(strings.Split(out, "\n")[2], "| 1 | "+testutils.TestAddress("p12").String()+" | 12 |"))
	uassert.True(t, strings.Contains(out, "| 10 | "+testutils.TestAddress("p3").String()+" | 3 |"))
	uassert.False(t, strings.Contains(out, testutils.TestAddress("p2").String()))
}

func TestGamePageShowsActionsForEveryState(cur realm, t *testing.T) {
	reset()
	contains := func(out string, want ...string) {
		for _, w := range want {
			uassert.True(t, strings.Contains(out, w), "missing "+w+" in:\n"+out)
		}
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id := Offer(cross(cur), "", 10, commit())
	page := "game/" + strconv.Itoa(id)
	contains(Render(page), "func=Accept", ".send=10000000ugnot", "func=Cancel", "Open offer")

	g := mustGet(id)
	g.ExpiresAt = time.Now().Add(-time.Second)
	out := Render(page)
	contains(out, "expired", "func=Cancel")
	uassert.False(t, strings.Contains(out, "func=Accept"))

	g, p := accepted(cur)
	page = "game/" + strconv.Itoa(g.ID)
	contains(Render(page), "Waiting for", "func=Reveal", "func=Resign")

	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Reveal(cross(cur), g.ID, p)
	contains(Render(page), "func=Play", "column=7", "func=Resign", "Turn:")

	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Resign(cross(cur), g.ID)
	contains(Render(page), "Winner", bob.String(), gnot(2*stake-fee))

	for status, want := range map[Status]string{
		Draw:      "both stakes refunded",
		Void:      "both stakes refunded",
		Cancelled: "refunded to the creator",
	} {
		g.Status = status
		contains(Render(page), want)
	}
}

func TestLobbyLinksEveryGameToItsPage(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id := Offer(cross(cur), "", 10, commit())
	g, _ := accepted(cur)
	// Render as if deployed elsewhere: links must follow the realm's real path.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/nym-mikecito001/connect4"))
	out := Render("")
	base := "(/r/nym-mikecito001/connect4:"
	uassert.True(t, strings.Contains(out, base+"game/"+strconv.Itoa(id)+")"), out)
	uassert.True(t, strings.Contains(out, base+"game/"+strconv.Itoa(g.ID)+")"), out)
	uassert.True(t, strings.Contains(out, base+"new)"), out)
	uassert.False(t, strings.Contains(out, "samcrew"), "links must not hardcode the realm path")
}

func TestNewOfferPage(t *testing.T) {
	reset()
	c := sha256Hex("some four random words")

	out := Render("new")
	uassert.True(t, strings.Contains(out, `<gno-form path="new">`))
	uassert.False(t, strings.Contains(out, "func=Offer"))

	out = Render("new?stake=12.5&validFor=10&opponent=" + bob.String() + "&commitment=" + c)
	for _, want := range []string{"func=Offer", ".send=12500000ugnot", "validFor=10", "opponent=" + bob.String(), "commitment=" + c, "12.5 GNOT"} {
		uassert.True(t, strings.Contains(out, want), "missing "+want+" in:\n"+out)
	}

	out = Render("new?stake=3&commitment=" + c) // validFor defaults, opponent optional
	uassert.True(t, strings.Contains(out, ".send=3000000ugnot"))
	uassert.True(t, strings.Contains(out, "validFor=15"))

	for _, q := range []string{
		"stake=%3Cscript%3E&validFor=10&commitment=" + c, // not a number
		"stake=0.5&validFor=10&commitment=" + c,          // below minimum
		"stake=1.0000001&validFor=10&commitment=" + c,    // more than 6 decimals
		"stake=5&validFor=61&commitment=" + c,
		"stake=5&validFor=10&opponent=%3Cscript%3E&commitment=" + c,
		"stake=5&validFor=10&commitment=%3Cscript%3E",
		"stake=5&validFor=10",
	} {
		out := Render("new?" + q)
		uassert.False(t, strings.Contains(out, "func=Offer"), q)
		uassert.True(t, strings.Contains(out, "Fix the following"), q)
		uassert.False(t, strings.Contains(out, "<script>"), "form input echoed: "+q)
	}
}

// svgs returns the decoded SVG of every data-URI image in out, and the
// markdown that immediately wraps each image ("[" link or "" for none).
func svgs(t *testing.T, out string) (images []string, linked []bool) {
	parts := strings.Split(out, "(data:image/svg+xml;base64,")
	for i, p := range parts[1:] {
		end := strings.Index(p, ")")
		raw, err := base64.StdEncoding.DecodeString(p[:end])
		if err != nil {
			t.Fatalf("image %d is not base64: %v", i, err)
		}
		images = append(images, string(raw))
		before := parts[i]
		img := strings.LastIndex(before, "![")
		linked = append(linked, img > 0 && before[img-1] == '[')
	}
	return images, linked
}

func TestBoardIsClickableSVGColumns(cur realm, t *testing.T) {
	reset()
	g, p := accepted(cur)
	page := "game/" + strconv.Itoa(g.ID)

	// Reveal phase: the board is one image holding all 7 columns, not a link.
	out := Render(page)
	images, linked := svgs(t, out)
	uassert.Equal(t, 1, len(images))
	uassert.Equal(t, 7, strings.Count(images[0], `class="col"`))
	uassert.False(t, linked[0], "no clickable column before the reveal")
	uassert.True(t, strings.Contains(out, "![board: column 1:"), "alt text")
	uassert.False(t, strings.Contains(out, "func=Play"))

	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Reveal(cross(cur), g.ID, p)
	first := g.Turn
	move(cur, g, 3) // first mover drops in column 3

	out = Render(page)
	for c := 1; c <= 7; c++ {
		uassert.True(t, strings.Contains(out, "](/r/samcrew/connect4$help&func=Play&column="+strconv.Itoa(c)+"&id=") ||
			strings.Contains(out, "$help&func=Play&column="+strconv.Itoa(c)+"&id="), "column link "+strconv.Itoa(c))
	}
	images, linked = svgs(t, out)
	boardImgs := 0
	for i, img := range images {
		if strings.Contains(img, `class="col"`) {
			boardImgs++
			uassert.True(t, linked[i], "board column must be a link while playing")
		}
	}
	uassert.Equal(t, 7, boardImgs)
	col3 := images[boardIndex(images, 3)]
	uassert.True(t, strings.Contains(col3, `fill="`+[...]string{"", red, yellow}[first]+`"`), col3)
	uassert.True(t, strings.Contains(col3, `stroke="`+lastMoveStroke+`"`), "last move ring")
	uassert.True(t, strings.Contains(out, "![column 3: "+[...]string{"", "red", "yellow"}[first]), "alt text")

	// Win with four stacked in column 1: the four cells get the win ring.
	for _, c := range []int{1, 2, 1, 2, 1, 2} {
		move(cur, g, c)
	}
	move(cur, g, 1)
	uassert.Equal(t, "won", g.Status.String())
	out = Render(page)
	images, _ = svgs(t, out)
	uassert.Equal(t, 1, len(images))
	uassert.Equal(t, 4, strings.Count(images[0], `stroke="`+winStroke+`"`), images[0])
	uassert.False(t, strings.Contains(out, "func=Play"))
}

// boardIndex returns the index in images of board column c (1-based).
func boardIndex(images []string, c int) int {
	n := 0
	for i, img := range images {
		if strings.Contains(img, `class="col"`) {
			n++
			if n == c {
				return i
			}
		}
	}
	return -1
}

func TestLeaderboardsUpdateOnSettlement(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Resign(cross(cur), g.ID)
	uassert.Equal(t, 1, len(topWins))
	uassert.Equal(t, bob, topWins[0].Addr)
	uassert.Equal(t, 2*stake-fee, topGnot[0].Score)
	uassert.True(t, strings.Contains(Render(""), "| 1 | "+bob.String()+" | 1 |"))
}

func TestLobbyListsAtMostLobbyRows(cur realm, t *testing.T) {
	reset()
	for i := 0; i < lobbyRows+3; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		pay(stake)
		Offer(cross(cur), "", 10, commit())
	}
	out := Render("")
	uassert.Equal(t, lobbyRows, strings.Count(out, "func=Accept"))
	uassert.True(t, strings.Contains(out, "Showing the first 50 of 53 active games."))
}
