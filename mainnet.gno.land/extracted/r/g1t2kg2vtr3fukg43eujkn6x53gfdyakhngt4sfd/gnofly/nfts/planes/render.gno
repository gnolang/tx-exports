package planes

import (
	"strconv"
	"strings"
)

// Render returns the state of the collection as markdown, for gnoweb:
//
//	""               the collection: minted, price, tiers, the last mints
//	"plane/<id>"     one plane: traits, owner
//	"player/<addr>"  the planes of one address
//
// Everything printed here is a row of the table, whose charset the tests
// pin, a setting validated when it was written, or an address the chain gave
// the realm. The two caller-supplied values, an id and an address, are
// printed only once parsed and found valid. Nothing needs markdown escaping.
// No images: the planes are drawn by the game and by the website.
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "plane/"):
		if id, err := strconv.ParseInt(strings.TrimPrefix(path, "plane/"), 10, 64); err == nil {
			if p, ok := getPlane(id); ok {
				return renderPlane(p)
			}
		}
	case strings.HasPrefix(path, "player/"):
		if addr := address(strings.TrimPrefix(path, "player/")); validAddress(addr) {
			return renderPlayer(addr)
		}
	}
	return "# gnofly planes\n\nPage not found. Go back to the [collection](" + link("") + ").\n"
}

// link returns the gnoweb URL of a Render path of this realm.
func link(path string) string {
	if path == "" {
		return webPath
	}
	return webPath + ":" + path
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# gnofly planes\n\n")
	b.WriteString("777 planes to fly in gnofly, a multiplayer plane game. Each one is a GRC721 token with a name,\n")
	b.WriteString("a model, three colours, a tier and a laser, drawn from a table written once and for all.\n")
	b.WriteString("Mint up to 7 at once with `Mint` and count times the price attached, then pick one in the hangar of the game.\n\n")

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Minted | " + itoa(Minted()) + " of " + itoa(supply) + " |\n")
	b.WriteString("| Burned | " + itoa(Minted()-Token.TotalSupply()) + " |\n")
	b.WriteString("| Price | " + gnot(price) + " |\n")
	b.WriteString("| Mint open | " + yesNo(mintOpen) + " |\n")
	b.WriteString("| Per wallet | " + itoa(mintCap) + " |\n")
	b.WriteString("| Royalty | " + percent(RoyaltyBps()) + " to the treasury |\n")
	b.WriteString("| Treasury | " + roles.Treasury().String() + " |\n\n")

	b.WriteString("## Tiers\n\n")
	b.WriteString("| Tier | Planes | Minted |\n|---|---|---|\n")
	for i, tier := range strings.Split(tiers, ",") {
		b.WriteString("| " + tier + " | " + itoa(tierSupply[i]) + " | " + itoa(tierMinted[i]) + " |\n")
	}

	b.WriteString("\n## Recent mints\n\n")
	recent := 0
	for _, id := range recentIDs() {
		owner := ownerOf(id)
		if owner == "" {
			continue // burned
		}
		if recent == 0 {
			b.WriteString("| Plane | Tier | Owner |\n|---|---|---|\n")
		}
		p := mustPlane(id)
		b.WriteString("| " + planeLink(p) + " | " + p.tier + " | " + playerLink(owner) + " |\n")
		recent++
	}
	if recent == 0 {
		b.WriteString("No plane is minted yet.\n")
	}
	return b.String()
}

func renderPlane(p plane) string {
	var b strings.Builder
	b.WriteString("# " + p.name + "\n\n")
	b.WriteString("Plane " + itoa(p.id) + " of " + itoa(supply) + ", " + p.tier + ".\n\n")

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Model | " + p.model + " |\n")
	b.WriteString("| Pilot | " + p.pilot + " |\n")
	b.WriteString("| Body | `" + p.body + "` |\n")
	b.WriteString("| Wing | `" + p.wing + "` |\n")
	b.WriteString("| Accent | `" + p.accent + "` |\n")
	b.WriteString("| Laser | `" + p.laser + "` |\n")
	b.WriteString("| Tier | " + p.tier + " |\n")
	owner := ownerOf(p.id)
	switch {
	case owner == "" && wasMinted(p.id):
		b.WriteString("| Owner | burned |\n")
	case owner == "":
		b.WriteString("| Owner | not minted yet |\n")
	default:
		b.WriteString("| Owner | " + playerLink(owner) + " |\n")
		b.WriteString("| Metadata | `" + imageBase + itoa(p.id) + ".json` |\n")
	}
	b.WriteString("\n[Collection](" + link("") + ")\n")
	return b.String()
}

func renderPlayer(addr address) string {
	var b strings.Builder
	b.WriteString("# Pilot " + addr.String() + "\n\n")
	n, _ := Token.BalanceOf(addr)
	if n == 0 {
		b.WriteString("This address owns no plane.\n")
	} else {
		b.WriteString(itoa(n) + " plane" + plural(n) + ", minted " + itoa(mintedBy(addr)) + " of " + itoa(mintCap) + " allowed.\n\n")
		b.WriteString("| Plane | Model | Pilot | Tier |\n|---|---|---|---|\n")
		found := int64(0)
		for id := int64(1); id <= supply && found < n; id++ {
			if ownerOf(id) != addr {
				continue
			}
			p := mustPlane(id)
			b.WriteString("| " + planeLink(p) + " | " + p.model + " | " + p.pilot + " | " + p.tier + " |\n")
			found++
		}
	}
	b.WriteString("\n[Collection](" + link("") + ")\n")
	return b.String()
}

// planeLink is "[42 Storm Saint](.../plane/42)".
func planeLink(p plane) string {
	return "[" + itoa(p.id) + " " + p.name + "](" + link("plane/"+itoa(p.id)) + ")"
}

// playerLink is "[g1...](.../player/g1...)".
func playerLink(addr address) string {
	return "[" + addr.String() + "](" + link("player/"+addr.String()) + ")"
}

// gnot formats an amount of ugnot in GNOT, without trailing zeros:
// 77000000 gives "77 GNOT", 9500000 gives "9.5 GNOT".
func gnot(ugnot int64) string {
	whole, frac := ugnot/1000000, ugnot%1000000
	if frac == 0 {
		return itoa(whole) + " GNOT"
	}
	decimals := itoa(1000000 + frac)[1:] // all six of them, zeros included
	end := len(decimals)
	for decimals[end-1] == '0' {
		end--
	}
	return itoa(whole) + "." + decimals[:end] + " GNOT"
}

// percent formats basis points as a percentage, without trailing zeros:
// 500 gives "5%", 250 gives "2.5%", 1 gives "0.01%".
func percent(bps int64) string {
	whole, frac := bps/100, bps%100
	switch {
	case frac == 0:
		return itoa(whole) + "%"
	case frac%10 == 0:
		return itoa(whole) + "." + itoa(frac/10) + "%"
	case frac < 10:
		return itoa(whole) + ".0" + itoa(frac) + "%"
	}
	return itoa(whole) + "." + itoa(frac) + "%"
}

func plural(n int64) string {
	if n == 1 {
		return ""
	}
	return "s"
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// recentIDs returns the last ids minted, newest first.
func recentIDs() []int64 {
	var ids []int64
	for _, id := range recent {
		if id != 0 {
			ids = append(ids, id)
		}
	}
	return ids
}
