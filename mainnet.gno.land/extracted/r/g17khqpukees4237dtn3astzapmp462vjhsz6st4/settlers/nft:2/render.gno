package nft

import (
	"strconv"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft/v0"
	"gno.land/p/moul/md/v0"
	"gno.land/p/moul/mdtable/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mdalert/v0"
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

	if Notice != "" {
		res.Write(mdalert.New(NoticeType, "Message", Notice, false).String() + "\n\n")
	}

	res.Write(md.Paragraph(
		"Soulbound pixel-art gnomes for the early settlers of Gno.land. " +
			"Every account that had at least 15 GNOT at the launch of `gnoland-1` can mint one, " +
			"first come first served. A Settler can't be transferred, it's soulbound",
	))

	res.Write(md.Paragraph("Realm paths:"))
	pathsTable := mdtable.Table{Headers: []string{"Path", "Description"}}
	pathsTable.Append([]string{
		md.InlineCode("token/{id}"),
		"A Settler with its traits and its owner.",
	})
	pathsTable.Append([]string{
		md.InlineCode("addr/{address}"),
		"The Settler of an account.",
	})
	res.Write(pathsTable.String() + "\n")

	minted := tokens.Size()
	if len(root) == 0 {
		res.Write(md.Paragraph("The mint is not open yet."))
	} else {
		res.Write(md.Paragraph(
			md.BulletItem(md.Bold("Minted:")+" "+strconv.Itoa(minted)+" of "+strconv.Itoa(supplyCap)) +
				md.BulletItem(md.Bold("Eligible accounts:")+" "+strconv.Itoa(total)) +
				md.BulletItem(md.Bold("Merkle root:")+" "+md.InlineCode(MerkleRoot())),
		))

		res.Write(md.Paragraph(
			"To mint, get your proof from the list of eligible accounts and call " +
				md.Link("Mint", RealmPath+"$help&func=Mint") + " with it; the account that " +
				"signs the transaction is the one that gets the Settler.",
		))
		res.Write(md.Paragraph(
			"Check the " + md.Link("README", RealmPath+"$source&file=README.md") + " for the full instructions.",
		))
	}

	if minted > 0 {
		res.Write(md.H2("Last Settlers"))
		tokens.ReverseIterateByOffset(0, galleryLen, func(key string, value any) bool {
			settlerID, _ := strconv.Atoi(key)
			img := image(settlerID, nft.Unpack(value.(uint32)), galleryWidth)
			res.Write("[" + img + "](" + tokenPath(settlerID) + ") ")
			return false
		})
		res.Write("\n\n")
	}

	res.Write(footer())
}

func renderToken(res *mux.ResponseWriter, req *mux.Request) {
	tid := grc721.TokenID(req.GetVar("id"))
	settlerID, _ := parseTokenID(tid)
	packed, ok := traitsOf(tid)
	if !ok {
		res.Write(md.Paragraph("Settler not found."))
		res.Write(md.Paragraph(backHomeLink()))
		return
	}

	res.Write(md.H1(settlerName(settlerID)))
	t := nft.Unpack(packed)
	res.Write(image(settlerID, t, detailWidth) + "\n\n")

	ownerAddr, _ := OwnerOf(tid)
	owner := ownerAddr.String()
	res.Write(md.Paragraph(
		"Owner: " + md.Link(owner, RealmPath+":addr/"+owner) +
			" · soulbound, it can't be transferred",
	))

	res.Write("| Trait | Value |\n| --- | --- |\n")
	for _, attr := range t.Attributes() {
		res.Write("| " + attr.Type + " | " + attr.Value + " |\n")
	}
	res.Write("\n")

	res.Write(md.Paragraph(backHomeLink()))
	res.Write(footer())
}

func renderAddr(res *mux.ResponseWriter, req *mux.Request) {
	addr := sanitize.BechString(req.GetVar("addr"), "g")
	if addr == "" {
		res.Write(md.Paragraph("Not a valid address."))
		res.Write(md.Paragraph(backHomeLink()))
		return
	}

	tid := TokenOf(address(addr))
	if tid == "" {
		res.Write(md.H1("Settler of " + md.InlineCode(addr)))
		res.Write(md.Paragraph("This account has not minted a Settler."))
		res.Write(md.Paragraph(backHomeLink()))
		return
	}

	settlerID, _ := parseTokenID(tid)
	packed, _ := traitsOf(tid)
	img := image(settlerID, nft.Unpack(packed), detailWidth)
	res.Write(md.H1("Settler of " + md.InlineCode(addr)))
	res.Write("[" + img + "](" + tokenPath(settlerID) + ")\n\n")
	res.Write(md.Paragraph(backHomeLink()))
	res.Write(footer())
}

func image(settlerID int, t nft.Traits, width int) string {
	alt := settlerName(settlerID)
	return "![" + alt + "](" + nft.RenderDataURI(t, nft.Options{Size: width}) + ")"
}

func tokenPath(settlerID int) string {
	return RealmPath + ":token/" + strconv.Itoa(settlerID)
}

func backHomeLink() string {
	return md.Link("< Home", RealmPath)
}

func settlerName(settlerID int) string {
	return "Settler #" + strconv.Itoa(settlerID)
}

func footer() string {
	return md.Blockquote(nft.Credits)
}
