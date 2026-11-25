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
			res.Write(notFound("No such will"))
			return
		}
		res.Write(renderWill(w))
	})
	router.HandleFunc("u/{addr}", func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(userPage(req.GetVar("addr"), "", "0"))
	})
	router.HandleFunc("u/{addr}/{list}/{before}", func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(userPage(req.GetVar("addr"), req.GetVar("list"), req.GetVar("before")))
	})
	router.SetNotFoundHandler(func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write(notFound("Page not found"))
	})
	return router
}

// Render serves the home page, "will/<id>", "u/<address>", and
// "u/<address>/<made|heir|successor>/<before id>" for older entries of one list.
func Render(path string) string {
	route := strings.Trim(path, "/")
	return router.Render(route)
}

func userPage(rawAddr, list, rawBefore string) string {
	addr := normalize(rawAddr)
	if !addr.IsValid() {
		return notFound("Invalid address")
	}
	before, err := strconv.Atoi(rawBefore)
	if err != nil || before < 0 || (list != "" && before == 0) {
		return notFound("Page not found")
	}
	return renderUser(addr, list, before)
}

func notFound(title string) string {
	return "# " + title + "\n\n" + backLink() + "\n"
}
