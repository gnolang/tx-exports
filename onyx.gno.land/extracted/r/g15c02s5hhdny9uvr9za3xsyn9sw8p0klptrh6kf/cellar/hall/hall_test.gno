package hall

import (
	"strings"
	"testing"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const (
	ash   = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")
	briar = address("g19cyxvfmzdnxlf4ul6328wqq4hy3ssqmqcgul0k")
	cask  = address("g1rh0vd3xzwjpcqehrf0tpjlqeq35079wf4zklar")
)

// fake is a challenge whose captures the test controls.
type fake struct {
	info   flag.Info
	broken map[address]bool
}

func (f *fake) Info() flag.Info              { return f.info }
func (f *fake) Captured(player address) bool { return f.broken[player] }

func newFake(slug string, d flag.Difficulty) *fake {
	return &fake{
		info:   flag.Info{Slug: slug, Title: "Fake " + slug, Difficulty: d, Category: "testing", Brief: "A test."},
		broken: map[address]bool{},
	}
}

// enlistFrom enlists ch as if called from the realm at path.
func enlistFrom(cur realm, path string, ch flag.Challenge) {
	testing.SetRealm(testing.NewCodeRealm(path))
	Enlist(cross(cur), ch)
}

func claimAs(cur realm, player address, slug string) int {
	testing.SetRealm(testing.NewUserRealm(player))
	return Claim(cross(cur), slug)
}

func TestEnlistOfficialIsListed(cur realm, t *testing.T) {
	enlistFrom(cur, officialPrefix+"one", newFake("one", flag.Easy))
	e := mustEntry("one")
	uassert.True(t, e.official)
	uassert.Equal(t, "listed", e.status.String())
}

func TestEnlistCommunityWaitsForReview(cur realm, t *testing.T) {
	enlistFrom(cur, "gno.land/r/"+string(ash)+"/riddle", newFake("riddle", flag.Medium))
	e := mustEntry("riddle")
	uassert.False(t, e.official)
	uassert.Equal(t, "pending", e.status.String())

	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "not open for claims", func() { Claim(cross(cur), "riddle") })
	uassert.AbortsContains(t, cur, "only the curator", func() { Approve(cross(cur), "riddle") })

	testing.SetRealm(testing.NewUserRealm(curator))
	Approve(cross(cur), "riddle")
	uassert.Equal(t, "listed", e.status.String())
	uassert.AbortsContains(t, cur, "not awaiting review", func() { Approve(cross(cur), "riddle") })
}

func TestEnlistRejects(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "from its own realm", func() { Enlist(cross(cur), newFake("users", flag.Easy)) })

	path := "gno.land/r/" + string(briar) + "/twice"
	enlistFrom(cur, path, newFake("twice", flag.Easy))
	uassert.AbortsContains(t, cur, "already enlisted", func() { Enlist(cross(cur), newFake("twice-b", flag.Easy)) })

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/" + string(cask) + "/copycat"))
	uassert.AbortsContains(t, cur, "slug already taken", func() { Enlist(cross(cur), newFake("twice", flag.Easy)) })
	uassert.AbortsContains(t, cur, "slug must be", func() { Enlist(cross(cur), newFake("X", flag.Easy)) })
	uassert.AbortsContains(t, cur, "nil challenge", func() { Enlist(cross(cur), nil) })
}

func TestClaimFlow(cur realm, t *testing.T) {
	ch := newFake("flow", flag.Hard)
	enlistFrom(cur, officialPrefix+"flow", ch)

	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "no record of your capture", func() { Claim(cross(cur), "flow") })
	uassert.AbortsContains(t, cur, "no such challenge", func() { Claim(cross(cur), "nope") })

	ch.broken[ash] = true
	uassert.Equal(t, 500, claimAs(cur, ash, "flow"))
	uassert.AbortsContains(t, cur, "already claimed", func() { Claim(cross(cur), "flow") })

	// The first solver keeps the full value plus first blood.
	p, _ := findProfile(ash)
	pts, n, _ := p.score(0)
	uassert.Equal(t, 550, pts)
	uassert.Equal(t, 1, n)

	// A second solver lowers the value for both, retroactively.
	ch.broken[briar] = true
	second := claimAs(cur, briar, "flow")
	uassert.Equal(t, flag.Value(flag.Hard, 2), second)
	pts, _, _ = p.score(0)
	uassert.Equal(t, second+50, pts)

	// Badges: first blood for ash, a solve badge for briar.
	owner, err := Badges().OwnerOf("blood:flow")
	urequire.NoError(t, err)
	uassert.Equal(t, ash, owner)
	_, err = Badges().OwnerOf(grc721.TokenID("solve:flow:" + string(briar)))
	uassert.NoError(t, err)
	uassert.Equal(t, badgeArt+"blood-flow.svg", BadgeURI("blood:flow"))
	uassert.Equal(t, badgeArt+"flow.svg", BadgeURI("solve:flow:"+string(briar)))
	uassert.Equal(t, "", BadgeURI("solve:flow:"+string(ash)))
}

func TestClaimFromSolutionRealmCreditsNamespace(cur realm, t *testing.T) {
	ch := newFake("relay", flag.Easy)
	enlistFrom(cur, officialPrefix+"relay", ch)
	ch.broken[cask] = true

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/" + string(cask) + "/solutions"))
	Claim(cross(cur), "relay")
	p, ok := findProfile(cask)
	urequire.True(t, ok)
	uassert.True(t, p.solved("relay"))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/moul/home"))
	uassert.AbortsContains(t, cur, "your-g1-address", func() { Claim(cross(cur), "relay") })
}

func TestRetireKeepsPoints(cur realm, t *testing.T) {
	ch := newFake("old", flag.Easy)
	enlistFrom(cur, officialPrefix+"old", ch)
	ch.broken[ash] = true
	claimAs(cur, ash, "old")
	before, _, _ := profileOf(ash).score(0)

	testing.SetRealm(testing.NewUserRealm(curator))
	Retire(cross(cur), "old")
	after, _, _ := profileOf(ash).score(0)
	uassert.Equal(t, before, after)

	ch.broken[briar] = true
	testing.SetRealm(testing.NewUserRealm(briar))
	uassert.AbortsContains(t, cur, "not open for claims", func() { Claim(cross(cur), "old") })
}

func TestHandles(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	SetHandle(cross(cur), "ash")
	uassert.Equal(t, "ash", DisplayName(ash))
	SetHandle(cross(cur), "ash_two")
	uassert.Equal(t, "ash_two", DisplayName(ash))

	testing.SetRealm(testing.NewUserRealm(briar))
	SetHandle(cross(cur), "ash") // released by ash, free again
	uassert.AbortsContains(t, cur, "already taken", func() { SetHandle(cross(cur), "ash_two") })
	for _, bad := range []string{"ab", "1abc", "Ash", "has space", strings.Repeat("a", 21)} {
		uassert.AbortsContains(t, cur, "a handle is", func() { SetHandle(cross(cur), bad) })
	}

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/" + string(cask) + "/bot"))
	uassert.AbortsContains(t, cur, "belong to people", func() { SetHandle(cross(cur), "botty") })

	uassert.Equal(t, "g1rh0vd3…klar", DisplayName(cask))
}

func TestSeasons(cur realm, t *testing.T) {
	ch := newFake("season", flag.Medium)
	enlistFrom(cur, officialPrefix+"season", ch)
	ch.broken[cask] = true
	claimAs(cur, cask, "season")
	opened := currentSeason().Number

	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "only the curator", func() { OpenSeason(cross(cur), "Second Pressing") })

	testing.SetRealm(testing.NewUserRealm(curator))
	uassert.AbortsContains(t, cur, "season name", func() { OpenSeason(cross(cur), "") })
	OpenSeason(cross(cur), "Second Pressing")

	closed := seasons[opened-1]
	uassert.True(t, closed.ClosedAt != 0)
	urequire.True(t, len(closed.Podium) > 0)
	_, err := Badges().OwnerOf(grc721.TokenID("season:" + itoa(opened) + ":1"))
	uassert.NoError(t, err)
	uassert.Equal(t, badgeArt+"season-1.svg", BadgeURI("season:"+itoa(opened)+":1"))
	uassert.Equal(t, opened+1, currentSeason().Number)
	uassert.Equal(t, 0, len(standings(currentSeason().Number)))
}

func TestCurationTransfer(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "only the curator", func() { TransferCuration(cross(cur), ash) })

	old := curator
	testing.SetRealm(testing.NewUserRealm(old))
	uassert.AbortsContains(t, cur, "invalid address", func() { TransferCuration(cross(cur), "nope") })
	TransferCuration(cross(cur), briar)
	uassert.Equal(t, briar, Curator())
	testing.SetRealm(testing.NewUserRealm(briar))
	TransferCuration(cross(cur), old)
}
