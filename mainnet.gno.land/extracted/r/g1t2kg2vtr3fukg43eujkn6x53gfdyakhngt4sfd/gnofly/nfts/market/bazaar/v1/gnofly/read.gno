package gnofly

import (
	"strconv"
	"strings"

	"gno.land/p/nt/grc721/v0"
	"gno.land/p/onbloc/json/v0"

	"gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/nfts/planes"
)

// The reads are in the shapes Bazaar's site (bazaar.gnomi.fun) parses on a
// collection package, so that this market can be registered there later
// without a new version. Lines are fields joined by "|":
//
//	id|name|owner|seller|price|listed|image|collection|rarity|traits|revealed|slot
//
// owner is the planes realm's owner, this realm for a listed plane (escrow);
// seller and price are empty and 0 when the plane is not listed. collection
// is the slug Bazaar would know this realm by: the last path element.

// slug is the last element of this realm's path.
const slug = "gnofly"

// maxOpen is the most listings ListOpen returns, as Bazaar's own realms do.
const maxOpen = 50

// Name and Symbol are the planes collection's: the market sells nothing else.
func Name() string   { return "gnofly planes" }
func Symbol() string { return "PLANE" }

// Minted returns how many planes were minted.
func Minted() int { return int(planes.Minted()) }

// OwnerOf returns the owner of a plane on the planes realm: this realm while
// it is listed.
func OwnerOf(tid string) (address, error) {
	return planes.OwnerOf(grc721.TokenID(tid))
}

// TokenURI returns the image of a plane, an https URL.
func TokenURI(tid string) string {
	uri, err := planes.TokenURI(grc721.TokenID(tid))
	if err != nil {
		return ""
	}
	return uri
}

// TokensOf returns the ids of the planes owner holds, comma-separated, in
// id order: "3,42,700". A listed plane is not among them: it is held here.
func TokensOf(owner string) string {
	ids := strings.TrimSuffix(strings.TrimPrefix(planes.PlanesOf(address(owner)), "["), "]")
	return ids
}

// ListOpen returns the listings, one line each, in id order, at most 50.
func ListOpen() string {
	var lines []string
	listings.Iterate("", "", func(k string, v any) bool {
		id, _ := strconv.Atoi(k)
		lines = append(lines, line(id, v.(*listing)))
		return len(lines) >= maxOpen
	})
	return strings.Join(lines, "\n")
}

// ItemLine returns the line of plane id, listed or not. It panics for an id
// that is not a minted plane: Bazaar's site skips the ids it cannot read.
func ItemLine(id int) string {
	ownerOf(id) // panics for an id that is not minted
	return line(id, getListing(id))
}

// line builds the line of plane id; l is its listing, nil when it has none.
func line(id int, l *listing) string {
	p := planeInfo(id)
	owner, _ := planes.OwnerOf(tid(id))
	seller, price, listed := "", "0", "false"
	if l != nil {
		seller, price, listed = l.seller.String(), strconv.FormatInt(l.price, 10), "true"
	}
	traits := "model:" + p.model + ",pilot:" + p.pilot + ",laser:" + p.laser
	return strings.Join([]string{
		strconv.Itoa(id), clean(p.name), owner.String(), seller, price, listed,
		clean(p.image), slug, p.tier, clean(traits), "true", "",
	}, "|")
}

type plane struct {
	name, image, tier, model, pilot, laser string
}

// planeInfo reads plane id from the planes realm's PlaneJSON.
func planeInfo(id int) plane {
	node, err := json.Unmarshal([]byte(planes.PlaneJSON(int64(id))))
	if err != nil {
		panic(errUnknownPlane)
	}
	str := func(k string) string {
		v, err := node.GetKey(k)
		if err != nil {
			return ""
		}
		s, err := v.GetString()
		if err != nil {
			return ""
		}
		return s
	}
	return plane{
		name: str("name"), image: str("image"), tier: str("tier"),
		model: str("model"), pilot: str("pilot"), laser: str("laser"),
	}
}

// clean keeps a field from breaking a line: no "|" and no line break. The
// planes realm's names and URLs have none; this is a guard, not a filter.
func clean(s string) string {
	return strings.NewReplacer("|", " ", "\n", " ", "\r", " ").Replace(s)
}

// Render shows the listings on gnoweb.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# gnofly planes on Bazaar\n\n")
	b.WriteString("The [gnofly](https://gnofly.xyz) planes for sale on [Bazaar](https://bazaar.gnomi.fun), the collection `gnofly`. ")
	b.WriteString("A listed plane is held by this realm until it is bought or the listing is cancelled. ")
	b.WriteString("Each sale pays Bazaar's fee and the planes' royalty to the gnofly treasury, the rest to the seller.\n\n")
	if !registered {
		b.WriteString("Not registered on Bazaar yet.\n\n")
	}
	if paused {
		b.WriteString("New listings are paused: listed planes can still be bought or cancelled.\n\n")
	}
	if listings.Size() == 0 {
		b.WriteString("No plane is for sale.\n")
		return b.String()
	}
	b.WriteString("| Plane | Tier | Price | Seller |\n|---|---|---|---|\n")
	listings.Iterate("", "", func(k string, v any) bool {
		id, _ := strconv.Atoi(k)
		l := v.(*listing)
		p := planeInfo(id)
		b.WriteString("| [#" + k + " " + p.name + "](https://gnofly.xyz/nft/collections/planes/" + strconv.Itoa(id) + ") | " +
			p.tier + " | " + gnot(l.price) + " | " + l.seller.String() + " |\n")
		return false
	})
	return b.String()
}

// gnot writes ugnot as GNOT: 1000000 is "1 GNOT", 1500000 "1.5 GNOT".
func gnot(ugnot int64) string {
	whole, frac := ugnot/1_000_000, ugnot%1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	f := strings.TrimRight(strconv.FormatInt(frac+1_000_000, 10)[1:], "0")
	return strconv.FormatInt(whole, 10) + "." + f + " GNOT"
}
