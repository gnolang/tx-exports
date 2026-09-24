package nft

import (
	"strconv"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft/v0"
	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/md/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
)

const (
	// Gallery width is the width/height of gallery Settler images.
	galleryWidth = 96

	// Detail width is the width/height of Settler the image for detail views.
	detailWidth = 256

	// Gallery length is the number of last minted Settlers of the home page.
	galleryLen = 5
)

// Render renders the realm.
//
// By default renders the state of the mint and the last minted Settlers.
//
// Paths:
//   - `token/{id}`: A Settler with its traits and its owner.
//   - `addr/{address}`: The Settler of an account.
func Render(path string) string {
	router := mux.NewRouter()
	router.NotFoundHandler = func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write("Path not found")
	}

	router.HandleFunc("", renderHome)
	router.HandleFunc("token/{id}", renderToken)
	router.HandleFunc("addr/{addr}", renderAddr)

	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write(md.H1("Settlers"))
	res.Write(md.Paragraph(
		"Soulbound pixel-art gnomes for the early settlers of Gno.land. " +
			"Every account that had at least 15 GNOT at the launch of `gnoland-1` can mint one, " +
			"first come first served. A Settler can't be transferred.",
	))

	minted := TotalSupply()
	if len(root) == 0 {
		res.Write(md.Paragraph("The mint is not open yet."))
	} else {
		res.Write(md.Paragraph(
			md.BulletItem(md.Bold("Minted:")+" "+strconv.Itoa(minted)+" of "+strconv.Itoa(supplyCap)) +
				md.BulletItem(md.Bold("Eligible accounts:")+" "+strconv.Itoa(total)) +
				md.BulletItem(md.Bold("Merkle root:")+" "+md.InlineCode(MerkleRoot())),
		))

		res.Write(md.Paragraph(
			"To mint, get your proof from the list of eligible accounts and call `Mint` with it; " +
				"the account that signs the transaction is the one that gets the Settler.",
		))
	}

	if minted > 0 {
		res.Write(md.H2("Last Settlers"))
		tokens.ReverseIterateByOffset(0, galleryLen, func(key string, value any) bool {
			settlerID, _ := strconv.Atoi(key)
			alt := "Settler #" + strconv.Itoa(settlerID)
			img := image(alt, nft.Unpack(value.(token).traits), galleryWidth)
			res.Write("[" + img + "](" + tokenPath(settlerID) + ") ")
			return false
		})
		res.Write("\n\n")
	}

	res.Write(footer())
}

func renderToken(res *mux.ResponseWriter, req *mux.Request) {
	rawSettlerID := req.GetVar("id")
	settlerID, err := strconv.Atoi(rawSettlerID)
	if err != nil || settlerID < 1 || settlerID > TotalSupply() {
		res.Write(md.Paragraph("Settler not found."))
		res.Write(md.Paragraph(md.Link("Home", realmPath)))
		return
	}

	title := "Settler #" + rawSettlerID
	res.Write(md.H1(title))
	t := TraitsOf(settlerID)
	res.Write(image(title, t, detailWidth) + "\n\n")

	owner := OwnerOf(settlerID).String()
	res.Write(md.Paragraph(
		"Owner: " + md.Link(owner, realmPath+":addr/"+owner) +
			" · soulbound: it can't be transferred",
	))

	res.Write("| Trait | Value |\n| --- | --- |\n")
	for _, attr := range t.Attributes() {
		res.Write("| " + attr.Type + " | " + attr.Value + " |\n")
	}
	res.Write("\n")

	res.Write(md.Paragraph(md.Link("Home", realmPath)))
	res.Write(footer())
}

func renderAddr(res *mux.ResponseWriter, req *mux.Request) {
	addr := sanitize.BechString(req.GetVar("addr"), "g")
	if addr == "" {
		res.Write(md.Paragraph("Not a valid address."))
		res.Write(md.Paragraph(md.Link("Home", realmPath)))
		return
	}

	settlerID := TokenOf(address(addr))
	if settlerID == 0 {
		res.Write(md.H1("Settler of " + md.InlineCode(addr)))
		res.Write(md.Paragraph("This account has not minted a Settler."))
		res.Write(md.Paragraph(md.Link("Home", realmPath)))
		return
	}

	res.Write(md.H1("Settler of " + md.InlineCode(addr)))
	res.Write("[" + image("Settler #"+strconv.Itoa(settlerID), TraitsOf(settlerID), detailWidth) + "](" + tokenPath(settlerID) + ")\n\n")
	res.Write(md.Paragraph(md.Link("Settler #"+strconv.Itoa(settlerID), tokenPath(settlerID)) + " · " + md.Link("Home", realmPath)))
	res.Write(footer())
}

func image(alt string, t nft.Traits, width int) string {
	return "![" + alt + "](" + nft.RenderDataURI(t, nft.Options{Size: width}) + ")"
}

func tokenPath(settlerID int) string {
	return realmPath + ":token/" + strconv.Itoa(settlerID)
}

func footer() string {
	return md.Blockquote(nft.Credits)
}
