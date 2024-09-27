package router

import (
	"strings"

	"gno.land/p/demo/ufmt"
)

type (
	// ResponseWriter defines the interface to write response output content.
	ResponseWriter interface {
		// Write writes a string to the response output.
		Write(s string)

		// Writef writes a formatted string to the response output.
		Writef(format string, values ...interface{})
	}

	// Request contains incoming request info.
	Request struct {
		// Path contains the full render path.
		Path string

		// Prefix contains the render path prefix that handled the request.
		// For example for "/prefix/custom/route" the prefix path is "/prefix".
		Prefix string

		// Route contains the render path after the prefix.
		// This path doesn't include arguments.
		// For example for "/prefix/custom/route:arg1=value1" the route is "/custom/route".
		Route string

		// Args contains the list of arguments found in the render path.
		// Any number of arguments can be defined as render path suffix by using
		// a colon as separator, for example:
		//
		//  /prefix/custom/route:arg1=value1:arg2=value2
		//
		// In the example the argument are "arg1=value1" and "arg2=value2".
		// The arguments can have any format as long as they are separated by a colon.
		Args []string
	}

	// HandlerFunc defines the type for request handlers.
	HandlerFunc func(ResponseWriter, Request)

	handler struct {
		Prefix string
		Fn     HandlerFunc
	}
)

// New creates a new prefix router.
func New() Router {
	return Router{}
}

// Router allows routing requests by render path prefix.
type Router struct {
	handlers []handler
}

// HandlerFunc registers a request handler for a request path prefix.
func (r *Router) HandleFunc(prefix string, fn HandlerFunc) {
	r.handlers = append(r.handlers, handler{
		Prefix: prefix,
		Fn:     fn,
	})
}

// Render returns the response content for a render path.
func (r Router) Render(path string) string {
	prefix, route, args := SplitRenderPath(path)

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

// SplitRenderPath splits render path into a prefix, route and arguments.
func SplitRenderPath(path string) (prefix, route string, args []string) {
	path = strings.TrimSpace(path)
	path = strings.TrimLeft(path, "/")

	// Handle the case where the path is the prefix with no route
	if !strings.ContainsAny(path, "/") {
		// Split prefix and arguments
		parts := strings.Split(path, ":")
		prefix = parts[0]
		if len(parts) > 1 {
			args = parts[1:]
		}

		return prefix, route, args
	}

	// Split route prefix and route
	parts := strings.SplitN(path, "/", 2)
	prefix = parts[0]

	// Split route and arguments
	parts = strings.Split(parts[1], ":")
	route = parts[0]
	if len(parts) > 1 {
		args = parts[1:]
	}

	return prefix, route, args
}
