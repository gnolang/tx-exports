package heirloom

import (
	"strconv"
	"strings"

	"gno.land/p/nt/mux/v0"
)

var router = newRouter()

func newRouter() *mux.Router {
	router := mux.NewRouter()
	router.HandleFunc("", func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write(renderHome())
	})
	router.HandleFunc("will/{id}", func(res *mux.ResponseWriter, req *mux.Request) {
		id, err := strconv.Atoi(req.GetVar("id"))
		w := getWill(id)
		if err != nil || w == nil {
			res.Write(notFound("Will not found"))
			return
		}
		res.Write(renderWill(w))
	})
	router.HandleFunc("u/{addr}", func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(userPage(req.GetVar("addr"), "1"))
	})
	router.HandleFunc("u/{addr}/{page}", func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(userPage(req.GetVar("addr"), req.GetVar("page")))
	})
	router.SetNotFoundHandler(func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write(notFound("Page not found"))
	})
	return router
}

// Render serves the home page, "will/<id>", and "u/<address>" with an
// optional page number, "u/<address>/<n>".
func Render(path string) string {
	return router.Render(strings.Trim(path, "/"))
}

func userPage(rawAddr, rawPage string) string {
	addr := normalize(rawAddr)
	if !addr.IsValid() {
		return notFound("Invalid address")
	}
	page, err := strconv.Atoi(rawPage)
	if err != nil || page < 1 {
		return notFound("Page not found")
	}
	return renderUser(addr, page)
}

func notFound(title string) string {
	return "# " + title + "\n\n" + backLink() + "\n"
}
