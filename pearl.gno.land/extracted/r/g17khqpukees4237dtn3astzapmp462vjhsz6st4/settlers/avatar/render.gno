package avatar

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/md/v0"
	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/mdtable/v0"
	"gno.land/p/nt/mux/v0"
	settlers "gno.land/r/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft"
)

const (
	// Sample size is the size in pixels of the avatars in the pages.
	sampleSize = 48

	// Samples is how many avatars the home page shows.
	samples = 6

	// Snippet contains a package usage snippet.
	snippet = "import \"gno.land/r/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/avatar\"\n\n" +
		"func row(addr address) string {\n\treturn avatar.Markdown(addr, 32, true) " +
		"+ \" \" + addr.String()\n}\n"
)

var realmPath string

func init(cur realm) {
	realmPath = strings.TrimPrefix(cur.PkgPath(), runtime.ChainDomain())
}

// Render renders the realm.
//
// By default renders what this realm is, how to use it, and some avatars.
//
// Paths:
//   - `svg/{address}`: The SVG of the Settler of an address.
//   - `md/{address}`: The Markdown that Markdown returns for an address, rendered, with the same parameters.
func Render(path string) string {
	router := mux.NewRouter()
	router.NotFoundHandler = func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write("Path not found")
	}

	router.HandleFunc("", renderHome)
	router.HandleFunc("svg/{addr}", renderSVG)
	router.HandleFunc("md/{addr}", renderMarkdown)

	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write(md.H1("Settler avatars"))
	res.Write(md.Paragraph(
		"The " + md.Link("Settlers", "/r/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft") +
			" of an address as an avatar, for other realms and for web apps.",
	))

	res.Write(md.H2("From a realm"))
	res.Write(md.LanguageCodeBlock("go", snippet))

	table := mdtable.Table{Headers: []string{"Function", "Description"}}
	table.Append([]string{
		"Markdown(addr, size, transparent)",
		"The image, or an empty text if there is none",
	})
	table.Append([]string{
		"SVG(addr, size, transparent)",
		"The SVG document, or an empty text if there is none",
	})
	table.Append([]string{
		"URI(addr, size, transparent)",
		"The same image as a data URI",
	})
	res.Write(table.String() + "\n")

	res.Write(md.Paragraph(
		"The size is in pixels, from 32 to 2048, and 0 leaves it to the container. " +
			"With transparent the image has no background. Every call draws the image again and " +
			"costs gas (about 6 to 8 million), so use it in `Render` and not in a transaction.",
	))

	res.Write(md.H2("From a web app"))
	res.Write(md.Paragraph("Ask the node for the page of an address, with `vm/qrender`, and use what it returns as an image: " +
		md.InlineCode(realmPath+":svg/{address}?size=64&transparent=1") + ". It is empty if the address has no Settler."))

	if n := settlers.TotalSupply(); n > 0 {
		res.Write(md.H2("Last Settlers"))

		for id := n; id > 0 && id > n-samples; id-- {
			owner := settlers.OwnerOf(id)
			table := mdtable.Table{Headers: []string{"", ""}}
			table.Append([]string{
				Markdown(owner, sampleSize, false),
				md.InlineCode(owner.String()),
			})
			res.Write(table.String() + "\n")
		}
	}
}

func renderSVG(res *mux.ResponseWriter, req *mux.Request) {
	svg := SVG(address(req.GetVar("addr")), sizeParam(req), transparentParam(req))
	res.Write(svg)
}

func renderMarkdown(res *mux.ResponseWriter, req *mux.Request) {
	size := sizeParam(req)
	if size == 0 {
		size = sampleSize
	}

	addr := req.GetVar("addr")
	if !address(addr).IsValid() {
		res.Write(md.Paragraph("Not a valid address."))
		res.Write(md.Paragraph(md.Link("Home", realmPath)))
		return
	}

	res.Write(md.H1("Avatar of " + md.InlineCode(addr)))
	res.Write(md.Paragraph(Markdown(address(addr), size, transparentParam(req))))
	res.Write(md.Paragraph(md.Link("Home", realmPath)))
}

func sizeParam(req *mux.Request) int {
	size, err := strconv.Atoi(req.Query.Get("size"))
	if err != nil {
		return 0
	}
	return size
}

func transparentParam(req *mux.Request) bool {
	v := req.Query.Get("transparent")
	return v == "1" || v == "true"
}
