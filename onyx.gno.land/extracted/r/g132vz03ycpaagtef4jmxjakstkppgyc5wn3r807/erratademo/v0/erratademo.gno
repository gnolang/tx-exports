// Package erratademo embeds the accepted corrections for a documentation page.
package erratademo

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/errata/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v0"
)

const pageSize = 20

var (
	owner    address
	bookID   int
	realmURL string
	router   = mux.NewRouter()
)

func init(cur realm) {
	owner = cur.Previous().Address()
	realmURL = strings.TrimPrefix(cur.PkgPath(), "gno.land") + ":"
	router.HandleFunc("", renderGuide)
}

// SetBook connects this page to an existing book. The deployer can do this once.
func SetBook(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("invalid realm context")
	}
	if cur.Previous().Address() != owner {
		panic("demo deployer only")
	}
	if bookID != 0 {
		panic("demo book already set")
	}
	if _, ok := erratabank.GetBook(id); !ok {
		panic("book not found")
	}
	bookID = id
	chain.Emit("DemoBookSet", "book", strconv.Itoa(id))
}

// BookID returns the configured book, or zero if the page is unlinked.
func BookID() int {
	return bookID
}

func Render(path string) string {
	return router.Render(path)
}

func renderGuide(w *mux.ResponseWriter, req *mux.Request) {
	w.Write("# Erratabank Quickstart\n\n")
	w.Write("To report an error, give the page or section, explain what is wrong, and suggest a correction.\n\n")
	w.Write("The maintainer reviews submissions on Erratabank. Accepted corrections appear here automatically.\n\n")
	w.Write("## Section 1. Formatting examples\n\nOpen a fenced code block with two backticks on their own line.\n\n")
	w.Write("## Section 2. Notes\n\nInclude the expected output when a correction changes an example.\n\n")
	if bookID == 0 {
		w.Write("The maintainer has yet to link this guide to a book.\n\n")
		w.Write(errata.RenderSection("Errata", nil))
		return
	}
	page := 1
	if value := req.Query.Get("page"); value != "" {
		var err error
		page, err = strconv.Atoi(value)
		if err != nil || page < 1 || page-1 > int(^uint(0)>>1)/pageSize {
			w.Write("Errata page not found.\n")
			return
		}
	}

	entries := erratabank.AcceptedEntriesPage(bookID, (page-1)*pageSize, pageSize+1)
	if page > 1 && len(entries) == 0 {
		w.Write("Errata page not found.\n")
		return
	}
	more := len(entries) > pageSize
	if more {
		entries = entries[:pageSize]
	}
	w.Write(errata.RenderSection("Errata", entries))
	if page > 1 {
		w.Write("\n[Previous](" + realmURL + "?page=" + strconv.Itoa(page-1) + ")")
	}
	if more {
		w.Write("\n[Next](" + realmURL + "?page=" + strconv.Itoa(page+1) + ")")
	}
}
