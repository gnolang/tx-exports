package hall

import (
	"strconv"
	"strings"

	"gno.land/p/nt/grc721/v0"
)

// badgeArt is where the badge artwork lives. The artwork of a badge is
// derived from its token id, so nothing extra is stored per token.
const badgeArt = "https://akinbola247.github.io/cellar-ctf/badges/"

var (
	badges    *grc721.Token
	badgeMint *grc721.PrivateLedger
)

func initBadges(cur realm) {
	badges, badgeMint = grc721.NewToken("Cellar Badges", "CELLAR", 0, cur)
}

// Badges returns a read-only view of the badge collection (GRC721).
// Badges cannot be transferred: the hall exposes no transfer.
//
// Token ids:
//
//	solve:<slug>:<address>  broke a challenge
//	blood:<slug>            broke it first (replaces the solve badge)
//	season:<n>:<rank>       finished a season on the podium
func Badges() grc721.Teller { return badges.ReadonlyTeller() }

// BadgeURI returns the artwork URI of badge tid, or "" if it was never
// minted.
func BadgeURI(tid string) string {
	if _, err := badges.OwnerOf(grc721.TokenID(tid)); err != nil {
		return ""
	}
	parts := strings.Split(tid, ":")
	switch parts[0] {
	case "solve":
		return badgeArt + parts[1] + ".svg"
	case "blood":
		return badgeArt + "blood-" + parts[1] + ".svg"
	case "season":
		return badgeArt + "season-" + parts[2] + ".svg"
	}
	return ""
}

// awardSolve mints the badge for a solve: first blood, or a plain solve.
func awardSolve(p *profile, s Solve) {
	if s.FirstBlood {
		mint(p, "blood:"+s.Slug)
		return
	}
	mint(p, "solve:"+s.Slug+":"+s.Player.String())
}

// awardSeason mints a season podium badge.
func awardSeason(addr address, season, rank int) {
	mint(profileOf(addr), "season:"+strconv.Itoa(season)+":"+strconv.Itoa(rank))
}

func mint(p *profile, tid string) {
	if err := badgeMint.Mint(p.addr, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
	p.badges = append(p.badges, tid)
}
