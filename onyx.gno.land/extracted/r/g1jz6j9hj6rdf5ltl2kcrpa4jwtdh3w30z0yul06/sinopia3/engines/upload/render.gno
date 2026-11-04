package upload

import (
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/media/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
)

// cardSVG is the generic card: the registration sample (unique
// fingerprint, CV-L3), RenderWith output, and the answer to any call that
// is not core's real render of a revealed, bound token.
const cardSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">` +
	`<rect width="512" height="512" fill="#16130f"/>` +
	`<rect x="20" y="20" width="472" height="472" fill="none" stroke="#b5332e" stroke-width="3"/>` +
	`<text x="256" y="240" fill="#eeeeee" font-family="monospace" font-size="30" text-anchor="middle">Sinopia Upload</text>` +
	`<text x="256" y="282" fill="#999999" font-family="monospace" font-size="15" text-anchor="middle">art from a sealed asset store</text>` +
	`</svg>`

// certificateSVG stands in for raster and IPFS art on core's TokenURI
// path, which only carries allowlisted SVG (§10.1). Every text is
// XML-escaped; the document stays far below MaxSVGBytes.
func certificateSVG(r resolved) string {
	a := r.art
	title := a.Title
	if title == "" {
		title = "Artwork #" + strconv.FormatInt(a.Index+1, 10)
	}
	tier := "no tier"
	if a.Tier != "" {
		tier = a.Tier + " — creator tier"
	}
	where := strings.ToUpper(media.MimeName(a.Mime)) + " · " + sizeLabel(a.Size) + " · stored on-chain"
	if a.Kind != media.KindChain {
		where = "IPFS · " + strings.ToUpper(media.MimeName(a.Mime)) + " · " + sizeLabel(a.Size)
	}
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">`)
	b.WriteString(`<rect width="512" height="512" fill="#16130f"/>`)
	b.WriteString(`<rect x="16" y="16" width="480" height="480" fill="none" stroke="#b5332e" stroke-width="2"/>`)
	line := func(y int, size int, fill, text string) {
		b.WriteString(`<text x="256" y="` + strconv.Itoa(y) + `" fill="` + fill + `" font-family="monospace" font-size="` +
			strconv.Itoa(size) + `" text-anchor="middle">` + safe.XMLEscape(text) + `</text>`)
	}
	line(78, 24, "#eeeeee", r.info.Name)
	line(116, 20, "#cccccc", "#"+r.tid)
	line(196, 20, "#eeeeee", title)
	line(232, 16, "#d9a441", tier)
	if a.Editions > 1 {
		line(262, 14, "#aaaaaa", "edition "+editionLabel(r.edition, a.Editions))
	}
	line(316, 14, "#aaaaaa", where)
	if a.CID != "" {
		line(340, 11, "#888888", a.CID)
	}
	line(364, 12, "#888888", "sha256 "+a.SHA256[:16]+"…")
	line(452, 11, "#777777", "full image: "+selfPath+" TokenURI")
	b.WriteString(`</svg>`)
	return b.String()
}

func sizeLabel(n int64) string {
	if n < 1024 {
		return strconv.FormatInt(n, 10) + " B"
	}
	tenths := (n*10 + 512) / 1024
	return strconv.FormatInt(tenths/10, 10) + "." + strconv.FormatInt(tenths%10, 10) + " KB"
}
