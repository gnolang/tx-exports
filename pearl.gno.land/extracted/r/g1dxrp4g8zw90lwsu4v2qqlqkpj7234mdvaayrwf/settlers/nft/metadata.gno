package nft

import (
	"chain/runtime"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/grc721/v0"
	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft/v0"
)

// TokenURI returns a JSON string with the metadata of a Settler (OpenSea style).
// The `image` is the gnome SVG, encoded in a data URI, and the `external_url` is
// the page of this realm that shows the token, so that an app that lists a Settler
// can link back to the realm.
func TokenURI(tid grc721.TokenID) (string, error) {
	traits, err := TraitsOf(tid)
	if err != nil {
		return "", err
	}

	var attrs string
	for i, attr := range traits.Attributes() {
		if i > 0 {
			attrs += ","
		}

		attrs += `{"trait_type":"` + attr.Type + `","value":"` + attr.Value + `"}`
	}

	return `{"name":"Settler #` + string(tid) + `",` +
		`"description":"Soulbound gnome of the early settlers of Gno.land. ` + nft.Credits + `",` +
		`"image":"` + nft.RenderDataURI(traits, nft.Options{Size: nft.CanonicalSize}) + `",` +
		`"external_url":"` + ExternalURL(tid) + `",` +
		`"attributes":[` + attrs + `]}`, nil
}

// ExternalURL returns the URL to a Settler profile page.
func ExternalURL(tid grc721.TokenID) string {
	return "https://" + runtime.ChainDomain() + RealmPath + ":token/" + string(tid)
}
