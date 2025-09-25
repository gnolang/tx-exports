package router

import (
	"strings"

	"gno.land/p/demo/ufmt"
)

type (
	ResponseWriter interface {
		Write(s string)
		Writef(format string, values ...interface{})
	}

	Request struct {
		Path   string
		Prefix string
		Route  string
		Args   []string
	}

	HandlerFunc func(ResponseWriter, Request)

	handler struct {
		Prefix string
		Fn     HandlerFunc
	}
)

func NewRouter() Router {
	return Router{}
}

type Router struct {
	handlers []handler
}

func (r *Router) HandleFunc(prefix string, fn HandlerFunc) {
	r.handlers = append(r.handlers, handler{
		Prefix: prefix,
		Fn:     fn,
	})
}

func (r Router) Render(path string) string {
	prefix, route, args := splitRenderPath(path)

	for _, h := range r.handlers {
		if h.Prefix == prefix {
			var (
				w   responseWriter
				req = Request{
					Path:   path,
					Prefix: prefix,
					Route:  route,
					Args:   args,
				}
			)

			h.Fn(&w, req)

			return w.Output()
		}
	}

	return "Path not found"
}

type responseWriter struct {
	output strings.Builder
}

func (w *responseWriter) Write(s string) {
	w.output.WriteString(s)
}

func (w *responseWriter) Writef(format string, values ...interface{}) {
	w.output.WriteString(ufmt.Sprintf(format, values...))
}

func (w responseWriter) Output() string {
	return w.output.String()
}

func splitRenderPath(path string) (prefix, route string, args []string) {
	// Split route prefix and route.
	// Path format is "prefix/route:args".
	path = strings.TrimSpace(path)
	if parts := strings.SplitN(path, "/", 2); len(parts) == 2 {
		prefix = parts[0]
		route = parts[1]

		// Split route and arguments
		if parts := strings.Split(route, ":"); len(parts) > 1 {
			route = parts[0]
			args = parts[1:]
		}
	}

	return prefix, route, args
}
