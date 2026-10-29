package nft

import (
	"chain/runtime"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft/v0"
	"gno.land/p/nt/grc721/v0"
)

// TokenURI returns the Settler image as an SVG data URI.
// Wallets such as Adena read TokenURI directly as the token image,
// so this must be the image itself. The metadata lives in TokenMetadata.
func TokenURI(tid grc721.TokenID) (string, error) {
	traits, err := TraitsOf(tid)
	if err != nil {
		return "", err
	}

	return nft.RenderDataURI(traits, nft.Options{Size: nft.CanonicalSize}), nil
}

// TokenMetadata returns a JSON string with the metadata of a Settler
// in the format the Adena wallet can understand.
func TokenMetadata(tid grc721.TokenID) (string, error) {
	traits, err := TraitsOf(tid)
	if err != nil {
		return "", err
	}

	var attrs string
	for i, attr := range traits.Attributes() {
		if i > 0 {
			attrs += ","
		}

		attrs += `{"traitType":"` + attr.Type + `","value":"` + attr.Value + `"}`
	}

	return `{"name":"Settler #` + string(tid) + `",` +
		`"description":"Soulbound gnome of the early settlers of Gno.land. ` + nft.Credits + `",` +
		`"image":"` + nft.RenderDataURI(traits, nft.Options{Size: nft.CanonicalSize}) + `",` +
		`"externalUrl":"` + ExternalURL(tid) + `",` +
		`"attributes":[` + attrs + `]}`, nil
}

// ExternalURL returns the URL to a Settler profile page.
func ExternalURL(tid grc721.TokenID) string {
	return "https://" + runtime.ChainDomain() + RealmPath + ":token/" + string(tid)
}
