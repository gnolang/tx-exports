package nft

import (
	"chain/runtime"
	"strconv"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft/v0"
)

// TokenURI returns a JSON string with the metadata of a Settler (OpenSea style).
// The `image` is the gnome SVG, encoded in a data URI, and the `external_url` is
// the page of this realm that shows the token, so that an app that lists a Settler
// can link back to the realm.
func TokenURI(settlerID int) string {
	t := TraitsOf(settlerID)

	var attrs string
	for i, attr := range t.Attributes() {
		if i > 0 {
			attrs += ","
		}

		attrs += `{"trait_type":"` + attr.Type + `","value":"` + attr.Value + `"}`
	}

	return `{"name":"Settler #` + strconv.Itoa(settlerID) + `",` +
		`"description":"Soulbound gnome of the early settlers of Gno.land. ` + nft.Credits + `",` +
		`"image":"` + nft.RenderDataURI(t, nft.Options{Size: nft.CanonicalSize}) + `",` +
		`"external_url":"` + ExternalURL(settlerID) + `",` +
		`"attributes":[` + attrs + `]}`
}

// ExternalURL returns the URL to a Settler profile page.
func ExternalURL(settlerID int) string {
	return "https://" + runtime.ChainDomain() + realmPath + ":token/" + strconv.Itoa(settlerID)
}
